#!/usr/bin/env bash
# Marketing captures of the DEMO app only (build/DustBarDemo.app, bundle id com.megasoft78.dustbar.demo).
#   bash scripts/capture/capture.sh
# Writes docs/assets/<tab>-<light|dark>@2x.png (window-only), og.png, poster-<appearance>.png and the scan videos.
# Never touches /Applications/DustBar.app; demo processes are matched by the demo bundle path only.
# Needs Screen Recording permission for the app that runs this script (the terminal or harness).
# A capture that is still blank after 3 attempts fails the run and nothing is written for that asset.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
ASSETS="$ROOT/docs/assets"
APP_DIR="$ROOT/build/DustBarDemo.app"
BIN="$APP_DIR/Contents/MacOS/DustBarDemo"
DEMO_ID="com.megasoft78.dustbar.demo"
WINID="$ROOT/scripts/capture/winid.swift"
TABS=(explore types growth clean)
APPEARANCES=(light dark)
MIN_COLORS=200             # real popover content has thousands of colours; a blank SwiftUI frame has about 100
MIN_COLORS_MENUBAR=50      # the menu bar ring has few colours but is never flat
SETTLE_TICKS=(3 6 10)      # per attempt, poll the capture every 0.5 s for 1.5 s, 3 s, then 5 s

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dustbar-capture.XXXXXX")"
trap 'stop_demo; rm -rf "$WORK"' EXIT

log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
command -v magick >/dev/null 2>&1 || fail "magick (ImageMagick) is required for the blank-capture check"

# ---- build if missing or stale ---------------------------------------------
if [ ! -x "$BIN" ] || [ -n "$(find Sources Resources Package.swift scripts/bundle.sh -newer "$BIN" -print -quit 2>/dev/null)" ]; then
    log "building demo app"
    DEMO=1 bash scripts/bundle.sh >/dev/null || fail "DEMO=1 bash scripts/bundle.sh failed"
fi

# ---- demo process control (only processes running this bundle's binary) ----
demo_pids() { pgrep -f "$BIN --demo" || true; }
stop_demo() {
    local pids; pids="$(demo_pids)"
    [ -n "$pids" ] || return 0
    kill $pids 2>/dev/null || true
    for _ in $(seq 1 20); do [ -z "$(demo_pids)" ] && break; sleep 0.25; done
    [ -z "$(demo_pids)" ] || kill -9 $(demo_pids) 2>/dev/null || true
    # The demo writes its fixture history to $TMPDIR/dustbar-demo-<pid>; remove only the dirs of the pids stopped here.
    for pid in $pids; do rm -rf "${TMPDIR:-/tmp}/dustbar-demo-$pid"; done
}

# A background launch leaves the popover as a flat grey frame: SwiftUI draws it only once the demo is active.
# Activation is by bundle id, so only the demo app is affected.
activate_demo() { osascript -e "tell application id \"$DEMO_ID\" to activate" >/dev/null 2>&1 || true; }

# Polls up to 10 s for the window of the demo's own process; prints "<id> x y w h" or nothing.
find_window() {
    local kind="$1" pid win=""
    for _ in $(seq 1 20); do
        pid="$(demo_pids | head -1)"
        if [ -n "$pid" ]; then
            if [ "$kind" = popover ]; then
                win="$(swift "$WINID" "DustBar Demo" --pid "$pid" --bounds 2>/dev/null || true)"
            else
                win="$(swift "$WINID" "DustBar Demo" --pid "$pid" --status --bounds 2>/dev/null || true)"
            fi
            [ -n "$win" ] && { printf '%s' "$win"; return 0; }
        fi
        sleep 0.5
    done
    return 1
}

pixel_width() { sips -g pixelWidth "$1" | awk '/pixelWidth/ { print $2 }'; }

# Blank = fewer than $2 distinct colours (a flat placeholder has about 100, real content thousands).
is_blank() {
    [ -s "$1" ] || return 0
    [ "$(magick identify -format '%k' "$1" 2>/dev/null || echo 0)" -lt "$2" ]
}

# Captures window $1 into $2 every 0.5 s for up to $3 ticks; returns 0 as soon as the capture is not blank.
wait_for_content() {
    local id="$1" ticks="$2" tmp="$3" i
    for i in $(seq 1 "$ticks"); do
        sleep 0.5
        screencapture -x -o -r -l"$id" "$tmp" 2>/dev/null || true
        is_blank "$tmp" "$MIN_COLORS" || return 0
    done
    return 1
}

# ---- popover captures -------------------------------------------------------
capture_popover() {
    local tab="$1" app="$2" out="$ASSETS/$1-$2@2x.png" name="$1-$2@2x.png"
    local attempt win id w tmp pw pid
    tmp="$WORK/$tab-$app.png"
    for attempt in 0 1 2; do
        stop_demo
        open -n "$APP_DIR" --args --demo --demo-tab "$tab" --demo-appearance "$app" --demo-open --demo-backdrop
        win="$(find_window popover)" || { stop_demo; fail "no popover window for $tab/$app within 10 s"; }
        id="${win%% *}"
        activate_demo
        rm -f "$tmp"
        if wait_for_content "$id" "${SETTLE_TICKS[$attempt]}" "$tmp"; then
            pid="$(demo_pids | head -1)"
            # The popover grows open, so read its bounds after the content is drawn.
            win="$(swift "$WINID" "DustBar Demo" --pid "$pid" --bounds)" || { stop_demo; fail "popover window lost for $tab/$app"; }
            stop_demo
            w="$(printf '%s' "$win" | awk '{ print $4 }')"
            pw="$(pixel_width "$tmp")"
            [ "$pw" -eq $((w * 2)) ] || fail "$tab/$app is ${pw}px wide, expected $((w * 2)) (2x of ${w}pt)"
            mv "$tmp" "$out"
            log "ok $name ${pw}px (attempt $((attempt + 1)))"
            sleep 0.5
            return 0
        fi
        stop_demo
        log "blank $name on attempt $((attempt + 1))/3, retrying with a longer settle"
    done
    fail "$name still blank after 3 attempts (settle 1.5/3/5 s); not written. Grant Screen Recording to the app running this script."
}

# ---- menu bar ring ----------------------------------------------------------
# The status item is drawn by WindowServer, so it has no window id and no screen capture is made. The demo app
# renders the item (ring + title) itself at 4x on a transparent background and exits.
capture_menubar() {
    local app="$1" out="$ASSETS/menubar-$1@2x.png" tmp="$WORK/menubar-$1.png" attempt
    for attempt in 0 1 2; do
        stop_demo
        [ "$attempt" -eq 0 ] || sleep "$(( attempt == 1 ? 3 : 5 ))"
        rm -f "$tmp"
        "$BIN" --demo --demo-appearance "$app" --demo-export-statusitem "$tmp" 2>/dev/null || true
        if [ -s "$tmp" ] && ! is_blank "$tmp" "$MIN_COLORS_MENUBAR"; then
            mv "$tmp" "$out"
            log "ok $(basename "$out") $(pixel_width "$out")px"
            return 0
        fi
        log "blank menubar-$app on attempt $((attempt + 1))/3"
    done
    fail "menubar-$app@2x.png still blank after 3 attempts; not written"
}

for app in "${APPEARANCES[@]}"; do
    for tab in "${TABS[@]}"; do
        capture_popover "$tab" "$app"
    done
done
for app in "${APPEARANCES[@]}"; do
    capture_menubar "$app"
done

# ---- videos and posters (first frame of each scan) --------------------------
bash "$ROOT/scripts/capture/record-scan.sh" dark
bash "$ROOT/scripts/capture/record-scan.sh" light

# ---- og.png: icon + navy + explore-dark ------------------------------------
magick -size 1200x630 "xc:#0B1220" \
    \( -background none "$ROOT/docs/assets/icon.svg" -resize 200x200 \) -geometry +120+215 -composite \
    \( "$ASSETS/explore-dark@2x.png" -resize x520 \) -geometry +740+55 -composite \
    "$ASSETS/og.png"
log "ok og.png $(pixel_width "$ASSETS/og.png")px"

# ---- post-process: metadata strip (colour profile kept) ----------------------
for f in "$ASSETS"/*.png; do
    [ -f "$f" ] || continue
    if command -v exiftool >/dev/null 2>&1; then
        # Strip all metadata but keep the colour profile (-all= alone would drop it and shift colours).
        exiftool -q -all= --ICC_Profile:all -overwrite_original "$f"
    else
        magick "$f" -strip "$f"             # no ICC kept on this path: sRGB assumed
    fi
    # pngquant is deliberately not run: it drops the colour profile and dithers the glass gradients.
done
command -v oxipng >/dev/null 2>&1 || log "note: oxipng not installed, skipped (files are ~100 KB each)"

log "done"
