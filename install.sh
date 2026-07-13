#!/bin/sh
# TangentBar installer — the documented install path:
#
#   curl -fsSL https://raw.githubusercontent.com/Joshuatanderson/tangentbar/main/install.sh | sh
#
# Why a script instead of a plain download: curl never applies the
# com.apple.quarantine attribute, so Gatekeeper never evaluates the app and
# the ad-hoc signature opens clean — no "damaged" dialog, no Settings dance.
#
# What it does, verbatim: fetch the latest GitHub release zip, unpack it,
# move TangentBar.app into /Applications, walk you through picking local
# models (Ollama), open the app. Nothing else.

set -eu

REPO="${TANGENTBAR_REPO:-Joshuatanderson/tangentbar}"
DEST="/Applications/TangentBar.app"
OLLAMA="http://localhost:11434"
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

if [ -d "$DEST" ]; then
  # ${braces} required: bash 3.2 (/bin/sh) folds a trailing multibyte char
  # into the variable name and set -u aborts on the "unbound" result.
  say "replacing existing ${DEST}…"
  rm -rf "$DEST"
fi
mv "$TMP/TangentBar.app" "$DEST"
say "installed → $DEST"

# ------------------------------------------------------------ model wizard
# Interactive even under `curl | sh` (stdin is the pipe): prompts read from
# /dev/tty. No terminal, or already configured → skip; the app's own model
# discovery and menu handle everything later.

ask() {  # ask "prompt" -> $ANS
  printf '%s' "$1" > /dev/tty
  IFS= read -r ANS < /dev/tty
}

list_models() {
  curl -fsS --max-time 3 "$OLLAMA/api/tags" 2>/dev/null \
    | grep -o '"name":"[^"]*"' | sed 's/"name":"//;s/"$//'
}

wizard() {
  if [ -f "$CONFIG" ]; then
    say "existing TangentBar config found — keeping it (models are switchable from the menu-bar icon)."
    return 0
  fi

  say ""
  say "— Model setup —"
  say "TangentBar answers from a model running on YOUR machine. Ollama is the"
  say "easiest way to serve one (single app, no account)."

  if ! curl -fsS --max-time 2 "$OLLAMA/api/tags" >/dev/null 2>&1; then
    ask "Ollama isn't running. Open its download page now? [Y/n] "
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

  MODELS=$(list_models || true)
  if [ -z "$MODELS" ]; then
    say ""
    say "Ollama is running but has no models yet."
    if command -v ollama >/dev/null 2>&1; then
      ask "Pull a small, fast one for definitions now? qwen3:1.7b, ~1.4 GB [Y/n] "
      case "$ANS" in n|N) ;; *) ollama pull qwen3:1.7b < /dev/tty > /dev/tty 2>&1 || true ;; esac
      MODELS=$(list_models || true)
    else
      say "run 'ollama pull qwen3:1.7b' in a terminal, then relaunch TangentBar."
    fi
  fi
  [ -z "$MODELS" ] && return 0

  say ""
  say "Local models found:"
  i=0
  for m in $MODELS; do i=$((i+1)); say "  $i) $m"; done

  say ""
  say "DEFINE model — answers the double-click definitions. Pick something very"
  say "small and lightweight (≤2B parameters): instant beats smart here."
  ask "number [1]: "
  N=$(printf '%s' "${ANS:-1}" | tr -cd '0-9')
  DEFINE=$(printf '%s\n' "$MODELS" | sed -n "${N:-1}p")
  [ -z "$DEFINE" ] && DEFINE=$(printf '%s\n' "$MODELS" | sed -n 1p)
  say "define model → $DEFINE"

  say ""
  say "CHAT model — powers the drag-to-chat conversations. This one wants real"
  say "quality (Sonnet/Opus-class or better), which locally means a much bigger"
  say "model. Press return to reuse the define model for now; if the claude CLI"
  say "is installed, chats fall back to Sonnet automatically when local fails."
  ask "number or return for same-as-define: "
  CHAT=""
  N=$(printf '%s' "$ANS" | tr -cd '0-9')
  if [ -n "$N" ]; then
    CHAT=$(printf '%s\n' "$MODELS" | sed -n "${N}p")
  fi
  say "chat model → ${CHAT:-same as define}"

  mkdir -p "$CONFIG_DIR"
  CHAT_URL=""
  [ -n "$CHAT" ] && CHAT_URL="$OLLAMA/v1"
  cat > "$CONFIG" <<EOF
{
  "tangentModel": "$DEFINE",
  "localBaseURL": "$OLLAMA/v1",
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
