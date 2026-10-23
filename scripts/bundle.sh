#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

plutil -lint Resources/Info.plist

# DEMO=1 builds the synthetic-data demo app (build/DustBarDemo.app, separate bundle id) in its own scratch dir.
# The normal build never compiles demo code.
BUILD_ARGS=(-c release)
if [ "${DEMO:-0}" = "1" ]; then
    BUILD_ARGS+=(--scratch-path .build/demo-scratch -Xswiftc -DDUSTBAR_DEMO)
    APP="build/DustBarDemo.app"
    EXE="DustBarDemo"
else
    APP="build/DustBar.app"
    EXE="DustBar"
fi

# Apple silicon by default (smallest binary). UNIVERSAL=1 adds x86_64.
if [ "${UNIVERSAL:-0}" = "1" ]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/DustBar" "$APP/Contents/MacOS/$EXE"
mkdir -p "$APP/Contents/Resources"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ "${DEMO:-0}" = "1" ]; then
    PLIST="$APP/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string com.megasoft78.dustbar.demo "$PLIST"
    plutil -replace CFBundleName -string "DustBar Demo" "$PLIST"
    plutil -replace CFBundleDisplayName -string "DustBar Demo" "$PLIST"
    plutil -replace CFBundleExecutable -string "$EXE" "$PLIST"
fi
strip -x "$APP/Contents/MacOS/$EXE"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

SIZE=$(stat -f%z "$APP/Contents/MacOS/$EXE")
echo "Built $APP (binary: $SIZE bytes)"
