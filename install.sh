#!/bin/sh
# TangentBar installer — the documented install path:
#
#   interactive:  curl -fsSL https://raw.githubusercontent.com/Joshuatanderson/tangentbar/main/install.sh | sh
#   headless:     curl -fsSL .../install.sh | sh -s -- --headless [--define-model <id>] [--chat-model <id>] [--no-open]
#
# Why a script instead of a plain download: curl never applies the
# com.apple.quarantine attribute, so Gatekeeper never evaluates the app and
# the self-signed signature opens clean — no "damaged" dialog, no Settings dance.
#
# What it does, verbatim: fetch the latest GitHub release zip, unpack it,
# move TangentBar.app into /Applications, walk you through picking local
# models (Ollama, LM Studio), open the app. Nothing else.
#
# Headless mode (agents, CI, dotfiles): no prompts, no /dev/tty needed.
#   --headless            skip the wizard even on a real terminal
#   --define-model <id>   write config: model for double-click definitions
#   --chat-model <id>     write config: model for drag-to-chat conversations
#   --no-open             don't launch the app afterwards
# Env equivalents: TANGENTBAR_HEADLESS=1, TANGENTBAR_DEFINE_MODEL,
# TANGENTBAR_CHAT_MODEL, TANGENTBAR_NO_OPEN=1. Model ids must be served by
# Ollama/LM Studio at install time, or be a claude CLI model
# (haiku/sonnet/opus/fable). Without model flags no config is written — the
# app discovers models on its own.

set -eu

REPO="${TANGENTBAR_REPO:-Joshuatanderson/tangentbar}"
DEST="/Applications/TangentBar.app"
OLLAMA="http://localhost:11434"
LMSTUDIO="http://localhost:1234"
CONFIG_DIR="$HOME/Library/Application Support/TangentBar"
CONFIG="$CONFIG_DIR/config.json"
TAB=$(printf '\t')

# ------------------------------------------------------------------- ui
# The Oathbound-CLI look (clack-style gutter + diamonds) in dependency-free
# POSIX sh. Honors NO_COLOR (https://no-color.org) and non-TTY stdout.

if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  ACC='' DIM='' BLD='' GRN='' RED='' YLW='' RST=''
else
  ACC=$(printf '\033[38;2;122;146;224m')   # app accent #3a4d8f, lifted for dark terminals
  DIM=$(printf '\033[2m')  BLD=$(printf '\033[1m')
  GRN=$(printf '\033[32m') RED=$(printf '\033[31m')
  YLW=$(printf '\033[33m') RST=$(printf '\033[0m')
fi

say()   { printf '%s│%s  %s\n' "$DIM" "$RST" "$*"; }            # gutter text
step()  { printf '%s◇%s  %s\n' "$ACC" "$RST" "$*"; }            # milestone
ok()    { printf '%s✓%s  %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '%s▲%s  %s\n' "$YLW" "$RST" "$*"; }
die()   { printf '%s✗  %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }
intro() { printf '\n%s%s─◠─ tangentbar%s  %s%s%s\n%s│%s\n' "$ACC" "$BLD" "$RST" "$DIM" "$1" "$RST" "$DIM" "$RST"; }
outro() { printf '%s└%s  %s\n\n' "$DIM" "$RST" "$*"; }

usage() {
  printf '%s\n' "tangentbar installer
  interactive:  curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sh
  headless:     curl -fsSL .../install.sh | sh -s -- --headless [options]

  --headless            no prompts (auto when there is no terminal)
  --define-model <id>   config: model for double-click definitions
  --chat-model <id>     config: model for drag-to-chat conversations
  --no-open             don't launch the app afterwards
  --help                this text

  env: TANGENTBAR_HEADLESS=1  TANGENTBAR_DEFINE_MODEL  TANGENTBAR_CHAT_MODEL
       TANGENTBAR_NO_OPEN=1   TANGENTBAR_REPO"
}

# ------------------------------------------------------------------ flags
HEADLESS="${TANGENTBAR_HEADLESS:-}"
NO_OPEN="${TANGENTBAR_NO_OPEN:-}"
DEFINE_REQ="${TANGENTBAR_DEFINE_MODEL:-}"
CHAT_REQ="${TANGENTBAR_CHAT_MODEL:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --headless) HEADLESS=1 ;;
    --no-open)  NO_OPEN=1 ;;
    --define-model)   [ $# -ge 2 ] || die "--define-model needs a value"; DEFINE_REQ=$2; shift ;;
    --define-model=*) DEFINE_REQ=${1#*=} ;;
    --chat-model)     [ $# -ge 2 ] || die "--chat-model needs a value"; CHAT_REQ=$2; shift ;;
    --chat-model=*)   CHAT_REQ=${1#*=} ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done
# Passing models implies you don't want prompts.
if [ -n "$DEFINE_REQ" ] || [ -n "$CHAT_REQ" ]; then HEADLESS=1; fi

# ---------------------------------------------------------------- download
intro "installer"
say "fetching the latest release of ${REPO}…"

API="https://api.github.com/repos/${REPO}/releases/latest"
URL=$(curl -fsSL "$API" \
  | grep -o '"browser_download_url": *"[^"]*TangentBar[^"]*\.zip"' \
  | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')

[ -n "$URL" ] || die "no release zip found at ${API} (check https://github.com/${REPO}/releases)"

TMP=$(mktemp -d /tmp/tangentbar.XXXXXX)
# Also restore the terminal if we die mid-menu (raw mode, hidden cursor).
trap 'rm -rf "$TMP"; if [ -n "${M_OLDSTTY:-}" ]; then { stty "$M_OLDSTTY" < /dev/tty; printf "\033[?25h" > /dev/tty; } 2>/dev/null || true; fi' EXIT

say "downloading $(basename "$URL")…"
curl -fsSL -o "$TMP/TangentBar.zip" "$URL"

# ditto preserves the bundle structure and the code signature.
ditto -xk "$TMP/TangentBar.zip" "$TMP"
[ -d "$TMP/TangentBar.app" ] || die "zip did not contain TangentBar.app"

# macOS TCC keys the Accessibility grant to the app's code signature
# (designated requirement). If the incoming build's signature differs from
# the installed one — always true for the old ad-hoc builds — the existing
# grant silently dies, while its toggle stays ON in System Settings and
# re-toggling never revives it. Drop the stale entry so the app can re-prompt
# cleanly. Same story when the app is gone but a leftover entry lingers.
# Order matters: the app must be fully dead before the reset, or its 2 s
# permission poll re-registers a TCC entry keyed to the old signature.
OLD_REQ=""
if [ -d "$DEST" ]; then
  OLD_REQ=$(codesign -d -r- "$DEST" 2>&1 | grep '^designated' || true)
  # ${braces} required: bash 3.2 (/bin/sh) folds a trailing multibyte char
  # into the variable name and set -u aborts on the "unbound" result.
  say "replacing existing ${DEST}…"
  osascript -e 'quit app "TangentBar"' >/dev/null 2>&1 || true
  sleep 1
  pkill -x TangentBar >/dev/null 2>&1 || true
  rm -rf "$DEST"
fi
mv "$TMP/TangentBar.app" "$DEST"
ok "installed → $DEST"

NEW_REQ=$(codesign -d -r- "$DEST" 2>&1 | grep '^designated' || true)
if [ -z "$OLD_REQ" ] || [ "$OLD_REQ" != "$NEW_REQ" ]; then
  tccutil reset Accessibility com.whorl.TangentBar >/dev/null 2>&1 || true
  if [ -n "$OLD_REQ" ]; then
    say "note: this build's code signature differs from the installed one, so"
    say "macOS invalidated the old Accessibility grant. Cleared it — TangentBar"
    say "will ask for Accessibility again on launch."
  fi
fi

# ------------------------------------------------------------ model wizard
# Interactive even under `curl | sh` (stdin is the pipe): prompts read from
# /dev/tty. No terminal, headless flag, or already configured → skip; the
# app's own model discovery and menu handle everything later.

ask() {  # ask "prompt" -> $ANS
  printf '%s◆%s  %s' "$ACC" "$RST" "$1" > /dev/tty
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

model_labels() {  # one display label per $MODELS line, serving app named
  printf '%s\n' "$MODELS" | while IFS="$TAB" read -r m u; do
    case "$u" in
      "$LMSTUDIO"*) s="LM Studio" ;;
      "$OLLAMA"*)   s="Ollama" ;;
      *)            s="claude CLI" ;;
    esac
    printf '%s  (%s)\n' "$m" "$s"
  done
}

# ---- arrow-key menu (clack-style), still zero dependencies ----------------
# menu_select "<label lines>" <initial index> -> $MENU_IDX (1-based).
# ↑↓ / j k move, return selects, 1-9 jumps. Renders to /dev/tty and collapses
# to nothing when done (the caller prints the chosen value). Falls back to a
# numeric prompt when the tty can't do raw mode.
M_OLDSTTY=""
ESCCH=$(printf '\033')

m_draw() {  # $1 = 1 → repaint over the previous render
  {
    [ "${1:-0}" = 1 ] && printf '\033[%dA' $((M_COUNT + 1))
    i=0
    printf '%s\n' "$M_LINES" | while IFS= read -r line; do
      i=$((i+1))
      if [ "$i" -eq "$M_CUR" ]; then
        printf '\r\033[2K%s│%s  %s%s❯ %s%s\n' "$DIM" "$RST" "$ACC" "$BLD" "$line" "$RST"
      else
        printf '\r\033[2K%s│    %s%s\n' "$DIM" "$line" "$RST"
      fi
    done
    printf '\r\033[2K%s│  ↑↓ move · return select%s\n' "$DIM" "$RST"
  } > /dev/tty
}

m_clear() {  # erase the rendered menu, leave the cursor where it began
  {
    printf '\033[%dA' $((M_COUNT + 1))
    i=0
    while [ "$i" -le "$M_COUNT" ]; do printf '\r\033[2K\n'; i=$((i+1)); done
    printf '\033[%dA' $((M_COUNT + 1))
  } > /dev/tty
}

menu_select() {
  M_LINES=$1
  M_COUNT=$(printf '%s\n' "$M_LINES" | grep -c .)
  M_CUR=${2:-1}
  if [ "$M_COUNT" -le 1 ]; then MENU_IDX=1; return 0; fi
  if ! M_OLDSTTY=$(stty -g < /dev/tty 2>/dev/null); then
    # No raw tty (weird shells): plain numeric prompt.
    i=0
    printf '%s\n' "$M_LINES" | while IFS= read -r line; do
      i=$((i+1)); printf '%s│%s   %s%d)%s %s\n' "$DIM" "$RST" "$BLD" "$i" "$RST" "$line"
    done > /dev/tty
    ask "number [${M_CUR}]: "
    N=$(printf '%s' "${ANS:-$M_CUR}" | tr -cd '0-9')
    { [ -n "$N" ] && [ "$N" -ge 1 ] && [ "$N" -le "$M_COUNT" ]; } || N=$M_CUR
    MENU_IDX=$N
    return 0
  fi
  stty -icanon -echo min 1 time 0 < /dev/tty
  printf '\033[?25l' > /dev/tty
  m_draw 0
  while :; do
    key=$(dd bs=1 count=1 < /dev/tty 2>/dev/null || true)
    case "$key" in
      "")  break ;;  # return (the captured newline is stripped)
      j)   M_CUR=$((M_CUR % M_COUNT + 1)) ;;
      k)   M_CUR=$(( (M_CUR + M_COUNT - 2) % M_COUNT + 1 )) ;;
      [1-9])
        if [ "$key" -le "$M_COUNT" ]; then M_CUR=$key; m_draw 1; break; fi ;;
      "$ESCCH")
        stty min 0 time 2 < /dev/tty
        b2=$(dd bs=1 count=1 < /dev/tty 2>/dev/null || true)
        b3=$(dd bs=1 count=1 < /dev/tty 2>/dev/null || true)
        stty min 1 time 0 < /dev/tty
        if [ "$b2" = "[" ]; then
          case "$b3" in
            A) M_CUR=$(( (M_CUR + M_COUNT - 2) % M_COUNT + 1 )) ;;
            B) M_CUR=$((M_CUR % M_COUNT + 1)) ;;
          esac
        fi ;;
    esac
    m_draw 1
  done
  m_clear
  stty "$M_OLDSTTY" < /dev/tty
  M_OLDSTTY=""
  printf '\033[?25h' > /dev/tty
  MENU_IDX=$M_CUR
}

pick_line() {  # pick_line <number> -> "<id><TAB><baseURL>" (empty if out of range)
  printf '%s\n' "$MODELS" | sed -n "${1}p"
}

# Claude models join the list after the local ones — pickable, never the
# nudged default (local-first, D7).
gather_all_models() {
  MODELS=$(collect_models)
  CLAUDE_MODELS=$(collect_claude_models)
  if [ -n "$CLAUDE_MODELS" ]; then
    if [ -n "$MODELS" ]; then
      MODELS=$(printf '%s\n%s' "$MODELS" "$CLAUDE_MODELS")
    else
      MODELS=$CLAUDE_MODELS
    fi
  fi
}

resolve_url() {  # resolve_url <model-id> -> base URL on stdout, or nothing
  printf '%s\n' "$MODELS" | awk -F"$TAB" -v m="$1" '$1==m{print $2; exit}'
}

write_config() {  # write_config <define> <defineURL> <chat> <chatURL>
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG" <<EOF
{
  "tangentModel": "$1",
  "localBaseURL": "$2",
  "chatModel": "$3",
  "chatLocalBaseURL": "$4"
}
EOF
  ok "saved → $CONFIG"
}

headless_config() {
  [ -n "$DEFINE_REQ" ] || [ -n "$CHAT_REQ" ] || return 0
  if [ -f "$CONFIG" ]; then
    warn "config already exists at $CONFIG — keeping it; requested models NOT applied"
    say "(switch models from the menu-bar icon, or edit the file)"
    return 0
  fi
  gather_all_models
  D_MODEL="$DEFINE_REQ" C_MODEL="$CHAT_REQ" D_URL="" C_URL=""
  if [ -n "$D_MODEL" ]; then
    D_URL=$(resolve_url "$D_MODEL")
    [ -n "$D_URL" ] || die "define model '$D_MODEL' not found (not served by Ollama/LM Studio, not a claude CLI model) — app installed, config not written"
  fi
  if [ -n "$C_MODEL" ]; then
    C_URL=$(resolve_url "$C_MODEL")
    [ -n "$C_URL" ] || die "chat model '$C_MODEL' not found (not served by Ollama/LM Studio, not a claude CLI model) — app installed, config not written"
  fi
  if [ -z "$D_MODEL" ] && [ -n "$C_MODEL" ]; then
    # Config needs a define model; borrow the chat pick rather than fail.
    D_MODEL=$C_MODEL D_URL=$C_URL
  fi
  write_config "$D_MODEL" "$D_URL" "$C_MODEL" "$C_URL"
  step "define model → $D_MODEL"
  step "chat model → ${C_MODEL:-same as define}"
}

wizard() {
  if [ -f "$CONFIG" ]; then
    say "existing TangentBar config found — keeping it (models are switchable from the menu-bar icon)."
    return 0
  fi

  say ""
  step "model setup"
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
        warn "still can't reach Ollama at $OLLAMA — skipping; TangentBar will find it once it's up."
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
  fi

  gather_all_models
  [ -z "$MODELS" ] && return 0
  LABELS=$(model_labels)

  say ""
  step "${BLD}DEFINE model${RST} — answers double-click definitions. Small and instant beats smart (≤2B ideal)."
  menu_select "$LABELS" 1
  LINE=$(pick_line "$MENU_IDX")
  DEFINE=${LINE%%"$TAB"*}
  DEFINE_URL=${LINE##*"$TAB"}
  step "define model → ${BLD}$DEFINE${RST}"

  say ""
  step "${BLD}CHAT model${RST} — powers drag-to-chat. Wants real quality (Sonnet/Opus-class); the claude CLI entries fit here."
  CHAT_MENU=$(printf '%s\n%s' "Same as define  (local fails → Sonnet fallback)" "$LABELS")
  menu_select "$CHAT_MENU" 1
  CHAT=""
  CHAT_URL=""
  if [ "$MENU_IDX" -gt 1 ]; then
    LINE=$(pick_line $((MENU_IDX - 1)))
    CHAT=${LINE%%"$TAB"*}
    CHAT_URL=${LINE##*"$TAB"}
  fi
  step "chat model → ${BLD}${CHAT:-same as define}${RST}"

  write_config "$DEFINE" "$DEFINE_URL" "$CHAT" "$CHAT_URL"
}

if [ -n "$HEADLESS" ]; then
  headless_config
elif [ -c /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; then
  wizard
else
  say "(non-interactive shell — skipping model setup; TangentBar discovers local models on its own)"
fi

say ""
if [ -n "$NO_OPEN" ]; then
  outro "installed. Launch /Applications/TangentBar.app when ready — macOS will ask for the Accessibility permission on first run."
else
  say "opening TangentBar… (macOS will ask for the Accessibility permission on first run —"
  say "it's how TangentBar reads the text around your click; nothing leaves your machine)"
  open "$DEST"
  outro "double-click any word to take a tangent."
fi
