#!/usr/bin/env bash
# Records the demo popover's scan replay (window only, no shadow) and encodes the docs/assets videos.
#   bash scripts/capture/record-scan.sh [dark|light]   (default dark)
# dark  -> docs/assets/demo-scan.mp4 / .webm / .gif, plus docs/assets/poster-dark.png
# light -> docs/assets/poster-light.png only (first frame of a light scan)
# The poster is written only when its first frame is not blank; blank frames are retried up to 3 times with a
# longer settle, then the script exits 1 and leaves the existing poster untouched.
# Needs build/DustBarDemo.app (DEMO=1 bash scripts/bundle.sh), Screen Recording permission, ffmpeg and magick.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ASSETS="$ROOT/docs/assets"
APP_DIR="$ROOT/build/DustBarDemo.app"
BIN="$APP_DIR/Contents/MacOS/DustBarDemo"
DEMO_ID="com.megasoft78.dustbar.demo"
APPEARANCE="${1:-dark}"
case "$APPEARANCE" in dark|light) ;; *) echo "usage: $0 [dark|light]" >&2; exit 2 ;; esac
RECORD_SECONDS=8
MIN_COLORS=200             # same blank threshold as capture.sh
SETTLE=(0.5 3 5)           # seconds after the popover opens before recording, per attempt

if [ ! -x "$BIN" ]; then echo "missing $BIN (run: DEMO=1 bash scripts/bundle.sh)" >&2; exit 2; fi
if ! command -v ffmpeg >/dev/null 2>&1; then echo "ffmpeg not installed: cannot encode; install it (not via this script) and rerun" >&2; exit 2; fi
if ! command -v magick >/dev/null 2>&1; then echo "magick (ImageMagick) not installed: cannot check for blank frames" >&2; exit 2; fi

# Own temp dir; removed on exit.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dustbar-scan.XXXXXX")"
trap 'stop_demo; rm -rf "$WORK"' EXIT

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
activate_demo() { osascript -e "tell application id \"$DEMO_ID\" to activate" >/dev/null 2>&1 || true; }

# Blank = fewer than $2 distinct colours.
is_blank() {
    [ -s "$1" ] || return 0
    [ "$(magick identify -format '%k' "$1" 2>/dev/null || echo 0)" -lt "$2" ]
}

# The window-only capture has black outside the rounded popover; key that black out and place the
# popover on the demo backdrop colour (navy for dark, light grey-blue for light) so the frames look intentional.
if [ "$APPEARANCE" = "dark" ]; then BG="0B1220"; else BG="E9EEF5"; fi
bg_chain() {
    printf '%s' "[0:v]scale=$1:-2:flags=lanczos,split[a][b];[b]drawbox=x=0:y=0:w=iw:h=ih:color=0x$BG:t=fill[bg];[a]format=rgba,colorkey=0x000000:0.08:0.0[fg];[bg][fg]overlay=format=auto"
}

# Poster: black is keyed out only where it touches the frame corners (the margin around the rounded popover), so
# black text inside a light popover is kept. A global colour key would hollow out that text.
make_poster() {
    local in="$1" out="$2" w h
    read -r w h < <(magick identify -format '%w %h' "$in")
    magick "$in" -alpha set -fill none -fuzz 12% \
        -draw "color 0,0 floodfill" -draw "color $((w - 1)),0 floodfill" \
        -draw "color 0,$((h - 1)) floodfill" -draw "color $((w - 1)),$((h - 1)) floodfill" \
        -background "#$BG" -flatten -alpha off "$out"
}

# Opens the demo, records the scan and writes its first frame to $WORK/poster-<appearance>.png.
# Returns 1 when the recording or its first frame is missing or blank.
record_attempt() {
    local settle="$1" pid win="" wid
    stop_demo
    rm -f "$WORK/scan.mov" "$WORK/poster-$APPEARANCE.png"
    open -n "$APP_DIR" --args --demo --demo-tab explore --demo-appearance "$APPEARANCE" \
        --demo-open --demo-backdrop --demo-scan

    # Poll up to 10 s for the popover window of this exact demo process.
    for _ in $(seq 1 20); do
        pid="$(demo_pids | head -1)"
        if [ -n "$pid" ]; then
            win="$(swift "$ROOT/scripts/capture/winid.swift" "DustBar Demo" --pid "$pid" --bounds 2>/dev/null || true)"
            [ -n "$win" ] && break
        fi
        sleep 0.5
    done
    if [ -z "$win" ]; then stop_demo; echo "popover window not found within 10 s" >&2; exit 1; fi
    wid="${win%% *}"

    activate_demo
    sleep "$settle"
    # --demo-scan replays the scan on open (~6 s); the recording covers the whole replay.
    screencapture -x -o -v -V "$RECORD_SECONDS" -l"$wid" "$WORK/scan.mov" 2>/dev/null || true
    stop_demo
    [ -s "$WORK/scan.mov" ] || return 1
    ffmpeg -v error -y -i "$WORK/scan.mov" -frames:v 1 -vf "scale=720:-2:flags=lanczos" "$WORK/frame.png" || return 1
    make_poster "$WORK/frame.png" "$WORK/poster-$APPEARANCE.png" || return 1
    ! is_blank "$WORK/poster-$APPEARANCE.png" "$MIN_COLORS"
}

ok=0
for attempt in 0 1 2; do
    if record_attempt "${SETTLE[$attempt]}"; then ok=1; break; fi
    echo "blank or missing first frame ($APPEARANCE) on attempt $((attempt + 1))/3, retrying with a longer settle" >&2
done
[ "$ok" -eq 1 ] || { echo "FAIL: poster-$APPEARANCE.png still blank after 3 attempts; not written" >&2; exit 1; }

MOV="$WORK/scan.mov"
mv "$WORK/poster-$APPEARANCE.png" "$ASSETS/poster-$APPEARANCE.png"
echo "poster: $ASSETS/poster-$APPEARANCE.png"

if [ "$APPEARANCE" = "dark" ]; then
    # Video: 720 px wide, no audio, no muxer metadata.
    ffmpeg -v error -y -i "$MOV" -an -filter_complex "$(bg_chain 720),format=yuv420p[v]" -map "[v]" \
        -c:v libx264 -preset slow -crf 27 -profile:v high -movflags +faststart \
        -map_metadata -1 -fflags +bitexact -flags:v +bitexact \
        "$ASSETS/demo-scan.mp4"
    ffmpeg -v error -y -i "$MOV" -an -filter_complex "$(bg_chain 720),format=yuv420p[v]" -map "[v]" \
        -c:v libvpx-vp9 -crf 38 -b:v 0 -row-mt 1 \
        -map_metadata -1 -fflags +bitexact \
        "$ASSETS/demo-scan.webm"
    # GIF: 600 px wide, 10 fps, palette generated from the clip.
    ffmpeg -v error -y -i "$MOV" -an -filter_complex "$(bg_chain 600),fps=10,split[x][y];[x]palettegen=max_colors=128:stats_mode=diff[p];[y][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
        -map_metadata -1 -fflags +bitexact \
        "$ASSETS/demo-scan.gif"
    for f in demo-scan.mp4 demo-scan.webm demo-scan.gif; do
        echo "$f: $(stat -f%z "$ASSETS/$f") bytes"
    done
fi

# Metadata strip where exiftool exists (ffmpeg writes none beyond the encoder tag, but be sure).
if command -v exiftool >/dev/null 2>&1; then
    exiftool -q -all= -overwrite_original "$ASSETS/poster-$APPEARANCE.png" 2>/dev/null || true
    if [ "$APPEARANCE" = "dark" ]; then
        for f in demo-scan.mp4 demo-scan.webm demo-scan.gif; do
            [ -f "$ASSETS/$f" ] && exiftool -q -all= -overwrite_original "$ASSETS/$f" 2>/dev/null || true
        done
    fi
fi
echo "recorded $RECORD_SECONDS s ($APPEARANCE) after attempt $((attempt + 1))"
