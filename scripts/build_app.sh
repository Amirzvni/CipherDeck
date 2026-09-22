#!/bin/bash
# Builds dist/CipherDeck.app: release build, bundle, Hardened Runtime + ad-hoc signature.
# No Apple Developer account required.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"

VERSION="$(cat VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="dist/CipherDeck.app"

echo "▶ Running self-tests"
swift run -c release CipherDeckSelfTest | tail -1

echo "▶ Building CipherDeck $VERSION ($BUILD)"
swift build -c release --product CipherDeck
BIN="$(swift build -c release --show-bin-path)/CipherDeck"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CipherDeck"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
strip -x "$APP/Contents/MacOS/CipherDeck" 2>/dev/null || true

echo "▶ Signing (ad-hoc, Hardened Runtime)"
codesign --force --options runtime --timestamp=none \
    --entitlements Resources/CipherDeck.entitlements \
    --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "device.camera"

echo "✓ $APP"
