#!/usr/bin/env bash
# qub's startup measurement: launch the app a number of times, ask it where its
# own startup went, and print the phases with their medians.
#
#     bash scripts/startup-trace.sh                    # 10 runs on $DISPLAY
#     bash scripts/startup-trace.sh -n 20              # more samples
#     bash scripts/startup-trace.sh --offscreen        # no display needed
#     bash scripts/startup-trace.sh --profile ~/.local/share  # your real qub
#
# The binary carries the instrumentation itself, guarded by QUB_STARTUP_TRACE
# (see src/main.cpp), so this measures the build people run rather than a
# special one. The zero is taken here, in the shell, before exec — fork, exec
# and the dynamic linker are inside the number, which is what someone waiting
# for a window is actually waiting through.
#
# Read the platform before reading the numbers. `offscreen` needs no display
# and is therefore the tempting default, and it understates two phases badly:
# it skips fontconfig and it never asks a GPU for a context or a window manager
# for a window. It is good for comparing two builds against each other, and no
# good at all for publishing a figure. The default here is the real display.
#
# Each phase is the median of that mark across the runs, and the phases are
# differences of those medians, so they add up to the total exactly. One
# untimed run goes first to warm the page cache.
#
# Linux only, and the real-display default puts a window on your screen once
# per run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS=10
BINARY="$ROOT/build/qub"
PLATFORM=""
PROFILE=""
WORK="${TMPDIR:-/tmp}/qub-startup-$UID"

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--runs)     RUNS="$2";   shift 2 ;;
        -b|--binary)   BINARY="$2"; shift 2 ;;
        -p|--profile)  PROFILE="$2"; shift 2 ;;
        --offscreen)   PLATFORM="offscreen"; shift ;;
        --xvfb)        PLATFORM="xvfb"; shift ;;
        -h|--help)     sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -x "$BINARY" ] || { echo "no binary at $BINARY (build first, or pass -b)" >&2; exit 1; }
command -v python3 > /dev/null 2>&1 || { echo "missing python3" >&2; exit 1; }

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
note() { printf '   \033[36m--\033[0m   %s\n' "$1"; }

# ─────────────────────────────────────────────────────────────── display ────
XVFB_PID=""
cleanup() { [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2> /dev/null; }
trap cleanup EXIT

case "$PLATFORM" in
    offscreen)
        export QT_QPA_PLATFORM=offscreen
        WHERE="offscreen — understates fonts and the first frame"
        ;;
    xvfb)
        command -v Xvfb > /dev/null 2>&1 || { echo "missing Xvfb" >&2; exit 1; }
        DISPLAY_NUM=99
        while [ -e "/tmp/.X11-unix/X$DISPLAY_NUM" ]; do DISPLAY_NUM=$((DISPLAY_NUM + 1)); done
        export DISPLAY=":$DISPLAY_NUM"
        Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp > /dev/null 2>&1 &
        XVFB_PID=$!
        sleep 1
        export QT_QPA_PLATFORM=xcb
        WHERE="xcb on Xvfb $DISPLAY — a real X server, but software rendering"
        ;;
    *)
        [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || {
            echo "no display: run this on a desktop, or pass --offscreen / --xvfb" >&2
            exit 1; }
        WHERE="${QT_QPA_PLATFORM:-default} on ${DISPLAY:-$WAYLAND_DISPLAY}"
        ;;
esac

# ────────────────────────────────────────────────────── isolated profile ────
# AppDataLocation follows XDG_DATA_HOME, so a scratch directory gives the run
# its own qub.db, settings and connection list — an empty one, which is the
# only starting state two machines can agree on. Point --profile at the parent
# of your real `qub` data directory to measure your own startup instead.
if [ -n "$PROFILE" ]; then
    export XDG_DATA_HOME="$PROFILE"
    note "profile: $PROFILE (yours)"
else
    rm -rf "$WORK"
    mkdir -p "$WORK/data" "$WORK/config" "$WORK/cache" || exit 1
    export XDG_DATA_HOME="$WORK/data"
    export XDG_CONFIG_HOME="$WORK/config"
    export XDG_CACHE_HOME="$WORK/cache"
    note "profile: $WORK (empty)"
fi

# ─────────────────────────────────────────────────────────────── the run ────
# QUB_STARTUP_TRACE=exit makes the app close itself the moment it has drawn
# once, so nothing here has to find the window or send it a signal.
export QUB_STARTUP_TRACE=exit
SAMPLES="$(mktemp)"
trap 'cleanup; rm -f "$SAMPLES"' EXIT

sample() {
    QUB_STARTUP_T0="$(date +%s%N)" "$BINARY" 2>&1 | grep '^qub-startup '
}

step "Sampling"
note "$WHERE"
note "binary: $BINARY"
sample > /dev/null                       # warm the page cache; not counted
for i in $(seq "$RUNS"); do
    out="$(sample)"
    [ -n "$out" ] || { echo "run $i produced no marks — is this a build with the trace in it?" >&2; exit 1; }
    printf '%s\n' "$out" >> "$SAMPLES"
    printf '   run %2d/%d\r' "$i" "$RUNS"
done
printf '\033[K'

# ────────────────────────────────────────────────────────────── the table ────
step "Startup, median of $RUNS runs"
python3 - "$SAMPLES" "$RUNS" <<'PYEOF'
import sys, collections, statistics

marks = collections.defaultdict(list)
for line in open(sys.argv[1]):
    parts = line.split()
    if len(parts) == 3:
        marks[parts[1]].append(int(parts[2]) / 1000.0)

order = [("qguiapplication", "fork + exec + linker + QGuiApplication"),
         ("fonts",           "fonts — 8 x addApplicationFont"),
         ("objects",         "C++ objects — SQLite stores, keychain"),
         ("engine",          "QQmlApplicationEngine + Main.qml"),
         ("firstframe",      "until the first frame")]

missing = [k for k, _ in order if k not in marks]
if missing:
    sys.exit("no samples for: %s" % ", ".join(missing))

# Medians of the cumulative marks, then differences of those medians, so the
# phases add up to the total instead of drifting a millisecond off it.
med = {k: statistics.median(v) for k, v in marks.items()}
runs = marks["firstframe"]

print()
print("   %-42s %8s %8s" % ("phase", "median", "share"))
print("   " + "-" * 60)
total, prev = med["firstframe"], 0.0
for key, label in order:
    span = med[key] - prev
    prev = med[key]
    print("   %-42s %7.0f %7.0f%%" % (label, span, 100 * span / total))
print("   " + "-" * 60)
print("   %-42s %7.0f" % ("launch to a usable window", total))
print()
print("   spread across runs: %.0f - %.0f ms" % (min(runs), max(runs)))
print("   every number is milliseconds")
PYEOF
