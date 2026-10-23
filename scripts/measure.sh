#!/usr/bin/env bash
# Measures DustBar and writes docs/benchmarks.json.
#   scripts/measure.sh            short run: idle 60 s, scan 1M bench, refresh bench
#   scripts/measure.sh --long     idle 300 s (adds idleFootprint5minMB)
#   scripts/measure.sh --full     also scan the whole $HOME (~35-60 s), updates scan8M*
# Runs are warm-cache (no sudo purge). Fields not measured in this run keep their previous value.
set -euo pipefail

cd "$(dirname "$0")/.."

FULL=0
LONG=0
for arg in "$@"; do
    case "$arg" in
        --full) FULL=1 ;;
        --long) LONG=1 ;;
        *) echo "unknown flag: $arg (use --full, --long)" >&2; exit 2 ;;
    esac
done

OUT="docs/benchmarks.json"
APP="$PWD/build/DustBar.app"
BIN="$APP/Contents/MacOS/DustBar"
LOG_DIR="$(mktemp -d)"
PID=""

cleanup() {
    # Quit only the copy this script launched; the installed app is never touched.
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then kill "$PID" 2>/dev/null || true; fi
    rm -f "$LOG_DIR"/* 2>/dev/null || true
    rmdir "$LOG_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# 1. Build and binary size
bash scripts/bundle.sh > "$LOG_DIR/bundle.log" 2>&1 || { tail -n 20 "$LOG_DIR/bundle.log" >&2; exit 1; }
BINARY_BYTES="$(stat -f%z "$BIN")"

# 2. Idle footprint and CPU of a fresh copy (popover assumed closed)
IDLE_WINDOW=60
[ "$LONG" = 1 ] && IDLE_WINDOW=300

# Only build-path copies are touched; the installed /Applications copy is a different path.
BEFORE=" $(pgrep -fx "$BIN" | tr '\n' ' ' || true) "
open -n "$APP"
for _ in $(seq 1 50); do
    for CAND in $(pgrep -fx "$BIN" || true); do
        case "$BEFORE" in *" $CAND "*) ;; *) PID="$CAND" ;; esac
    done
    [ -n "$PID" ] && break
    sleep 0.2
done
[ -n "$PID" ] || { echo "could not find launched DustBar pid" >&2; exit 1; }

FOOT_60=""
FOOT_300=""
CPU_LOG="$LOG_DIR/cpu.txt"
: > "$CPU_LOG"
START="$(date +%s)"
FOOT_TAKEN=0
while :; do
    sleep 5
    NOW="$(date +%s)"
    ELAPSED=$(( NOW - START ))
    CPU="$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ' || true)"
    [ -n "$CPU" ] || { echo "DustBar exited during idle window" >&2; exit 1; }
    echo "$CPU" >> "$CPU_LOG"
    if [ "$FOOT_TAKEN" = 0 ] && [ "$ELAPSED" -ge 60 ]; then
        FOOT_60="$(vmmap -summary "$PID" 2>/dev/null | grep 'Physical footprint:' | head -n 1 || true)"
        FOOT_TAKEN=1
    fi
    [ "$ELAPSED" -ge "$IDLE_WINDOW" ] && break
done
IDLE_SECONDS="$(( $(date +%s) - START ))"
if [ "$LONG" = 1 ]; then
    FOOT_300="$(vmmap -summary "$PID" 2>/dev/null | grep 'Physical footprint:' | head -n 1 || true)"
fi
kill "$PID" 2>/dev/null || true
PID=""

# 3. Scan benches (warm cache). Output is kept in logs; only BENCH/REFRESH lines are parsed.
SCAN1_LOG="$LOG_DIR/scan1m.log"
SCAN8_LOG="$LOG_DIR/scan8m.log"
REFRESH_LOG="$LOG_DIR/refresh.log"

DUSTBAR_SCAN_BENCH="$HOME/Library" swift test --filter scanBench > "$SCAN1_LOG" 2>&1 \
    || { tail -n 20 "$SCAN1_LOG" >&2; echo "scan 1M bench failed" >&2; exit 1; }

if [ "$FULL" = 1 ]; then
    DUSTBAR_SCAN_BENCH="$HOME" swift test --filter scanBench > "$SCAN8_LOG" 2>&1 \
        || { tail -n 20 "$SCAN8_LOG" >&2; echo "scan 8M bench failed" >&2; exit 1; }
fi

DUSTBAR_REFRESH_BENCH=1 swift test --filter refreshBench > "$REFRESH_LOG" 2>&1 \
    || { tail -n 20 "$REFRESH_LOG" >&2; echo "refresh bench failed" >&2; exit 1; }

# 4. Machine info (no personal paths are written)
HW_MODEL="$(sysctl -n hw.model)"
CPU_BRAND="$(sysctl -n machdep.cpu.brand_string)"
CORES="$(sysctl -n hw.ncpu)"
MACOS_VER="$(sw_vers -productVersion)"
DATE_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# 5. Parse and write JSON (python3 json.dumps; values passed via environment)
RUN_FULL="$FULL" RUN_LONG="$LONG" OUT="$OUT" \
BINARY_BYTES="$BINARY_BYTES" IDLE_SECONDS="$IDLE_SECONDS" \
FOOT_60="$FOOT_60" FOOT_300="$FOOT_300" CPU_LOG="$CPU_LOG" \
SCAN1_LOG="$SCAN1_LOG" SCAN8_LOG="$SCAN8_LOG" REFRESH_LOG="$REFRESH_LOG" \
HW_MODEL="$HW_MODEL" CPU_BRAND="$CPU_BRAND" CORES="$CORES" \
MACOS_VER="$MACOS_VER" DATE_ISO="$DATE_ISO" \
python3 -I - <<'PY'
import json, os, re, sys

env = os.environ
out = env["OUT"]

prev = {}
if os.path.exists(out):
    try:
        with open(out) as f:
            prev = json.load(f)
    except (OSError, ValueError):
        prev = {}

def fail(msg):
    sys.exit("measure.sh: " + msg)

def footprint_mb(line):
    m = re.search(r"Physical footprint:\s*([0-9.]+)\s*([KMG]?)B?\b", line)
    if not m:
        fail(f"cannot parse footprint line: {line!r}")
    value = float(m.group(1))
    unit = m.group(2)
    return round({"": value / 1048576, "K": value / 1024, "M": value, "G": value * 1024}[unit], 1)

DUR_UNITS = {
    "h": 3600.0, "hour": 3600.0, "hours": 3600.0,
    "min": 60.0, "minute": 60.0, "minutes": 60.0, "m": 60.0,
    "s": 1.0, "second": 1.0, "seconds": 1.0,
    "ms": 1e-3, "millisecond": 1e-3, "milliseconds": 1e-3,
    "us": 1e-6, "µs": 1e-6, "microsecond": 1e-6, "microseconds": 1e-6,
    "ns": 1e-9, "nanosecond": 1e-9, "nanoseconds": 1e-9,
}

def duration_seconds(text):
    # Swift Duration prints e.g. "12.5 seconds", "1m 2.5s" or "250.0ms"; sum all tokens.
    tokens = re.findall(r"([0-9]+(?:\.[0-9]+)?)\s*(hours?|minutes?|min|seconds?|milliseconds?|microseconds?|nanoseconds?|ms|us|µs|ns|h|m|s)\b", text)
    if not tokens:
        fail(f"cannot parse duration: {text!r}")
    return round(sum(float(v) * DUR_UNITS[u] for v, u in tokens), 3)

def bench_line(path, prefix):
    with open(path, errors="replace") as f:
        for line in f:
            if prefix in line:
                return line.strip()
    fail(f"no '{prefix}' line in {os.path.basename(path)}")

def scan_fields(path):
    line = bench_line(path, "BENCH elapsed=")
    m_el = re.search(r"BENCH elapsed=(.+?) snapshots=", line)
    m_files = re.search(r"files=([0-9]+)", line)
    if not (m_el and m_files):
        fail(f"cannot parse scan line: {line!r}")
    return duration_seconds(m_el.group(1)), int(m_files.group(1))

def keep(key):
    return prev.get(key)

# CPU mean over samples
samples = []
with open(env["CPU_LOG"]) as f:
    for line in f:
        line = line.strip()
        if line:
            try:
                samples.append(float(line.replace(",", ".")))
            except ValueError:
                fail(f"cannot parse ps %cpu: {line!r}")
if not samples:
    fail("no CPU samples")
idle_cpu = round(sum(samples) / len(samples), 2)

idle_foot_60 = footprint_mb(env["FOOT_60"]) if env["FOOT_60"] else None
idle_foot_300 = footprint_mb(env["FOOT_300"]) if env["FOOT_300"] else None

scan1_s, scan1_files = scan_fields(env["SCAN1_LOG"])
if env["RUN_FULL"] == "1":
    scan8_s, scan8_files = scan_fields(env["SCAN8_LOG"])
else:
    scan8_s, scan8_files = keep("scan8MSeconds"), keep("scan8MFiles")

refresh_line = bench_line(env["REFRESH_LOG"], "REFRESH root=")
m_full = re.search(r" full=(.+?) refresh=", refresh_line)
m_refresh = re.search(r" refresh=(.+?) dirty=", refresh_line)
if not (m_full and m_refresh):
    fail(f"cannot parse refresh line: {refresh_line!r}")
full_s = duration_seconds(m_full.group(1))
refresh_s = duration_seconds(m_refresh.group(1))
if refresh_s <= 0:
    fail("refresh time is zero")
speedup = round(full_s / refresh_s, 1)

if env["RUN_LONG"] == "1":
    idle_300_out = idle_foot_300
else:
    idle_300_out = keep("idleFootprint5minMB")

data = {
    "binaryBytes": int(env["BINARY_BYTES"]),
    "idleFootprintMB": idle_foot_60,
    "idleFootprint5minMB": idle_300_out,
    "idleSeconds": int(env["IDLE_SECONDS"]),
    "idleCpuPct": idle_cpu,
    "scan1MSeconds": scan1_s,
    "scan1MFiles": scan1_files,
    "scan8MSeconds": scan8_s,
    "scan8MFiles": scan8_files,
    "refreshSpeedup": speedup,
    "refreshFullSeconds": full_s,
    "refreshIncrementalSeconds": refresh_s,
    "machine": {
        "model": env["HW_MODEL"],
        "cpu": env["CPU_BRAND"],
        "cores": int(env["CORES"]),
    },
    "macos": env["MACOS_VER"],
    "date": env["DATE_ISO"],
    "warmCache": True,
    "methods": {
        "binaryBytes": "stat of build/DustBar.app/Contents/MacOS/DustBar after scripts/bundle.sh (release, stripped, ad-hoc signed)",
        "idleFootprintMB": f"fresh copy via open -n, popover closed, vmmap -summary 'Physical footprint:' read after 60 s idle",
        "idleFootprint5minMB": "same as idleFootprintMB, read after 300 s idle; only with --long (previous value kept otherwise)",
        "idleSeconds": "length of the idle window in seconds (60 default, 300 with --long)",
        "idleCpuPct": "mean of ps -o %cpu= sampled every 5 s over the idle window",
        "scan1MSeconds": "DUSTBAR_SCAN_BENCH=~/Library swift test --filter scanBench; BENCH elapsed line; 'scan1M' label is the ~/Library tree as the bench scans it",
        "scan1MFiles": "files count printed by the scanBench BENCH line",
        "scan8MSeconds": "DUSTBAR_SCAN_BENCH=~ swift test --filter scanBench; only with --full (previous value kept otherwise)",
        "scan8MFiles": "files count printed by scanBench on ~; only with --full",
        "refreshSpeedup": "full scan time / incremental refresh time of 20 random dirs (DUSTBAR_REFRESH_BENCH=1 swift test --filter refreshBench, ~/Library)",
        "refreshFullSeconds": "full scan time from the refreshBench REFRESH line",
        "refreshIncrementalSeconds": "refresh time of 20 dirty directories from the refreshBench REFRESH line",
        "machine": "sysctl hw.model, machdep.cpu.brand_string, hw.ncpu",
        "macos": "sw_vers -productVersion",
        "date": "UTC timestamp of the measurement run",
        "warmCache": "warm cache: no sudo purge; numbers reflect a warm disk cache",
    },
}

os.makedirs(os.path.dirname(out) or ".", exist_ok=True)
with open(out, "w") as f:
    f.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
print(json.dumps({k: data[k] for k in ("binaryBytes", "idleFootprintMB", "idleCpuPct", "idleSeconds", "scan1MSeconds", "scan1MFiles", "scan8MSeconds", "scan8MFiles", "refreshSpeedup", "refreshFullSeconds", "refreshIncrementalSeconds")}))
PY

echo "wrote $OUT"
