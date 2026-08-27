#!/usr/bin/env bash
# qub's load test: drive the real UI against a million rows, for as many cycles
# as you ask, and report what the process was holding at the end against what it
# was holding after the first one.
#
#     bash scripts/load-test.sh                  # 20 cycles, 1000-row results
#     bash scripts/load-test.sh -n 40 -r 20000   # longer, and heavier per run
#     bash scripts/load-test.sh --heaptrack      # attribute what is retained
#
# Why a driven UI and not a benchmark harness: the panels are the expensive part.
# A query against SQLite costs a millisecond; building a chart, a per-column
# profile and a pivot out of its result costs orders of magnitude more, and those
# only run when something clicks the tab. Anything that measures the executor
# alone measures the cheap half.
#
# The app runs on its own Xvfb display with its own XDG directories, so it never
# touches the real desktop or the real qub.db, and the run is repeatable. There
# is no window manager: the window is unmanaged at a fixed 1280x800 with no
# decoration, which is what makes the click coordinates below stable, and it
# means input focus follows the pointer — every keystroke here is preceded by a
# mousemove into the widget that should receive it.
#
# Linux only: it reads /proc for the numbers and needs Xvfb, xdotool and
# ImageMagick's `import`.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CYCLES=20
ROWS=1000
HEAPTRACK=0
KEEP=0
BINARY="$ROOT/build-ci/qub"
WORK="${TMPDIR:-/tmp}/qub-load"

while [ $# -gt 0 ]; do
    case "$1" in
        -n|--cycles)   CYCLES="$2"; shift 2 ;;
        -r|--rows)     ROWS="$2";   shift 2 ;;
        -b|--binary)   BINARY="$2"; shift 2 ;;
        -w|--work)     WORK="$2";   shift 2 ;;
        --heaptrack)   HEAPTRACK=1; shift ;;
        --keep)        KEEP=1; shift ;;
        -h|--help)     sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

for tool in Xvfb xdotool import python3; do
    command -v "$tool" > /dev/null 2>&1 || { echo "missing $tool" >&2; exit 1; }
done
[ -x "$BINARY" ] || { echo "no binary at $BINARY (build first, or pass -b)" >&2; exit 1; }
[ "$HEAPTRACK" = 0 ] || command -v heaptrack > /dev/null 2>&1 || {
    echo "--heaptrack asked for but heaptrack is not installed" >&2; exit 1; }

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }
note() { printf '   \033[36m--\033[0m   %s\n' "$1"; }

DB="$WORK/events.db"
PROFILE="$WORK/profile"
OUT="$WORK/run"
mkdir -p "$WORK" "$OUT" || exit 1

# ─────────────────────────────────────────────────────────── the fixture ────
# A million rows of a shape the panels can all do something with: a timestamp to
# order by, two low-cardinality columns to group and pivot on, a numeric column
# to chart and aggregate, and a text column wide enough that the rows are not
# all cache-resident. Seeded, so two runs on two machines load the same bytes.
# Kept between runs — it takes longer to build than the test takes to run.
step "Fixture"
if [ -s "$DB" ]; then
    note "reusing $DB ($(du -h "$DB" | cut -f1))"
else
    python3 - "$DB" <<'PYEOF'
import sqlite3, sys, random, datetime, os
path = sys.argv[1]
tmp  = path + ".partial"
if os.path.exists(tmp): os.remove(tmp)
db = sqlite3.connect(tmp)
db.execute("PRAGMA journal_mode=OFF"); db.execute("PRAGMA synchronous=OFF")
db.execute("""CREATE TABLE events (
    id INTEGER PRIMARY KEY, ts TEXT NOT NULL, region TEXT NOT NULL,
    channel TEXT NOT NULL, customer_id INTEGER NOT NULL, amount REAL NOT NULL,
    status TEXT NOT NULL, note TEXT)""")
db.execute("""CREATE TABLE customers (
    id INTEGER PRIMARY KEY, name TEXT NOT NULL, region TEXT NOT NULL,
    signup TEXT NOT NULL)""")
random.seed(7)
regions  = ["north", "south", "east", "west", "central"]
channels = ["web", "mobile", "api", "partner", "store"]
statuses = ["ok", "pending", "failed", "refunded"]
base = datetime.datetime(2025, 1, 1)
db.executemany("INSERT INTO customers VALUES (?,?,?,?)",
    ((i, "customer %05d" % i, random.choice(regions),
      (base + datetime.timedelta(days=random.randint(0, 600))).date().isoformat())
     for i in range(1, 20001)))
db.executemany("INSERT INTO events VALUES (?,?,?,?,?,?,?,?)",
    ((i, (base + datetime.timedelta(seconds=i * 31)).isoformat(sep=" "),
      random.choice(regions), random.choice(channels),
      random.randint(1, 20000), round(random.uniform(1, 5000), 2),
      random.choice(statuses), "note %d %s" % (i, "x" * random.randint(0, 60)))
     for i in range(1, 1_000_001)))
db.execute("CREATE INDEX idx_events_customer ON events(customer_id)")
db.commit(); db.close()
os.rename(tmp, path)
PYEOF
    [ -s "$DB" ] || { echo "fixture build failed" >&2; exit 1; }
    note "built $DB ($(du -h "$DB" | cut -f1))"
fi

# ────────────────────────────────────────────────────── isolated profile ────
# AppDataLocation follows XDG_DATA_HOME, so pointing the three XDG variables at
# a scratch directory gives the run its own connections.json, qub.db, history
# and settings. connections.json is seeded rather than typed into the connection
# form: ConnectionManager::load() reopens what it finds there at startup, so the
# app comes up already connected, and a SQLite source needs no password, so the
# keychain is never asked for one.
step "Profile"
rm -rf "$PROFILE"
mkdir -p "$PROFILE/data/qub/qub" "$PROFILE/config" "$PROFILE/cache" || exit 1
cat > "$PROFILE/data/qub/qub/connections.json" <<EOF
{"version":1,"connections":[{"name":"loadtest","driver":"QSQLITE","host":"","port":0,
"database":"$DB","username":"","profileId":"","sshConfigId":"","ssl":false,
"sslCaCert":"","sslClientCert":"","sslClientKey":"","timeout":30,"schema":"",
"lastModified":"2026-01-01T00:00:00"}]}
EOF
note "$PROFILE"

# ─────────────────────────────────────────────────────────────── display ────
DISPLAY_NUM=99
while [ -e "/tmp/.X11-unix/X$DISPLAY_NUM" ]; do DISPLAY_NUM=$((DISPLAY_NUM + 1)); done
export DISPLAY=":$DISPLAY_NUM"
Xvfb "$DISPLAY" -screen 0 1280x800x24 -nolisten tcp > "$OUT/xvfb.log" 2>&1 &
XVFB_PID=$!
for _ in $(seq 20); do xdotool getdisplaygeometry > /dev/null 2>&1 && break; sleep 0.2; done
xdotool getdisplaygeometry > /dev/null 2>&1 || { echo "Xvfb did not come up" >&2; exit 1; }

APP_PID=""
WIN=""
# The app is signalled, not closed. Qt installs no SIGTERM handler, so this is
# an abrupt death with static destructors unrun — which matters for exactly one
# number: under --heaptrack, everything still allocated is reported as "leaked",
# and here that is live data, not a leak. Read the cycle-to-cycle curve for
# retention and heaptrack only for attribution. Closing the window politely
# instead was tried: with no window manager on the display, WM_DELETE_WINDOW is
# not reliably honoured — four attempts out of five left the app running, and
# the fifth exited through a segfault worth its own look.
cleanup() {
    [ -n "$APP_PID" ] && kill "$APP_PID" 2> /dev/null
    sleep 1
    [ -n "$APP_PID" ] && kill -9 "$APP_PID" 2> /dev/null
    kill "$XVFB_PID" 2> /dev/null
    [ "$KEEP" = 1 ] || rm -rf "$PROFILE"
}
trap cleanup EXIT

# ────────────────────────────────────────────────────────────── the app ────
# QT_QPA_PLATFORM is forced because this is very likely running inside a Wayland
# session: Qt would pick the wayland plugin, open the window on the real desktop
# and leave Xvfb black, which is exactly what happened the first time.
# DBUS_SESSION_BUS_ADDRESS is cleared for the same reason ci-check.sh clears it —
# a portal dialog on the developer's actual screen is not part of the test.
step "Launch"
LAUNCH=("$BINARY")
[ "$HEAPTRACK" = 0 ] || LAUNCH=(heaptrack -o "$OUT/heaptrack" "$BINARY")
env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE \
    QT_QPA_PLATFORM=xcb \
    XDG_DATA_HOME="$PROFILE/data" \
    XDG_CONFIG_HOME="$PROFILE/config" \
    XDG_CACHE_HOME="$PROFILE/cache" \
    DBUS_SESSION_BUS_ADDRESS= \
    "${LAUNCH[@]}" > "$OUT/app.log" 2>&1 &
APP_PID=$!

# Several X windows answer to the name "qub" — a 10x10 utility window and a 1x1
# one alongside the real thing — and the first match is not the toplevel. Pick
# by geometry: only one of them is the 1280x800 window, and closing the wrong
# one at the end does nothing at all.
for _ in $(seq 60); do
    for w in $(xdotool search --name '^qub$' 2> /dev/null); do
        case "$(xdotool getwindowgeometry --shell "$w" 2> /dev/null)" in
            *WIDTH=1280*HEIGHT=800*) WIN="$w"; break ;;
        esac
    done
    [ -n "$WIN" ] && break
    sleep 0.5
done
[ -n "$WIN" ] || { echo "no qub window appeared; see $OUT/app.log" >&2; exit 1; }
# Under heaptrack the process we sample is the child, not the launcher.
if [ "$HEAPTRACK" = 1 ]; then
    APP_PID="$(pgrep -P "$APP_PID" -f "$(basename "$BINARY")" | head -1)"
    [ -n "$APP_PID" ] || { echo "could not find the traced process" >&2; exit 1; }
fi
note "window $WIN, pid $APP_PID"

# ───────────────────────────────────────────────────────────── the driver ───
# Fixed coordinates, because the window is a fixed size and nothing manages it.
# The result-pane tabs sit in one row under the editor; the editor's first line
# is near the top. Read them off a screenshot if the layout ever moves.
ED_X=600;  ED_Y=100          # the editor's first line
# Checks and Diff are not driven: one needs rules added through a dialog and the
# other a saved baseline, and neither is where the time goes. Chart, Profile,
# Pivot and Explain are the four that compute something over the whole result.
declare -A PANE=( [results]=273 [output]=357 [chart]=435 [profile]=511
                  [explain]=593 [pivot]=671 [checks]=750 [diff]=829 )
PANE_Y=410

click()  { xdotool mousemove "$1" "$2" click 1; sleep "${3:-0.4}"; }
# On the first cycle each pane is photographed as it is opened. Without that the
# run reports numbers for a sequence of clicks nobody ever confirmed landed on
# anything: a mistyped coordinate would still produce a plausible-looking report.
pane()   {
    click "${PANE[$1]}" "$PANE_Y" "${2:-1.2}"
    [ "$CUR_CYCLE" = 1 ] && import -window root "$OUT/pane-$1.png" 2> /dev/null
    return 0
}
CUR_CYCLE=0
# Opening the Explain pane shows an empty state: the plan is computed by Ctrl+E,
# not by looking at the tab. Clicking the tab alone measured nothing, which the
# first-cycle screenshot is what caught.
explain() {
    xdotool mousemove "$ED_X" "$ED_Y"
    xdotool key ctrl+e
    sleep "${1:-2.0}"
}
typesql() {
    xdotool mousemove "$ED_X" "$ED_Y" click 1
    sleep 0.3
    xdotool key ctrl+a
    xdotool type --delay 6 "$1"
    sleep 0.3
    xdotool key ctrl+Return
    sleep "${2:-2.5}"
}

Q1="SELECT id, ts, region, channel, customer_id, amount, status, note FROM events ORDER BY id LIMIT $ROWS"
Q2="SELECT region, channel, count(*) AS n, sum(amount) AS total, avg(amount) AS mean FROM events GROUP BY region, channel ORDER BY total DESC"
Q3="SELECT e.id, e.ts, c.name, c.region, e.amount, e.status FROM events e JOIN customers c ON c.id = e.customer_id ORDER BY e.id LIMIT $ROWS"

# Home shows the seeded data source as a row; clicking it opens the workspace.
# The click is verified rather than assumed: the Run button is the one solidly
# blue thing on the screen and it exists only in the workspace, so reading that
# pixel says whether the app moved. A run that starts on the Home screen types a
# thousand keystrokes into nothing and still reports a plausible memory curve —
# which is exactly what happened under heaptrack, where everything is slow
# enough that the first click landed before the window was ready.
step "Drive"
in_workspace() {
    local px
    px="$(import -window root -crop 1x1+911+61 -depth 8 txt:- 2> /dev/null \
          | sed -n 's/.*srgb(\([0-9]*\),\([0-9]*\),\([0-9]*\)).*/\1 \2 \3/p')"
    [ -n "$px" ] || return 1
    set -- $px
    [ "$3" -gt 150 ] && [ "$3" -gt $(( $1 + 40 )) ]
}
opened=0
for _ in $(seq 10); do
    click 600 305 3
    if in_workspace; then opened=1; break; fi
done
[ "$opened" = 1 ] || { echo "never reached the workspace; see $OUT/app.log" >&2
                       import -window root "$OUT/stuck.png" 2> /dev/null; exit 1; }

# ─────────────────────────────────────────────────────────── the sampler ────
# One reader, called between cycles, so a sample is always taken at the same
# point in the loop: after a full pass, with nothing in flight. RSS counts every
# page mapped in, shared libraries included; PSS charges a shared page by the
# number of processes sharing it, which is the number that answers "what does
# this cost the machine". Both are recorded, PSS is the honest one.
sample() {
    python3 - "$APP_PID" "$1" "$OUT/samples.csv" <<'PYEOF'
import os, sys
pid, cycle, out = sys.argv[1], sys.argv[2], sys.argv[3]
def field(path, key):
    try:
        for line in open("/proc/%s/%s" % (pid, path)):
            if line.startswith(key):
                return int(line.split()[1])
    except OSError:
        pass
    return 0
with open("/proc/%s/stat" % pid) as f:
    st = f.read().rsplit(")", 1)[1].split()
cpu = (int(st[11]) + int(st[12])) / os.sysconf("SC_CLK_TCK")
row = dict(cycle=cycle,
           rss_kb=field("status", "VmRSS:"),
           pss_kb=field("smaps_rollup", "Pss:"),
           priv_kb=field("smaps_rollup", "Private_Dirty:"),
           cpu_s=round(cpu, 2),
           threads=len(os.listdir("/proc/%s/task" % pid)),
           fds=len(os.listdir("/proc/%s/fd" % pid)))
cols = ["cycle", "rss_kb", "pss_kb", "priv_kb", "cpu_s", "threads", "fds"]
new = not os.path.exists(out)
with open(out, "a") as f:
    if new: f.write(",".join(cols) + "\n")
    f.write(",".join(str(row[c]) for c in cols) + "\n")
print("   cycle %-3s rss %6.1f MB   pss %6.1f MB   cpu %6.1fs   threads %2d   fds %3d"
      % (cycle, row["rss_kb"] / 1024, row["pss_kb"] / 1024, row["cpu_s"],
         row["threads"], row["fds"]))
PYEOF
}

rm -f "$OUT/samples.csv"
sample 0

for c in $(seq 1 "$CYCLES"); do
    CUR_CYCLE="$c"
    typesql "$Q1" 3
    pane chart
    pane profile 2.0
    pane pivot
    pane results 0.6

    typesql "$Q2" 4          # a full scan and a group-by: the slow one
    pane chart
    pane results 0.6

    typesql "$Q3" 3          # a join, so the model holds columns from two tables
    pane profile 2.0
    explain
    pane explain
    pane results 0.6

    sample "$c"
    if [ ! -d "/proc/$APP_PID" ]; then
        echo "   the app died in cycle $c; see $OUT/app.log" >&2
        break
    fi
done

import -window root "$OUT/final.png" 2> /dev/null

# ───────────────────────────────────────────────────────────── the report ───
# Cycle 1 against the last: both are taken at the same point in an identical
# pass, so a rising resident set is retention, not warm-up. Peak matters as much
# as the end value — the app has to survive the peak on the user's machine.
step "Result"
python3 - "$OUT/samples.csv" "$CYCLES" <<'PYEOF'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
if len(rows) < 2:
    sys.exit("not enough samples")
n = lambda r, k: int(r[k])
first, last = rows[1], rows[-1]
mb = lambda kb: kb / 1024.0
print("   cycles run   %s" % last["cycle"])
print("   rss    MB    cycle 1 %6.1f   last %6.1f   peak %6.1f   drift %+.1f"
      % (mb(n(first, "rss_kb")), mb(n(last, "rss_kb")),
         mb(max(n(r, "rss_kb") for r in rows)),
         mb(n(last, "rss_kb") - n(first, "rss_kb"))))
print("   pss    MB    cycle 1 %6.1f   last %6.1f   peak %6.1f   drift %+.1f"
      % (mb(n(first, "pss_kb")), mb(n(last, "pss_kb")),
         mb(max(n(r, "pss_kb") for r in rows)),
         mb(n(last, "pss_kb") - n(first, "pss_kb"))))
print("   private MB   cycle 1 %6.1f   last %6.1f   drift %+.1f"
      % (mb(n(first, "priv_kb")), mb(n(last, "priv_kb")),
         mb(n(last, "priv_kb") - n(first, "priv_kb"))))
print("   cpu     s    %.1f total, %.2f per cycle"
      % (float(last["cpu_s"]),
         (float(last["cpu_s"]) - float(rows[0]["cpu_s"])) / max(1, int(last["cycle"]))))
print("   threads      %s -> %s      fds %s -> %s"
      % (first["threads"], last["threads"], first["fds"], last["fds"]))
# The first cycles are warm-up, not retention: fonts, the QML cache, the SQLite
# page cache and glibc's arenas all fill on the way to a steady state. A slope
# fitted over the back half is what says whether the app keeps growing once it
# is warm; the earlier number would have charged warm-up to a leak.
half = rows[1 + len(rows) // 2:]
if len(half) >= 3:
    xs = [(int(r["cycle"]), mb(n(r, "rss_kb"))) for r in half]
    mx = sum(x for x, _ in xs) / len(xs)
    my = sum(y for _, y in xs) / len(xs)
    slope = (sum((x - mx) * (y - my) for x, y in xs)
             / sum((x - mx) ** 2 for x, _ in xs))
    print("\n   %+.2f MB of RSS per cycle over the last %d cycles (fitted),"
          % (slope, len(xs)))
    print("   against %+.2f MB per cycle measured from cycle 1, which is warm-up."
          % mb((n(last, "rss_kb") - n(first, "rss_kb")) / max(1, int(last["cycle"]) - 1)))
else:
    print("\n   %+.2f MB of RSS per cycle after the first (too few cycles to fit)."
          % mb((n(last, "rss_kb") - n(first, "rss_kb")) / max(1, int(last["cycle"]) - 1)))
PYEOF
note "samples  $OUT/samples.csv"
note "log      $OUT/app.log"
note "screen   $OUT/final.png, plus $OUT/pane-*.png from the first cycle"
[ "$HEAPTRACK" = 0 ] || note "heaptrack $OUT/heaptrack.*.zst — heaptrack_print or heaptrack_gui"
