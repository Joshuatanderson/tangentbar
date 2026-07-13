#!/bin/sh
# TangentBar installer — the documented install path:
#
#   curl -fsSL https://raw.githubusercontent.com/Joshuatanderson/tangentbar/main/install.sh | sh
#
# Why a script instead of a plain download: curl never applies the
# com.apple.quarantine attribute, so Gatekeeper never evaluates the app and
# the self-signed signature opens clean — no "damaged" dialog, no Settings dance.
#
# What it does, verbatim: fetch the latest GitHub release zip, unpack it,
# move TangentBar.app into /Applications, walk you through picking local
# models (Ollama, LM Studio), open the app. Nothing else.

set -eu

REPO="${TANGENTBAR_REPO:-Joshuatanderson/tangentbar}"
DEST="/Applications/TangentBar.app"
OLLAMA="http://localhost:11434"
LMSTUDIO="http://localhost:1234"
CONFIG_DIR="$HOME/Library/Application Support/TangentBar"
CONFIG="$CONFIG_DIR/config.json"

say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- download
say "TangentBar installer — fetching the latest release of ${REPO}…"

API="https://api.github.com/repos/${REPO}/releases/latest"
URL=$(curl -fsSL "$API" \
  | grep -o '"browser_download_url": *"[^"]*TangentBar[^"]*\.zip"' \
  | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')

if [ -z "$URL" ]; then
  say "error: no release zip found at ${API}" >&2
  say "       (check https://github.com/${REPO}/releases)" >&2
  exit 1
fi

TMP=$(mktemp -d /tmp/tangentbar.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

say "downloading $(basename "$URL")…"
curl -fsSL -o "$TMP/TangentBar.zip" "$URL"

# ditto preserves the bundle structure and the code signature.
ditto -xk "$TMP/TangentBar.zip" "$TMP"
[ -d "$TMP/TangentBar.app" ] || { say "error: zip did not contain TangentBar.app" >&2; exit 1; }

# macOS TCC keys the Accessibility grant to the app's code signature
# (designated requirement). If the incoming build's signature differs from
# the installed one — always true for the old ad-hoc builds — the existing
# grant silently dies, while its toggle stays ON in System Settings and
# re-toggling never revives it. Drop the stale entry so the app can re-prompt
# cleanly. Same story when the app is gone but a leftover entry lingers.
OLD_REQ=""
if [ -d "$DEST" ]; then
  OLD_REQ=$(codesign -d -r- "$DEST" 2>&1 | grep '^designated' || true)
  # ${braces} required: bash 3.2 (/bin/sh) folds a trailing multibyte char
  # into the variable name and set -u aborts on the "unbound" result.
  say "replacing existing ${DEST}…"
  osascript -e 'quit app "TangentBar"' >/dev/null 2>&1 || true
  rm -rf "$DEST"
fi
mv "$TMP/TangentBar.app" "$DEST"
say "installed → $DEST"

NEW_REQ=$(codesign -d -r- "$DEST" 2>&1 | grep '^designated' || true)
if [ -z "$OLD_REQ" ] || [ "$OLD_REQ" != "$NEW_REQ" ]; then
  tccutil reset Accessibility com.whorl.TangentBar >/dev/null 2>&1 || true
  if [ -n "$OLD_REQ" ]; then
    say "note: this build's code signature differs from the installed one, so macOS"
    say "      invalidated the old Accessibility grant. Cleared it — TangentBar will"
    say "      ask for Accessibility again on launch."
  fi
fi

# ------------------------------------------------------------ model wizard
# Interactive even under `curl | sh` (stdin is the pipe): prompts read from
# /dev/tty. No terminal, or already configured → skip; the app's own model
# discovery and menu handle everything later.

ask() {  # ask "prompt" -> $ANS
  printf '%s' "$1" > /dev/tty
  IFS= read -r ANS < /dev/tty
}

# Same non-chat filter the app's discovery applies (embedding/audio/image
# models can't answer a definition).
NONCHAT='embed|whisper|clip|diffusion'

list_ollama() {
  curl -fsS --max-time 3 "$OLLAMA/api/tags" 2>/dev/null \
    | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"$//' \
    | grep -viE "$NONCHAT"
}

list_lmstudio() {
  curl -fsS --max-time 3 "$LMSTUDIO/v1/models" 2>/dev/null \
    | grep -o '"id": *"[^"]*"' | sed 's/.*"\([^"]*\)"/\1/' \
    | grep -viE "$NONCHAT"
}

TAB=$(printf '\t')

# All models from both servers, one per line as "<id><TAB><baseURL>" — the
# app tracks a base URL per model slot, so the wizard must too. Model ids
# never contain whitespace on either server.
collect_models() {
  for m in $(list_lmstudio || true); do printf '%s\t%s\n' "$m" "$LMSTUDIO/v1"; done
  for m in $(list_ollama || true); do printf '%s\t%s\n' "$m" "$OLLAMA/v1"; done
}

# The claude CLI's models — first-class picks in the app's menus, so the
# wizard offers them too. "claude" is the app's sentinel base URL routing a
# model through the CLI instead of a local server. The app must probe fixed
# paths (GUI apps get a bare PATH); here the user's own PATH answers, with
# the same fixed paths as backup.
have_claude() {
  command -v claude >/dev/null 2>&1 && return 0
  for p in /opt/homebrew/bin/claude /usr/local/bin/claude \
           "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" \
           "$HOME/.bun/bin/claude" "$HOME/.volta/bin/claude"; do
    [ -x "$p" ] && return 0
  done
  return 1
}

collect_claude_models() {
  have_claude || return 0
  for m in haiku sonnet opus fable; do printf '%s\t%s\n' "$m" "claude"; done
}

show_models() {  # numbered menu of $MODELS, with the serving app named
  i=0
  printf '%s\n' "$MODELS" | while IFS="$TAB" read -r m u; do
    i=$((i+1))
    case "$u" in
      "$LMSTUDIO"*) s="LM Studio" ;;
      "$OLLAMA"*)   s="Ollama" ;;
      *)            s="claude CLI" ;;
    esac
    say "  $i) $m — $s"
  done
}

pick_line() {  # pick_line <number> -> "<id><TAB><baseURL>" (empty if out of range)
  printf '%s\n' "$MODELS" | sed -n "${1}p"
}

wizard() {
  if [ -f "$CONFIG" ]; then
    say "existing TangentBar config found — keeping it (models are switchable from the menu-bar icon)."
    return 0
  fi

  say ""
  say "— Model setup —"
  say "TangentBar answers from a model running on YOUR machine (LM Studio or"
  say "Ollama). Ollama is the easiest way to serve one (single app, no account)."

  MODELS=$(collect_models)
  if [ -z "$MODELS" ]; then
    # Neither server had a usable model. The Ollama route is the one we can
    # walk a stranger through end-to-end, so nudge that way.
    if ! curl -fsS --max-time 2 "$OLLAMA/api/tags" >/dev/null 2>&1; then
      ask "No local model server is running. Open the Ollama download page now? [Y/n] "
      case "$ANS" in
        n|N) say "skipping model setup — TangentBar will discover models whenever a server appears."; return 0 ;;
      esac
      open "https://ollama.com/download"
      ask "Press return once Ollama is installed and running (or type skip): "
      [ "$ANS" = "skip" ] && return 0
      curl -fsS --max-time 2 "$OLLAMA/api/tags" >/dev/null 2>&1 || {
        say "still can't reach Ollama at $OLLAMA — skipping; TangentBar will find it once it's up."
        return 0
      }
    fi
    if ! list_ollama | grep -q .; then
      say ""
      say "Ollama is running but has no models yet."
      if command -v ollama >/dev/null 2>&1; then
        ask "Pull a small, fast one for definitions now? qwen3:1.7b, ~1.4 GB [Y/n] "
        case "$ANS" in n|N) ;; *) ollama pull qwen3:1.7b < /dev/tty > /dev/tty 2>&1 || true ;; esac
      else
        say "run 'ollama pull qwen3:1.7b' in a terminal, then relaunch TangentBar."
      fi
    fi
    MODELS=$(collect_models)
  fi

  # Claude models join the list after the local ones — pickable, never the
  # nudged default (local-first, D7).
  CLAUDE_MODELS=$(collect_claude_models)
  if [ -n "$CLAUDE_MODELS" ]; then
    if [ -n "$MODELS" ]; then
      MODELS=$(printf '%s\n%s' "$MODELS" "$CLAUDE_MODELS")
    else
      MODELS=$CLAUDE_MODELS
    fi
  fi
  [ -z "$MODELS" ] && return 0

  say ""
  say "Models found:"
  show_models

  say ""
  say "DEFINE model — answers the double-click definitions. Pick something very"
  say "small and lightweight (≤2B parameters): instant beats smart here."
  ask "number [1]: "
  N=$(printf '%s' "${ANS:-1}" | tr -cd '0-9')
  LINE=$(pick_line "${N:-1}")
  [ -z "$LINE" ] && LINE=$(pick_line 1)
  DEFINE=${LINE%%"$TAB"*}
  DEFINE_URL=${LINE##*"$TAB"}
  say "define model → $DEFINE"

  say ""
  say "CHAT model — powers the drag-to-chat conversations. This one wants real"
  say "quality (Sonnet/Opus-class or better). Locally that means a much bigger"
  say "model; the claude CLI entries are a natural fit here. Press return to"
  say "reuse the define model — when local fails, chats fall back to Sonnet"
  say "automatically anyway (if the claude CLI is installed)."
  show_models
  ask "number or return for same-as-define: "
  CHAT=""
  CHAT_URL=""
  N=$(printf '%s' "$ANS" | tr -cd '0-9')
  if [ -n "$N" ]; then
    LINE=$(pick_line "$N")
    if [ -n "$LINE" ]; then
      CHAT=${LINE%%"$TAB"*}
      CHAT_URL=${LINE##*"$TAB"}
    fi
  fi
  say "chat model → ${CHAT:-same as define}"

  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG" <<EOF
{
  "tangentModel": "$DEFINE",
  "localBaseURL": "$DEFINE_URL",
  "chatModel": "$CHAT",
  "chatLocalBaseURL": "$CHAT_URL"
}
EOF
  say "saved → $CONFIG"
}

if [ -c /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; then
  wizard
else
  say "(non-interactive shell — skipping model setup; TangentBar discovers local models on its own)"
fi

say ""
say "opening TangentBar… (macOS will ask for the Accessibility permission on first run —"
say "it's how TangentBar reads the text around your click; nothing leaves your machine)"
open "$DEST"
