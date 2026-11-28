#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# ///
"""Frame times of the headless Storybook, one build against another.

Runs the examples' headless Storybook (built with -c opt and
--@isomer//headless) under ISO_RENDER_LOG, drives a few stories through the
headless protocol (JSON lines on standard input and output), and reads each
frame's render-log line: its kind, what it wrote and built, and its time, the
build's and the renderer's apart (FrameLog.swift). Each binary given runs
every workload once a round, in an order rotated each round, so a busy
machine weighs on them alike; the paired figure is the median over rounds of
each round's median against the first binary's.

  cd examples
  bazel build -c opt --@isomer//headless //headless/storybook_headless_application
  cp "$(bazel cquery -c opt --@isomer//headless --output=files \\
      //headless/storybook_headless_application)" /tmp/storybook_base
  # ... the change, built again, copied to /tmp/storybook_new ...
  uv run tools/bench/headless_frames.py base=/tmp/storybook_base new=/tmp/storybook_new

Workloads (--workloads, comma-separated; all by default):
  index       the Storybook's index at 1024 wide (a split view), taps
              alternating between two stories
  form        lists.form: the Notifications toggle, off and on
  navigation  navigation.links: Mars pushed, then back
  search      lists.search: a query typed a letter at a time, then cleared

(No scrolling: the driver's swipe drives drag gestures, not scroll views.)

The headless head lays out each frame as the self-drawing renderer does
(drawn chrome, whole builds); ISO_PARTIAL and the like pass through from the
environment.
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import sys

WORKLOADS = {
    "index": {
        "env": {"ISO_HEADLESS_WIDTH": "1024", "ISO_HEADLESS_HEIGHT": "768"},
        "cycle": [{"cmd": "tap", "target": "List and Section"}, {"cmd": "tap", "target": "Form"}],
    },
    "form": {
        "story": "lists.form",
        "cycle": [
            {"cmd": "set", "target": "Notifications", "value": "0"},
            {"cmd": "set", "target": "Notifications", "value": "1"},
        ],
    },
    "navigation": {
        "story": "navigation.links",
        "cycle": [{"cmd": "tap", "target": "Mars"}, {"cmd": "back"}],
    },
    "search": {
        "story": "lists.search",
        "cycle": [
            {"cmd": "type", "target": "Search cities", "text": t} for t in ["L", "Lo", "Lon", "Lond", ""]
        ],
    },
}

# [render] frame 41 partial (DraftSend) | written 1 | built 1 | diffed 12 nodes, 1 op | events text | 0.4 ms (build 312 µs, render 101 µs)
FRAME = re.compile(
    r"\[render\] frame \d+ (?P<kind>\w+).*?"
    r"(?:\| written (?P<written>\d+) \| built (?P<built>\d+) )?"
    r"\| diffed (?P<diffed>\d+) nodes.*"
    r"\(build (?P<build>\d+) µs, render (?P<render>\d+) µs\)"
)


def run(binary, workload, cycles):
    """One launch: a warm-up cycle, then `cycles` measured. The frames of the
    measured commands, as dicts."""
    spec = WORKLOADS[workload]
    env = dict(os.environ, ISO_RENDER_LOG="1", **spec.get("env", {}))
    if "story" in spec:
        env["ISO_STORYBOOK_STORY"] = spec["story"]
    # Standard error into the same pipe: each answer follows its frames' lines.
    proc = subprocess.Popen(
        [binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        env=env, text=True, bufsize=1,
    )

    def command(cmd):
        proc.stdin.write(json.dumps(cmd) + "\n")
        proc.stdin.flush()
        frames = []
        for line in proc.stdout:
            if line.startswith("{"):
                answer = json.loads(line)
                if not answer.get("ok"):
                    raise SystemExit(f"{workload}: {cmd} failed: {answer.get('error')}")
                return frames
            m = FRAME.search(line)
            if m:
                frames.append({
                    "kind": m["kind"],
                    "written": int(m["written"] or 0),
                    "built": int(m["built"] or 0),
                    "build": int(m["build"]),
                    "render": int(m["render"]),
                })
        raise SystemExit(f"{workload}: the app ended (exit {proc.wait()})")

    try:
        command({"cmd": "ls"})
        for cmd in spec["cycle"]:
            command(cmd)
        measured = []
        for _ in range(cycles):
            for cmd in spec["cycle"]:
                measured += command(cmd)
        proc.stdin.write(json.dumps({"cmd": "quit"}) + "\n")
        proc.stdin.flush()
    finally:
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
    return measured


def pct(values, q):
    if not values:
        return float("nan")
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("binaries", nargs="+", help="name=path of a headless Storybook binary")
    parser.add_argument("--workloads", default=",".join(WORKLOADS))
    parser.add_argument("--rounds", type=int, default=6)
    parser.add_argument("--cycles", type=int, default=12, help="measured cycles a launch")
    parser.add_argument("--all-frames", action="store_true",
                        help="every frame, not only those that wrote state")
    args = parser.parse_args()

    binaries = [b.split("=", 1) if "=" in b else (os.path.basename(b), b) for b in args.binaries]
    workloads = [w for w in args.workloads.split(",") if w]
    for w in workloads:
        if w not in WORKLOADS:
            raise SystemExit(f"unknown workload {w}: {', '.join(WORKLOADS)}")

    # results[workload][name] = list of per-round frame lists
    results = {w: {name: [] for name, _ in binaries} for w in workloads}
    for r in range(args.rounds):
        order = binaries[r % len(binaries):] + binaries[:r % len(binaries)]
        for w in workloads:
            for name, path in order:
                frames = run(path, w, args.cycles)
                if not args.all_frames:
                    frames = [f for f in frames if f["written"] > 0] or frames
                results[w][name].append(frames)
        print(f"round {r + 1}/{args.rounds}", file=sys.stderr)

    base = binaries[0][0]
    print("| workload | build | frames | built p50 | build µs p50 / p90 | render µs p50 / p90 | total µs p50 / p90 | paired total |")
    print("|---|---|---|---|---|---|---|---|")
    for w in workloads:
        for name, _ in binaries:
            rounds = results[w][name]
            frames = [f for rnd in rounds for f in rnd]
            build = [f["build"] for f in frames]
            render = [f["render"] for f in frames]
            total = [f["build"] + f["render"] for f in frames]
            built = [f["built"] for f in frames]
            ratios = []
            for mine, theirs in zip(rounds, results[w][base]):
                a = [f["build"] + f["render"] for f in mine]
                b = [f["build"] + f["render"] for f in theirs]
                if a and b and statistics.median(b) > 0:
                    ratios.append(statistics.median(a) / statistics.median(b))
            paired = f"{statistics.median(ratios):.2f}" if ratios else "-"
            print(
                f"| {w} | {name} | {len(frames)} | {pct(built, 0.5)} "
                f"| {pct(build, 0.5)} / {pct(build, 0.9)} | {pct(render, 0.5)} / {pct(render, 0.9)} "
                f"| {pct(total, 0.5)} / {pct(total, 0.9)} | {paired} |"
            )


if __name__ == "__main__":
    main()
