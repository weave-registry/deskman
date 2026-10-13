#!/usr/bin/env bash
# Build tooling: wrap the SwiftPM binary in build/Deskman.app.
# macOS grants Accessibility permission to a bundle identity, so the app must be a bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${CONFIG:-release}
swift build -c "$CONFIG" --explicit-target-dependency-import-check error
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Deskman"

APP=build/Deskman.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Deskman"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Deskman</string>
    <key>CFBundleDisplayName</key><string>Deskman</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID:-dev.deskman.app}</string>
    <key>CFBundleExecutable</key><string>Deskman</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Sign with a stable identity, so the Accessibility permission survives rebuilds.
# scripts/make-signing-identity.sh creates one. Without it, fall back to ad hoc,
# whose signature changes on every build and loses the permission.
IDENTITY=${SIGN_IDENTITY:-Deskman Local Signing}
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "warning: no '$IDENTITY' identity; signing ad hoc. Run scripts/make-signing-identity.sh." >&2
  IDENTITY=-
fi
codesign --force --sign "$IDENTITY" --identifier "${BUNDLE_ID:-dev.deskman.app}" "$APP"
codesign --verify "$APP"
echo "Built $APP"
