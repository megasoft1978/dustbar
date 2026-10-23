#!/usr/bin/env bash
# Build, install to /Applications (replacing any running copy) and launch.
# Signs with $SIGN_IDENTITY, else the local "DustBar Local Signing" identity if present (keeps privacy grants
# like Full Disk Access across reinstalls), else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/bundle.sh
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && security find-identity -p codesigning | grep -q "DustBar Local Signing"; then
    SIGN_IDENTITY="DustBar Local Signing"
fi
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --options runtime --sign "$SIGN_IDENTITY" build/DustBar.app
    codesign --verify --strict build/DustBar.app
fi

DEST="/Applications/DustBar.app"
pkill -x DustBar 2>/dev/null || true
for _ in 1 2 3 4 5; do pgrep -x DustBar >/dev/null || break; sleep 1; done

rm -rf "$DEST"
cp -R build/DustBar.app "$DEST"
xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1 || true
codesign --verify --strict "$DEST"
open "$DEST"
echo "Installed $DEST"
