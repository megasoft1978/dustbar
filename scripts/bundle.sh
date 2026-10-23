#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

plutil -lint Resources/Info.plist

# Apple silicon by default (smallest binary). UNIVERSAL=1 adds x86_64.
if [ "${UNIVERSAL:-0}" = "1" ]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
else
    swift build -c release
    BIN_DIR="$(swift build -c release --show-bin-path)"
fi

APP="build/DustBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/DustBar" "$APP/Contents/MacOS/DustBar"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
strip -x "$APP/Contents/MacOS/DustBar"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

SIZE=$(stat -f%z "$APP/Contents/MacOS/DustBar")
echo "Built $APP (binary: $SIZE bytes)"
