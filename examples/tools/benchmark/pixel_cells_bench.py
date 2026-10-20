#!/usr/bin/env python3
# Pixel 3a bench driver for the docs/benchmarks.md#android ISO cells:
#   startup = process fork stamp (/proc/pid/stat f22) -> [content-frame] log
#   taps    = framestats HANDLE_INPUT_START -> SYNC_QUEUED on input frames
#             (Android 12 column order), plus the cells log [native-tap]
#             content-anchored values to logcat (grep them after a run).
# Usage: tools/benchmark/pixel_cells_bench.py <path-to-adb>
# NOTE: framestats CANNOT see posted-performClick work (see the doc's
# methodology caveat) - prefer the [native-tap] logs for slow-update cells.
import os, subprocess, sys, time, statistics

ADB = sys.argv[1]
# The phone to measure: its adb serial (`adb devices`), from the environment.
SERIAL = os.environ.get("ANDROID_SERIAL", "")
if not SERIAL:
    sys.exit("set ANDROID_SERIAL to the phone's adb serial")
LONG_MAX = 9223372036854775807

def adb(*a, **kw):
    return subprocess.run([ADB, "-s", SERIAL, *a], capture_output=True, text=True, **kw).stdout

def shell(cmd):
    return adb("shell", cmd)

def startup_cycle(pkg, act):
    shell(f"am force-stop {pkg}"); time.sleep(2)
    adb("logcat", "-c")
    shell(f"am start -n {pkg}/{act}")
    cf_epoch = None
    for _ in range(120):
        time.sleep(0.5)
        out = adb("logcat", "-d", "-v", "epoch", "-s", "Isomer:I")
        for line in out.splitlines():
            if "[content-frame]" in line:
                cf_epoch = float(line.strip().split()[0])
                break
        if cf_epoch: break
    if not cf_epoch: return None
    pid = shell(f"pidof {pkg}").strip()
    if not pid: return None
    stat = shell(f"cat /proc/{pid}/stat").split()
    ticks = int(stat[21])
    wall_up = shell('echo $(date +%s.%N) $(cat /proc/uptime)').split()
    boot_wall = float(wall_up[0]) - float(wall_up[1])
    start_wall = boot_wall + ticks / 100.0
    return (cf_epoch - start_wall) * 1000.0

def tap_cycle(pkg, act, x, y, presses=15):
    shell(f"am force-stop {pkg}"); time.sleep(2)
    shell(f"am start -n {pkg}/{act}"); time.sleep(6)
    shell(f"dumpsys gfxinfo {pkg} reset"); time.sleep(1)
    for _ in range(presses):
        shell(f"input swipe {x} {y} {x} {y} 80")
        time.sleep(0.9)
    time.sleep(1)
    out = shell(f"dumpsys gfxinfo {pkg} framestats")
    rows = []
    in_data = False
    for line in out.splitlines():
        if line.startswith("---PROFILEDATA---"):
            in_data = not in_data; continue
        if in_data and line and line[0].isdigit():
            # Android 12 columns: 0 Flags, 1 FrameTimelineVsyncId,
            # 2 IntendedVsync, 3 Vsync, 4 InputEventId, 5 HandleInputStart,
            # ..., 12 SyncQueued.
            cols = line.split(",")
            try:
                flags = int(cols[0]); input_id = int(cols[4])
                his = int(cols[5]); sq = int(cols[12])
                ivs = int(cols[2])
            except (ValueError, IndexError):
                continue
            if flags == 0 and input_id != 0:
                rows.append((ivs, (sq - his) / 1e6))
    rows.sort()
    # Presses are ~1s apart; a press window may hold 2 input frames
    # (down-state + up/update). Group by gaps > 300ms; keep the LAST frame
    # of each group (the ACTION_UP/update frame) AND report all-frames too.
    groups, cur = [], []
    for i, (ivs, d) in enumerate(rows):
        if cur and (ivs - cur[-1][0]) > 300e6:
            groups.append(cur); cur = []
        cur.append((ivs, d))
    if cur: groups.append(cur)
    last_of_group = [g[-1][1] for g in groups]
    all_frames = [d for _, d in rows]
    return all_frames, last_of_group

def run(tag, pkg, act, x, y):
    print(f"== {tag}")
    startups = []
    for c in range(4):
        s = startup_cycle(pkg, act)
        print(f"  startup cycle {c}: {s if s is None else round(s)} ms")
        if s is not None: startups.append(s)
    allf, lastf = tap_cycle(pkg, act, x, y)
    med = lambda v: statistics.median(v) if v else -1
    mean = lambda v: statistics.fmean(v) if v else -1
    print(f"  startup med(drop first): {round(med(startups[1:]))} ms  (all: {[round(s) for s in startups]})")
    print(f"  taps ALL n={len(allf)} med={med(allf):.2f} mean={mean(allf):.2f}")
    print(f"  taps LAST-of-press n={len(lastf)} med={med(lastf):.2f} mean={mean(lastf):.2f}")
    shell(f"am force-stop {pkg}")

run("wasm+Views", "dev.isomer.tapcounter.wasmviews", ".MainActivity", 539, 1147)
