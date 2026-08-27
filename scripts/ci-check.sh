#!/usr/bin/env bash
# qub's build gate: compile, run the unit tests, boot the app headless, lint the
# QML. The same script runs on a developer machine and on CI, so a red pipeline
# can always be reproduced locally with one command.
#
#     bash scripts/ci-check.sh                     # builds in build-ci/
#     bash scripts/ci-check.sh /tmp/qub-ci         # builds elsewhere
#     bash scripts/ci-check.sh --local-mahina      # use the ../mahina checkout
#     bash scripts/ci-check.sh --update-baseline   # accept the current lint counts
#
# Qt is located through CMAKE_PREFIX_PATH, exactly as for a normal build:
#
#     CMAKE_PREFIX_PATH=~/Qt/6.11.2/gcc_64 bash scripts/ci-check.sh
#
# JOBS overrides the build parallelism (default: nproc) and BOOT_SECONDS how
# long the app must survive (default: 10).
#
# Exit status is 0 only when every gate passes. Logs land in <build-dir>/ci-logs.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="$ROOT/scripts/qmllint-baseline.txt"
BOOT_SECONDS="${BOOT_SECONDS:-10}"
# Explicit, because `cmake --build --parallel` with no count passes a bare `-j`
# to make, which means *unlimited* rather than one job per core. Nearly every
# qmlcache translation unit is ready at once, so that starts a couple of hundred
# compilers together and the machine dies.
JOBS="${JOBS:-$(nproc)}"

UPDATE_BASELINE=0
LOCAL_MAHINA=0
BUILD_DIR=""
for arg in "$@"; do
    case "$arg" in
        --update-baseline) UPDATE_BASELINE=1 ;;
        --local-mahina)    LOCAL_MAHINA=1 ;;
        -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) BUILD_DIR="$arg" ;;
    esac
done
[ -n "$BUILD_DIR" ] || BUILD_DIR="$ROOT/build-ci"

mkdir -p "$BUILD_DIR/ci-logs" || exit 1
LOGS="$BUILD_DIR/ci-logs"

FAILED=()
step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
pass() { printf '   \033[32mok\033[0m   %s\n' "$1"; }
note() { printf '   \033[36m--\033[0m   %s\n' "$1"; }
fail() { printf '   \033[31mFAIL\033[0m %s\n' "$1"; FAILED+=("$1"); }

# ---------------------------------------------------------------- build ----
# CMakeLists prefers a ../mahina sibling checkout when one exists, which is the
# right default for developing the two together and the wrong one for a gate:
# CI has no sibling, so a dirty local Mahina would let this pass and CI fail on
# the same commit. Force the pinned commit unless asked otherwise. FetchContent
# caches inside the build directory, so only the first configure downloads.
step "Build"
MAHINA_ARG=(-DFETCHCONTENT_SOURCE_DIR_MAHINA=)
if [ "$LOCAL_MAHINA" -eq 1 ]; then
    MAHINA_ARG=()
    note "using ../mahina if present — this is not what CI does"
fi

# Ninja when it is there, the platform default otherwise. release.yml uses
# Ninja on all three jobs for the same reason — it is several times faster on
# the qmlcache units — but requiring it here would make the gate unrunnable on
# a machine that only has make.
GEN_ARG=()
command -v ninja >/dev/null 2>&1 && GEN_ARG=(-G Ninja)

if cmake -S "$ROOT" -B "$BUILD_DIR" \
         -DCMAKE_BUILD_TYPE=Release \
         "${GEN_ARG[@]}" "${MAHINA_ARG[@]}" > "$LOGS/configure.log" 2>&1; then
    pass "configure ($(grep -m1 '^-- Mahina:' "$LOGS/configure.log" | sed 's/^-- Mahina: //'))"
else
    cat "$LOGS/configure.log"
    fail "cmake configure"
    printf '\nAborting: nothing else can run without a configured build.\n'
    exit 1
fi

if cmake --build "$BUILD_DIR" --parallel "$JOBS" > "$LOGS/build.log" 2>&1; then
    pass "compile ($JOBS jobs)"
else
    tail -60 "$LOGS/build.log"
    fail "compile"
    printf '\nAborting: the remaining gates need the built artefacts.\n'
    exit 1
fi

# ------------------------------------------------------------------ ctest ----
# The unit tests cover the pure core — the guard, the diff and pivot and
# expectation engines, the export writers, and the JS modules loaded straight
# out of src/qml so the tested file is the shipped file.
step "Unit tests"
if ctest --test-dir "$BUILD_DIR" --output-on-failure > "$LOGS/ctest.log" 2>&1; then
    # "100% tests passed, 0 tests failed out of 5" — the count worth printing is
    # the last number, and the leading "100%" is not a digit run grep can anchor on.
    pass "$(sed -n 's/.*tests failed out of \([0-9]*\).*/\1 tests passed/p' \
                "$LOGS/ctest.log" | head -1)"
else
    tail -40 "$LOGS/ctest.log"
    fail "ctest"
fi

# ----------------------------------------------------------- boot smoke ----
# Booting the app is the only check that exercises QML at runtime: qmllint reads
# files in isolation and cannot see a binding that resolves to undefined once
# the real singletons are in place. The gate is silence, not merely survival —
# Qt reports a broken binding on stderr without exiting non-zero, so an app that
# stays up while printing warnings has still regressed.
step "Boot headless"
APP="$BUILD_DIR/qub"
if [ ! -x "$APP" ]; then
    fail "qub binary not found at $APP"
else
    # An isolated XDG profile keeps the run reproducible: qub creates its
    # settings and its SQLite databases on first launch, and a developer's real
    # profile already has both. It also stops Qt warning about an unset
    # XDG_RUNTIME_DIR, which would trip the silence gate.
    PROFILE="$BUILD_DIR/boot-profile"
    rm -rf "$PROFILE"
    mkdir -p "$PROFILE"/{config,data,cache,run}
    chmod 700 "$PROFILE/run"

    # DBUS_SESSION_BUS_ADDRESS is cleared deliberately. qtkeychain talks to the
    # Secret Service over the session bus, and CI has none; unsetting it here
    # means a developer run hits the same absence rather than passing on a
    # desktop and failing on the runner.
    env -u DBUS_SESSION_BUS_ADDRESS -u DISPLAY -u WAYLAND_DISPLAY \
        QT_QPA_PLATFORM=offscreen \
        XDG_CONFIG_HOME="$PROFILE/config" XDG_DATA_HOME="$PROFILE/data" \
        XDG_CACHE_HOME="$PROFILE/cache"   XDG_RUNTIME_DIR="$PROFILE/run" \
        timeout "$BOOT_SECONDS" "$APP" > "$LOGS/boot.log" 2>&1
    STATUS=$?
    LINES=$(wc -l < "$LOGS/boot.log")

    if [ "$STATUS" -ne 124 ]; then
        # 124 is the good case: still running when timeout(1) killed it.
        cat "$LOGS/boot.log"
        fail "qub exited early (status $STATUS) instead of staying up"
    elif [ "$LINES" -ne 0 ]; then
        cat "$LOGS/boot.log"
        fail "qub booted but printed $LINES line(s) — QML warnings are regressions"
    else
        pass "stayed up ${BOOT_SECONDS}s, silent"
    fi
fi

# -------------------------------------------------------------- qmllint ----
step "qmllint"
cmake --build "$BUILD_DIR" --target all_qmllint > "$LOGS/qmllint.log" 2>&1

ERRORS=$(grep -c '^Error:' "$LOGS/qmllint.log")
if [ "$ERRORS" -ne 0 ]; then
    grep '^Error:' "$LOGS/qmllint.log"
    fail "$ERRORS qmllint error(s)"
else
    pass "0 errors"
fi

# Warnings are counted per category and held against a checked-in ceiling. The
# repo carries a backlog too large to clear in one change, so the gate is a
# ratchet: a category may shrink freely, never grow. Lower the numbers in
# scripts/qmllint-baseline.txt as the backlog is worked off (--update-baseline).
COUNTS="$LOGS/qmllint-counts.txt"
grep '^Warning:' "$LOGS/qmllint.log" \
    | sed -n 's/.*\[\([A-Za-z0-9._-]*\)\]$/\1/p' \
    | sort | uniq -c | awk '{print $2, $1}' > "$COUNTS"
# Warnings qmllint emits with no category tag still have to be counted somewhere.
UNCAT=$(grep '^Warning:' "$LOGS/qmllint.log" | grep -cv '\[[A-Za-z0-9._-]*\]$')
if [ "$UNCAT" -gt 0 ]; then echo "uncategorised $UNCAT" >> "$COUNTS"; fi
sort -o "$COUNTS" "$COUNTS"

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    {
        echo "# qmllint warning ceilings, one per category. Regenerate with:"
        echo "#     bash scripts/ci-check.sh --update-baseline"
        echo "#"
        echo "# A category may shrink freely; growing one fails CI. The counts are tied"
        echo "# to the Qt version CI pins, since qmllint gains checks between releases."
        cat "$COUNTS"
    } > "$BASELINE"
    pass "baseline written to scripts/qmllint-baseline.txt"
elif [ ! -f "$BASELINE" ]; then
    fail "no baseline at scripts/qmllint-baseline.txt (create one with --update-baseline)"
else
    REGRESSED=0
    while read -r category count; do
        ceiling=$(awk -v c="$category" '$1 == c {print $2}' "$BASELINE")
        if [ -z "$ceiling" ]; then
            fail "new warning category '$category' ($count) — not in the baseline"
            REGRESSED=1
        elif [ "$count" -gt "$ceiling" ]; then
            fail "$category: $count warnings, baseline allows $ceiling"
            REGRESSED=1
        elif [ "$count" -lt "$ceiling" ]; then
            note "$category: $count (baseline $ceiling) — --update-baseline locks the win in"
        fi
    done < "$COUNTS"
    if [ "$REGRESSED" -eq 0 ]; then
        pass "$(awk '{s+=$2} END {print s+0}' "$COUNTS") warnings, all within baseline"
    fi
fi

# ------------------------------------------------------------------ aot ----
# Informational, never a gate: the number moves with the Qt version and with how
# much QML a change happens to touch, so pinning a threshold to it would fail
# for reasons unrelated to the change under review. It is printed because a
# change that quietly halves ahead-of-time coverage should be visible in the run
# that introduced it.
step "AOT coverage (informational)"
if cmake --build "$BUILD_DIR" --target all_aotstats > "$LOGS/aotstats.log" 2>&1; then
    # qmlaotstats prints a bare "Module X:" header before the table as well as
    # the summary line; require a count so only the latter is echoed.
    grep -E '^(Module .*|Total results): *[0-9]' "$LOGS/aotstats.log" | sed 's/^/   /'
else
    note "all_aotstats unavailable in this Qt build"
fi

# --------------------------------------------------------------- report ----
step "Summary"
if [ ${#FAILED[@]} -eq 0 ]; then
    printf '   all gates passed\n\n'
    exit 0
fi
printf '   %d gate(s) failed:\n' "${#FAILED[@]}"
printf '     - %s\n' "${FAILED[@]}"
printf '\n   Logs in %s\n\n' "$LOGS"
exit 1
