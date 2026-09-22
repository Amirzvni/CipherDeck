#!/bin/bash
# Regenerates Resources/AppIcon.icns and Resources/logo.png from scripts/generate_icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
swift scripts/generate_icon.swift Resources
iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
rm -rf Resources/AppIcon.iconset
echo "✓ Resources/AppIcon.icns"
