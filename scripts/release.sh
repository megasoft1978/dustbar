#!/usr/bin/env bash
# Build and package a release into dist/: DustBar-<ver>.zip, DustBar-<ver>.dmg, SHA256SUMS, dustbar.rb (Homebrew cask).
# Signing matches scripts/install.sh ($SIGN_IDENTITY, else "DustBar Local Signing" if present, else ad-hoc).
# Makes no network calls and publishes nothing; the gh command is printed for the owner to run.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
APP="build/DustBar.app"
DIST="dist"
ZIP="DustBar-$VERSION.zip"
DMG="DustBar-$VERSION.dmg"
TEMPLATE="packaging/homebrew/Casks/dustbar.rb.template"

bash scripts/bundle.sh

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && security find-identity -p codesigning | grep -F "DustBar Local Signing" >/dev/null; then
    SIGN_IDENTITY="DustBar Local Signing"
fi
if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

mkdir -p "$DIST"
rm -f "$DIST/$ZIP" "$DIST/$DMG" "$DIST/SHA256SUMS" "$DIST/dustbar.rb"

ditto -c -k --keepParent "$APP" "$DIST/$ZIP"
bash scripts/make-dmg.sh "$APP" "$DIST/$DMG"

(cd "$DIST" && shasum -a 256 "$ZIP" "$DMG" > SHA256SUMS)
DMG_SHA="$(awk -v f="$DMG" '$2 == f {print $1}' "$DIST/SHA256SUMS")"
ZIP_SHA="$(awk -v f="$ZIP" '$2 == f {print $1}' "$DIST/SHA256SUMS")"
test -n "$DMG_SHA" && test -n "$ZIP_SHA"

sed -e "s|__VERSION__|$VERSION|" -e "s|__SHA256__|$DMG_SHA|" "$TEMPLATE" > "$DIST/dustbar.rb"
if grep -q "__[A-Z0-9_]*__" "$DIST/dustbar.rb"; then
    echo "unfilled placeholder in $DIST/dustbar.rb" >&2
    exit 1
fi
ruby -c "$DIST/dustbar.rb" >/dev/null

echo
echo "Release $VERSION (signed: ${SIGN_IDENTITY:-ad-hoc})"
ls -l "$DIST/$ZIP" "$DIST/$DMG" "$DIST/SHA256SUMS" "$DIST/dustbar.rb" | awk '{print $5, $9}'
echo
echo "sha256 $ZIP  $ZIP_SHA"
echo "sha256 $DMG  $DMG_SHA"
echo
echo "Next steps (not run; nothing has been published):"
echo "  1. gh release create v$VERSION $DIST/$ZIP $DIST/$DMG $DIST/SHA256SUMS --title \"DustBar $VERSION\" --notes \"DustBar $VERSION (locally signed, not notarized; Apple silicon, macOS 15+).\""
echo "  2. Copy $DIST/dustbar.rb to the tap repo megasoft1978/homebrew-dustbar as Casks/dustbar.rb, then commit and push it there."
echo "  3. Users: brew tap megasoft1978/dustbar && brew install --cask dustbar"
