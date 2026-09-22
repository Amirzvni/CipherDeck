#!/bin/bash
# Produces dist/CipherDeck-<version>.dmg (drag-to-Applications layout).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
./scripts/build_app.sh

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R dist/CipherDeck.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="dist/CipherDeck-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "CipherDeck $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
hdiutil verify "$DMG" >/dev/null
shasum -a 256 "$DMG" | tee "$DMG.sha256"
echo "✓ $DMG"
