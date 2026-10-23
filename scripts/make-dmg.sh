#!/usr/bin/env bash
# Package an app bundle into a compressed DMG: DustBar.app + Applications symlink, volume "DustBar".
# Usage: scripts/make-dmg.sh <app-path> <output.dmg>
# Signs the DMG with $SIGN_IDENTITY, else the local "DustBar Local Signing" identity if present, else leaves it unsigned
# (same identity logic as scripts/install.sh). No AppleScript/Finder scripting.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <app-path> <output.dmg>" >&2
    exit 2
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
OUT_DIR="$(cd "$(dirname "$2")" && pwd)"
DMG="$OUT_DIR/$(basename "$2")"
VOLNAME="DustBar"
ICON="$ROOT/Resources/AppIcon.icns"

if [ ! -d "$APP_SRC" ]; then
    echo "not an app bundle: $APP_SRC" >&2
    exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dustbar-dmg.XXXXXX")"
MNT="$WORK/mnt"
STAGE="$WORK/stage"
TMP_DMG="$WORK/$(basename "$DMG")"
mkdir -p "$MNT" "$STAGE"
ATTACHED=0

cleanup() {
    if [ "$ATTACHED" = 1 ]; then
        hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach -force "$MNT" >/dev/null 2>&1 || true
    fi
    if [ -n "$WORK" ] && [ -d "$WORK" ]; then
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

APP_NAME="$(basename "$APP_SRC")"
cp -R "$APP_SRC" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"

# Optional volume icon: hidden .VolumeIcon.icns plus the custom-icon flag on the volume root. hdiutil -srcfolder
# drops that root flag, so set it on a writable image, then convert to compressed.
RW_DMG="$WORK/rw.dmg"
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW "$RW_DMG"
if [ -f "$ICON" ] && command -v SetFile >/dev/null 2>&1; then
    ATTACHED=1
    hdiutil attach -nobrowse -noautoopen -mountpoint "$MNT" "$RW_DMG" >/dev/null
    cp "$ICON" "$MNT/.VolumeIcon.icns"
    SetFile -a C "$MNT"
    hdiutil detach "$MNT" >/dev/null || hdiutil detach -force "$MNT" >/dev/null
    ATTACHED=0
fi
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$TMP_DMG"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && security find-identity -p codesigning | grep -F "DustBar Local Signing" >/dev/null; then
    SIGN_IDENTITY="DustBar Local Signing"
fi
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$TMP_DMG"
    codesign --verify --verbose=2 "$TMP_DMG"
fi

hdiutil verify "$TMP_DMG" >/dev/null

# Inspect the image as shipped, then detach (always, via the EXIT trap).
ATTACHED=1
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MNT" "$TMP_DMG" >/dev/null
test -d "$MNT/$APP_NAME" || { echo "missing $APP_NAME in DMG" >&2; exit 1; }
test -L "$MNT/Applications" || { echo "missing Applications symlink in DMG" >&2; exit 1; }
test "$(readlink "$MNT/Applications")" = "/Applications" || { echo "Applications is not a link to /Applications" >&2; exit 1; }
codesign --verify --strict "$MNT/$APP_NAME"
hdiutil detach "$MNT" >/dev/null || hdiutil detach -force "$MNT" >/dev/null
ATTACHED=0

mv -f "$TMP_DMG" "$DMG"
echo "Built $DMG ($(stat -f%z "$DMG") bytes, volume $VOLNAME, signed: ${SIGN_IDENTITY:-no})"
