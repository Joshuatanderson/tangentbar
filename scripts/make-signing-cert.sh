#!/bin/sh
# Create the persistent TangentBar code-signing identity (one-time setup).
#
#   scripts/make-signing-cert.sh [--force]
#
# macOS TCC keys permission grants (Accessibility etc.) to an app's code
# signature. Ad-hoc signatures change every build, so each update silently
# invalidated the user's grant. Signing every release with ONE long-lived
# self-signed identity gives the app a stable designated requirement
# (`identifier + certificate leaf`), and grants survive updates.
#
# This script:
#   1. generates a 10-year self-signed code-signing cert + key
#   2. stores them (plus a legacy-format .p12 for CI) in ~/.config/tangentbar/signing
#   3. imports the identity into your login keychain for local release builds
#   4. registers system trust for it (one sudo prompt)
#   5. uploads the .p12 + password as GitHub Actions secrets via `gh`
#
# DO NOT regenerate casually: a new cert = a new signature = every user
# re-grants Accessibility on their next update. That is the exact bug this
# identity exists to prevent. Hence the --force guard.

set -eu

NAME="TangentBar Release Signing"
DIR="$HOME/.config/tangentbar/signing"
REPO="Joshuatanderson/tangentbar"

if [ -d "$DIR" ] && [ "${1:-}" != "--force" ]; then
  echo "error: $DIR already exists — the signing identity is meant to live forever." >&2
  echo "Regenerating breaks Accessibility-grant continuity for every user." >&2
  echo "If you really mean it: scripts/make-signing-cert.sh --force" >&2
  exit 1
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
cd "$DIR"

echo "==> generating key + certificate ($NAME, 10 years)"
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -days 3650 -nodes -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" 2>/dev/null

PASS=$(openssl rand -hex 16)
printf '%s' "$PASS" > p12-pass.txt
chmod 600 key.pem p12-pass.txt

# -legacy: macOS `security import` cannot parse OpenSSL 3's modern PKCS12
# defaults (fails with "MAC verification failed").
echo "==> packaging signing.p12 (legacy format for macOS/CI import)"
openssl pkcs12 -export -legacy -out signing.p12 -inkey key.pem -in cert.pem \
  -name "$NAME" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
       -macalg sha1 -out signing.p12 -inkey key.pem -in cert.pem \
       -name "$NAME" -passout "pass:$PASS"
chmod 600 signing.p12

echo "==> importing identity into login keychain"
security import signing.p12 -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign

echo "==> registering system trust (sudo — codesign refuses untrusted identities)"
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
  -k /Library/Keychains/System.keychain cert.pem

if command -v gh >/dev/null 2>&1; then
  echo "==> uploading GitHub Actions secrets to $REPO"
  base64 -i signing.p12 | gh secret set MACOS_SIGN_P12_B64 --repo "$REPO"
  gh secret set MACOS_SIGN_P12_PASS --repo "$REPO" --body "$PASS"
else
  echo "gh not found — set these secrets on $REPO manually:"
  echo "  MACOS_SIGN_P12_B64  = base64 of $DIR/signing.p12"
  echo "  MACOS_SIGN_P12_PASS = contents of $DIR/p12-pass.txt"
fi

echo ""
echo "done. Identity \"$NAME\" is ready:"
security find-identity -v -p codesigning | grep "$NAME" || true
echo "Backup $DIR somewhere safe — losing it means a new cert and one more"
echo "round of re-granting Accessibility for every user."
