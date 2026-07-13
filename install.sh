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
# move TangentBar.app into /Applications, open it. Nothing else.

set -eu

REPO="${TANGENTBAR_REPO:-Joshuatanderson/tangentbar}"
DEST="/Applications/TangentBar.app"

echo "TangentBar installer — fetching the latest release of ${REPO}…"

API="https://api.github.com/repos/${REPO}/releases/latest"
URL=$(curl -fsSL "$API" \
  | grep -o '"browser_download_url": *"[^"]*TangentBar[^"]*\.zip"' \
  | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')

if [ -z "$URL" ]; then
  echo "error: no release zip found at ${API}" >&2
  echo "       (check https://github.com/${REPO}/releases)" >&2
  exit 1
fi

TMP=$(mktemp -d /tmp/tangentbar.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

echo "downloading $(basename "$URL")…"
curl -fsSL -o "$TMP/TangentBar.zip" "$URL"

# ditto preserves the bundle structure and the code signature.
ditto -xk "$TMP/TangentBar.zip" "$TMP"
[ -d "$TMP/TangentBar.app" ] || { echo "error: zip did not contain TangentBar.app" >&2; exit 1; }

if [ -d "$DEST" ]; then
  echo "replacing existing $DEST…"
  rm -rf "$DEST"
fi
mv "$TMP/TangentBar.app" "$DEST"

echo "installed → $DEST"
echo "opening… (macOS will ask for the Accessibility permission on first run)"
open "$DEST"
