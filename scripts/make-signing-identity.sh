#!/usr/bin/env bash
# Build tooling: create a self-signed code-signing identity in the login keychain.
# A stable identity gives every build the same designated requirement, so the
# Accessibility permission survives rebuilds (an ad-hoc signature does not).
set -euo pipefail

NAME=${SIGN_IDENTITY:-Deskman Local Signing}
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Identity '$NAME' already exists."
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pass=$(openssl rand -hex 16)

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$work/key.pem" -out "$work/cert.pem" -subj "/CN=$NAME" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
# -legacy: the macOS keychain cannot read OpenSSL 3's default PKCS#12 encryption.
openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" \
  -name "$NAME" -out "$work/id.p12" -passout "pass:$pass"
security import "$work/id.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null

echo "Created '$NAME' in the login keychain."
