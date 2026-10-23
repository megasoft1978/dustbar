#!/usr/bin/env bash
# Guard run before anything under docs/ or README.md is published.
#   1. no local absolute user paths or local user name in docs/ and README.md
#   2. no EXIF/XMP/IPTC/GPS or similar metadata in docs/assets media
#   3. no home-folder names (built at run time, never stored) visible in OCR text of docs/assets/*.png
# Exit 0 = clean, 1 = offending files/words found, 2 = guard could not run.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOCS="$ROOT/docs"
README="$ROOT/README.md"
ASSETS="${ASSETS_DIR:-$DOCS/assets}"
ALLOW="$ROOT/scripts/public-assets-allowlist.txt"
OCR="$ROOT/scripts/ocr.swift"

fail=0
say() { printf '%s\n' "$*"; }

# ---- 1. paths and user name -------------------------------------------------
targets=()
if [ -d "$DOCS" ]; then
    while IFS= read -r -d '' f; do targets+=("$f"); done < <(find "$DOCS" -type f -print0)
fi
[ -f "$README" ] && targets+=("$README")

hits1=""
if [ ${#targets[@]} -gt 0 ]; then
    # Perl is used because stock macOS grep has no -P; the pattern is the brief's PCRE.
    hits1=$(perl -ne '
        print "$ARGV:$.: local absolute path /Users/<name>\n" if /\/Users\/(?!demo)/;
        # The own bundle id of the app (com.megasoft78.dustbar) is already public in Info.plist; anything else is a leak.
        (my $t = $_) =~ s/com\.megasoft78\.dustbar(\.demo)?//g;
        print "$ARGV:$.: local user name megasoft78\n" if $t =~ /megasoft78/;
    ' "${targets[@]}" 2>&1)
fi
if [ -n "$hits1" ]; then
    fail=1
    say "FAIL 1/3 public-paths: ${#targets[@]} files checked"
    printf '%s\n' "$hits1" | sed 's/^/  /'
else
    say "PASS 1/3 public-paths: ${#targets[@]} files checked"
fi

# ---- 2. media metadata ------------------------------------------------------
media=()
if [ -d "$ASSETS" ]; then
    while IFS= read -r -d '' f; do media+=("$f"); done < <(
        find "$ASSETS" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \
            -o -iname '*.gif' -o -iname '*.mp4' -o -iname '*.webm' \) -print0)
fi

meta_tool=""
if command -v exiftool >/dev/null 2>&1; then
    meta_tool="exiftool"
elif command -v mdls >/dev/null 2>&1; then
    meta_tool="mdls"
fi

hits2=""
if [ ${#media[@]} -gt 0 ] && [ -z "$meta_tool" ]; then
    # Fail closed: an unverifiable asset must not pass.
    fail=1
    say "FAIL 2/3 media-metadata: neither exiftool nor mdls is installed; cannot verify ${#media[@]} files"
elif [ ${#media[@]} -gt 0 ]; then
    for f in "${media[@]}"; do
        if [ "$meta_tool" = "exiftool" ]; then
            # Keep only metadata groups; File/Composite/ExifTool are derived from format and size, not authored data.
            found=$(exiftool -s -G1 -api largefilesupport=1 "$f" 2>/dev/null | perl -ne '
                if (/^\[([^\]]+)\]\s+(\S+)\s*:/) {
                    my ($grp, $tag) = ($1, $2);
                    print "$tag ($grp)\n" if $grp =~ /^(EXIF|IFD\d|ExifIFD|GPS|XMP|IPTC|MakerNotes|Photoshop|Adobe|Comment|PNG-(tEXt|zTXt|iTXt|eXIf)|UserData|Keys|ItemList|Meta|XML)\b/;
                }')
        else
            found=$(mdls -name kMDItemAcquisitionMake -name kMDItemAcquisitionModel -name kMDItemAuthors \
                -name kMDItemCopyright -name kMDItemCreator -name kMDItemLatitude -name kMDItemLongitude \
                -name kMDItemWhereFroms -name kMDItemDescription -name kMDItemComment -name kMDItemSoftware \
                "$f" 2>/dev/null | grep '^kMDItem' | grep -v '(null)$')
        fi
        if [ -n "$found" ]; then
            hits2+="$(printf '%s\n' "$found" | sed "s|^|  $(basename "$f"): |")"$'\n'
        fi
    done
    if [ -n "$hits2" ]; then
        fail=1
        say "FAIL 2/3 media-metadata (via $meta_tool): ${#media[@]} files checked"
        printf '%s' "$hits2"
    else
        say "PASS 2/3 media-metadata (via $meta_tool): ${#media[@]} files checked"
    fi
else
    say "PASS 2/3 media-metadata: no media in docs/assets"
fi

# ---- 3. OCR denylist --------------------------------------------------------
# Denylist: lowercase entry names of ~, ~/Desktop, ~/Documents (depth 1, >= 5 chars).
# Held in shell memory and piped; never written to disk or printed.
deny=$(
    for d in "$HOME" "$HOME/Desktop" "$HOME/Documents"; do
        [ -d "$d" ] && find "$d" -mindepth 1 -maxdepth 1 -exec basename {} \;
    done | grep -E '^[a-z][a-z0-9_-]{4,}$' | sort -u
)
if [ -f "$ALLOW" ]; then
    deny=$(printf '%s\n' "$deny" | grep -vxF -f "$ALLOW")
fi

pngs=()
if [ -d "$ASSETS" ]; then
    while IFS= read -r -d '' f; do pngs+=("$f"); done < <(find "$ASSETS" -type f -iname '*.png' -print0)
fi

hits3=""
if [ ${#pngs[@]} -eq 0 ]; then
    say "PASS 3/3 ocr-denylist: no PNG in docs/assets"
elif ! command -v swift >/dev/null 2>&1; then
    fail=1
    say "FAIL 3/3 ocr-denylist: swift not installed; cannot OCR ${#pngs[@]} PNGs"
else
    ocr_failed=0
    for f in "${pngs[@]}"; do
        text=$(swift "$OCR" "$f" 2>/dev/null) || { ocr_failed=1; say "  OCR failed: $(basename "$f")"; continue; }
        words=$(printf '%s\n' "$text" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_-' '\n' | grep -v '^$' | sort -u)
        m=$(awk 'NR==FNR { d[$0]=1; next } ($0 in d) { print }' <(printf '%s\n' "$deny") <(printf '%s\n' "$words"))
        while IFS= read -r w; do
            [ -n "$w" ] && hits3+="  $(basename "$f"): denylisted word '$w'"$'\n'
        done <<< "$m"
    done
    if [ "$ocr_failed" -eq 1 ]; then
        fail=1
        say "FAIL 3/3 ocr-denylist: OCR error on at least one PNG"
    fi
    if [ -n "$hits3" ]; then
        fail=1
        say "FAIL 3/3 ocr-denylist: ${#pngs[@]} PNGs checked"
        printf '%s' "$hits3"
    elif [ "$ocr_failed" -eq 0 ]; then
        say "PASS 3/3 ocr-denylist: ${#pngs[@]} PNGs checked"
    fi
fi

# ---- result -----------------------------------------------------------------
if [ "$fail" -eq 0 ]; then
    say "RESULT: PASS - safe to publish docs/ and README.md"
    exit 0
fi
say "RESULT: FAIL - fix the items above before publishing"
exit 1
