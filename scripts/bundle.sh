#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/DustBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/DustBar" "$APP/Contents/MacOS/DustBar"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
strip -x "$APP/Contents/MacOS/DustBar"
codesign --force --sign - "$APP"

SIZE=$(stat -f%z "$APP/Contents/MacOS/DustBar")
echo "Built $APP (binary: $SIZE bytes)"
