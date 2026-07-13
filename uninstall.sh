#!/bin/sh
# TangentBar uninstaller — the documented removal path:
#
#   curl -fsSL https://raw.githubusercontent.com/Joshuatanderson/tangentbar/main/uninstall.sh | sh
#
# Removes everything the installer created, in the order that avoids the one
# classic macOS trap: a TCC Accessibility entry left behind after the app is
# gone looks granted in System Settings but matches nothing, and a later
# reinstall inherits a dead toggle that off/on can't fix. So the TCC entries
# go too.
#
#   1. quit the running app
#   2. delete /Applications/TangentBar.app
#   3. drop the TCC permission entries (Accessibility + Input Monitoring)
#   4. delete the config directory (pass --keep-config to keep model picks)

set -eu

DEST="/Applications/TangentBar.app"
CONFIG_DIR="$HOME/Library/Application Support/TangentBar"
BUNDLE_ID="com.whorl.TangentBar"

# Same dependency-free clack-style ui as install.sh (NO_COLOR + TTY aware).
if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  ACC='' DIM='' BLD='' GRN='' RST=''
else
  ACC=$(printf '\033[38;2;122;146;224m')
  DIM=$(printf '\033[2m') BLD=$(printf '\033[1m')
  GRN=$(printf '\033[32m') RST=$(printf '\033[0m')
fi
say()   { printf '%s│%s  %s\n' "$DIM" "$RST" "$*"; }
ok()    { printf '%s✓%s  %s\n' "$GRN" "$RST" "$*"; }
intro() { printf '\n%s%s─◠─ tangentbar%s  %s%s%s\n%s│%s\n' "$ACC" "$BLD" "$RST" "$DIM" "$1" "$RST" "$DIM" "$RST"; }
outro() { printf '%s└%s  %s\n\n' "$DIM" "$RST" "$*"; }

intro "uninstaller"

osascript -e 'quit app "TangentBar"' >/dev/null 2>&1 || true
sleep 1
pkill -x TangentBar >/dev/null 2>&1 || true

if [ -d "$DEST" ]; then
  rm -rf "$DEST"
  ok "removed $DEST"
else
  say "no app at $DEST (already removed)"
fi

tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true
ok "cleared macOS permission entries for $BUNDLE_ID"

if [ "${1:-}" = "--keep-config" ]; then
  say "kept config at $CONFIG_DIR"
elif [ -d "$CONFIG_DIR" ]; then
  rm -rf "$CONFIG_DIR"
  ok "removed $CONFIG_DIR"
fi

outro "TangentBar uninstalled."
