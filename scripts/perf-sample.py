#!/usr/bin/env python3
"""Sample qub's CPU and memory from /proc, so the numbers in the docs can be re-run.

Everything here comes out of /proc for one process:

    stat           utime+stime, divided by SC_CLK_TCK, differenced between samples
    status         VmRSS
    smaps_rollup   Pss, and the Private_Dirty / Private_Clean / Shared_Clean split
    smaps          per-mapping Pss, for --maps
    task/          thread count
    fd/            open descriptor count

RSS counts every page mapped in, shared libraries included, so three Qt apps each
"use" the same libQt6Quick. PSS divides a shared page by the number of processes
sharing it, which is the number that answers "what does this cost the machine".
Both are reported; PSS is the honest one.

Usage
-----
    scripts/perf-sample.py -d 90 -o run.csv -- ./build/qub
    scripts/perf-sample.py -d 45 -o off.csv --maps 12 -- env QT_QPA_PLATFORM=offscreen ./build/qub
    scripts/perf-sample.py -d 60 --pid 12345

Launching the process itself (the `--` form) is what makes a run repeatable: the
sampler starts before the first frame, so startup-to-idle is measured rather than
guessed. `--pid` attaches to something already running and reports no startup.

Linux only — smaps_rollup exists nowhere else.
"""

import argparse
import os
import signal
import subprocess
import sys
import time

HZ = os.sysconf("SC_CLK_TCK")


# ── /proc readers ─────────────────────────────────────────────────────────────

def cpu_ticks(pid):
    with open(f"/proc/{pid}/stat") as f:
        # The comm field is parenthesised and may itself contain spaces and
        # parens, so split on the *last* ')' rather than tokenising from the
        # left. utime and stime are fields 14 and 15 one-based; that split
        # drops pid and comm, putting them at 11 and 12.
        fields = f.read().rsplit(")", 1)[1].split()
    return int(fields[11]) + int(fields[12])


def rss_kb(pid):
    with open(f"/proc/{pid}/status") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    return 0


def rollup(pid):
    """Pss plus the private/shared split, in kB. Empty if smaps_rollup is absent."""
    out = {}
    try:
        with open(f"/proc/{pid}/smaps_rollup") as f:
            for line in f:
                key, _, rest = line.partition(":")
                if key in ("Pss", "Private_Dirty", "Private_Clean", "Shared_Clean",
                           "Shared_Dirty"):
                    out[key] = int(rest.split()[0])
    except OSError:
        pass
    return out


def maps_by_pss(pid):
    """Per-mapping Pss in kB, largest first, merged by mapping name.

    An anonymous mapping has no name and is reported as [anon]; the rest keep
    whatever the kernel calls them ([heap], a library path, [anon:JSGCHeap:QtQml]).
    Named mappings appear once per segment — text, rodata, data — so they are
    summed, which is why a library's number here is larger than any one line of
    /proc/PID/maps.
    """
    totals = {}
    try:
        f = open(f"/proc/{pid}/smaps")
    except OSError:
        return []
    with f:
        name = "[anon]"
        for line in f:
            if line.startswith("Pss:"):
                totals[name] = totals.get(name, 0) + int(line.split()[1])
            elif "-" in line.split(maxsplit=1)[0] and ":" not in line.split(maxsplit=1)[0]:
                # A header line: address range, perms, offset, dev, inode, [path].
                parts = line.split(maxsplit=5)
                path = parts[5].strip() if len(parts) > 5 else ""
                name = os.path.basename(path) if path.startswith("/") else (path or "[anon]")
    return sorted(totals.items(), key=lambda kv: -kv[1])


def threads(pid):
    return len(os.listdir(f"/proc/{pid}/task"))


def fds(pid):
    try:
        return len(os.listdir(f"/proc/{pid}/fd"))
    except OSError:
        return 0   # not ours to read


# ── sampling ──────────────────────────────────────────────────────────────────

def sample(pid, duration, interval, idle_pct, t0=None, base_ticks=None):
    """Poll until `duration` elapses or the process exits. Returns (rows, startup).

    startup is (wall_seconds, cpu_seconds) at the first moment the process went
    quiet — two consecutive samples under idle_pct — or None if it never did. It
    is only meaningful when t0 and base_ticks were taken at launch; the caller
    passes those in, because by the time this function runs the process has
    already been up long enough to burn most of its startup CPU.

    Two consecutive quiet samples means the earliest startup this can report is
    2 x interval. Pass a small --interval when that number is the point.
    """
    rows = []
    startup = None
    quiet = 0

    if t0 is None:
        t0 = time.monotonic()
    if base_ticks is None:
        base_ticks = cpu_ticks(pid)
    prev_ticks = cpu_ticks(pid)
    prev_t = time.monotonic()

    while time.monotonic() - t0 < duration:
        time.sleep(interval)
        try:
            now = time.monotonic()
            ticks = cpu_ticks(pid)
            cpu = (ticks - prev_ticks) / HZ / (now - prev_t) * 100.0
            roll = rollup(pid)
            rows.append({
                "t":       round(now - t0, 2),
                "cpu_pct": round(cpu, 2),
                "rss_kb":  rss_kb(pid),
                "pss_kb":  roll.get("Pss", 0),
                "threads": threads(pid),
                "fds":     fds(pid),
            })
            prev_ticks, prev_t = ticks, now

            if startup is None:
                quiet = quiet + 1 if cpu < idle_pct else 0
                if quiet == 2:
                    startup = (now - t0, (ticks - base_ticks) / HZ)
        except (FileNotFoundError, ProcessLookupError):
            print("process exited during sampling", file=sys.stderr)
            break

    return rows, startup


# ── reporting ─────────────────────────────────────────────────────────────────

def mb(kb):
    return kb / 1024.0


def report(rows, startup, roll, maps, top):
    n = len(rows)
    if not n:
        print("no samples collected", file=sys.stderr)
        return

    def col(k):
        return [r[k] for r in rows]

    cpu, rss, pss = col("cpu_pct"), col("rss_kb"), col("pss_kb")

    print(f"samples      {n} over {rows[-1]['t']:.1f}s")
    if startup:
        print(f"startup      {startup[0]:.2f}s wall to idle, {startup[1]:.2f}s CPU spent")
    else:
        print("startup      never went idle (or attached to a running process)")
    print(f"cpu %        mean {sum(cpu)/n:6.2f}   max {max(cpu):6.2f}")
    print(f"rss MB       mean {mb(sum(rss)/n):6.1f}   max {mb(max(rss)):6.1f}   last {mb(rss[-1]):6.1f}")
    print(f"pss MB       mean {mb(sum(pss)/n):6.1f}   max {mb(max(pss)):6.1f}   last {mb(pss[-1]):6.1f}")
    print(f"threads      {col('threads')[-1]}   fds {col('fds')[-1]}")

    # The leak line. Max minus last over a run where the app was left alone: if
    # it is zero the resident set came back to where it peaked, so nothing was
    # retained. It says nothing about behaviour under load.
    print(f"rss drift    max - last = {mb(max(rss) - rss[-1]):+.1f} MB")

    if roll:
        print("rollup MB    " + "  ".join(
            f"{k} {mb(v):.2f}" for k, v in sorted(roll.items())))

    if maps:
        print(f"\ntop {min(top, len(maps))} mappings by PSS (MB)")
        for name, kb in maps[:top]:
            print(f"  {mb(kb):8.1f}  {name}")


def write_csv(path, rows):
    cols = ["t", "cpu_pct", "rss_kb", "pss_kb", "threads", "fds"]
    with open(path, "w") as f:
        f.write(",".join(cols) + "\n")
        for r in rows:
            f.write(",".join(str(r[c]) for c in cols) + "\n")


# ── entry point ───────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Sample a process's CPU and memory from /proc.",
        epilog="Give either --pid, or -- followed by the command to launch.")
    ap.add_argument("-d", "--duration", type=float, default=60.0,
                    help="seconds to sample for (default 60)")
    ap.add_argument("-i", "--interval", type=float, default=0.5,
                    help="seconds between samples (default 0.5)")
    ap.add_argument("-o", "--csv", metavar="FILE",
                    help="write the per-sample rows here as CSV")
    ap.add_argument("--maps", type=int, nargs="?", const=12, default=0, metavar="N",
                    help="also print the N largest mappings by PSS (default 12)")
    ap.add_argument("--idle-pct", type=float, default=2.0,
                    help="CPU %% below which the process counts as idle (default 2)")
    ap.add_argument("--pid", type=int, help="sample a process that is already running")
    ap.add_argument("command", nargs=argparse.REMAINDER,
                    help="command to launch and sample, after --")
    args = ap.parse_args()

    if not sys.platform.startswith("linux"):
        sys.exit("perf-sample.py reads /proc; it only runs on Linux")

    cmd = args.command[1:] if args.command[:1] == ["--"] else args.command
    if bool(args.pid) == bool(cmd):
        sys.exit("give either --pid or -- <command>, not both and not neither")

    proc = None
    t0 = base_ticks = None
    if cmd:
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL)
        except OSError as e:
            sys.exit(f"could not launch {cmd[0]}: {e.strerror}")
        pid = proc.pid
        # Take the clock and the tick baseline here, not inside sample(): the
        # liveness check below costs a tenth of a second, and a Qt app spends a
        # good part of its startup CPU in that window. Reading the baseline
        # afterwards would charge it to nobody and report a startup of ~0.
        t0 = time.monotonic()
        base_ticks = cpu_ticks(pid)
        # /proc/<pid> exists the moment fork returns, so a command that dies
        # instantly (a typo in the path) is only caught by waiting a moment.
        time.sleep(0.1)
        if proc.poll() is not None:
            sys.exit(f"{cmd[0]} exited immediately with {proc.returncode}")
    else:
        pid = args.pid
        if not os.path.isdir(f"/proc/{pid}"):
            sys.exit(f"no process {pid}")

    try:
        rows, startup = sample(pid, args.duration, args.interval, args.idle_pct,
                               t0, base_ticks)
        if proc is None:
            # Attached mid-life: the process went idle before we arrived, and
            # "1.0s to idle" would be measuring our own start, not its.
            startup = None
        # Read the composition while the process is still alive; both vanish
        # with it, and they are a snapshot of the end of the run, not a mean.
        roll = rollup(pid)
        maps = maps_by_pss(pid) if args.maps else []
    finally:
        if proc and proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

    if args.csv:
        write_csv(args.csv, rows)
    report(rows, startup, roll, maps, args.maps or 0)


if __name__ == "__main__":
    main()
