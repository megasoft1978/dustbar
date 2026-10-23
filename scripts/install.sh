#!/usr/bin/env bash
# Build, install to /Applications (replacing any running copy) and launch.
# SIGN_IDENTITY="<codesign identity>" bash scripts/install.sh   # optional; default is ad-hoc
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/bundle.sh
if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --sign "$SIGN_IDENTITY" build/DustBar.app
    codesign --verify --strict build/DustBar.app
fi

DEST="/Applications/DustBar.app"
pkill -x DustBar 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x DustBar >/dev/null || break; sleep 1; done

rm -rf "$DEST"
cp -R build/DustBar.app "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --verify --strict "$DEST"
open "$DEST"
echo "Installed $DEST"
