#!/bin/sh
# Build the distributable TangentBar.app + zip.
#
#   scripts/build-app.sh [version]
#
# Output: dist/TangentBar.app and dist/TangentBar-<version>.zip
# Signed with the persistent "TangentBar Release Signing" identity when it is
# in the keychain (scripts/make-signing-cert.sh) — a stable signature is what
# lets macOS TCC keep the user's Accessibility grant across updates. Falls
# back to ad-hoc for throwaway local builds (grant breaks on every rebuild).
# The zip is built with `ditto --keepParent` so Finder and the installer both
# unpack it correctly.

set -eu
cd "$(dirname "$0")/.."

VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo 0.1.0-dev)}"
VERSION="${VERSION#v}"
BUNDLE_ID="com.whorl.TangentBar"
APP="dist/TangentBar.app"

echo "==> swift build -c release"
swift build -c release

echo "==> assembling ${APP} (version ${VERSION})"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TangentBar "$APP/Contents/MacOS/TangentBar"

# Icon: iconset from the 1024 master, downscaled per slot.
if [ -f assets/icon@1024.png ]; then
  ICONSET="dist/icon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size assets/icon@1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) assets/icon@1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>TangentBar</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>TangentBar</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>${VERSION}</string>
	<key>CFBundleVersion</key><string>${VERSION}</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>LSUIElement</key><true/>
	<key>NSHumanReadableCopyright</key><string>© Joshua Anderson</string>
</dict>
</plist>
PLIST

SIGN_IDENTITY="${TANGENTBAR_SIGN_IDENTITY:-TangentBar Release Signing}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "==> codesign ($SIGN_IDENTITY)"
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
  echo "==> codesign (ad-hoc — WARNING: Accessibility grants will NOT survive"
  echo "    updates of this build; run scripts/make-signing-cert.sh for the"
  echo "    stable release identity)"
  codesign --force --sign - "$APP"
fi
codesign --verify --deep "$APP"
codesign -d -r- "$APP" 2>&1 | grep '^designated' || true

ZIP="dist/TangentBar-${VERSION}.zip"
echo "==> ${ZIP}"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "done:"
ls -lh dist/
