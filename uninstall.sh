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

say() { printf '%s\n' "$*"; }

osascript -e 'quit app "TangentBar"' >/dev/null 2>&1 || true

if [ -d "$DEST" ]; then
  rm -rf "$DEST"
  say "removed $DEST"
else
  say "no app at $DEST (already removed)"
fi

tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true
say "cleared macOS permission entries for $BUNDLE_ID"

if [ "${1:-}" = "--keep-config" ]; then
  say "kept config at $CONFIG_DIR"
elif [ -d "$CONFIG_DIR" ]; then
  rm -rf "$CONFIG_DIR"
  say "removed $CONFIG_DIR"
fi

say "TangentBar uninstalled."
