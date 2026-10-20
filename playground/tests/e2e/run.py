#!/usr/bin/env python3
"""End-to-end tests of the Playground apps: what a reader does, on an emulator
and a simulator, against the builds that get installed.

  tests/e2e/run.py [android] [ios]        (both when none is named)

They exist because of two releases' worth of "Run on the web" opening a blank
page on the phones: once the site's file list lacked a module the renderer
had started importing, and once the installed APK was a stale build that
lacked it though the source was right. Neither shows in a compile; both show
the moment the page is loaded. So:

android  Builds the APK the way it is installed (-c opt), installs it on the
         hermetic emulator (emulator-5554 only: another session's is its
         own), or on the test phone ANDROID_SERIAL names (the root-only
         template check is skipped there), opens the 2048 project and
         - taps "Run on the web": the app compiles the project ON the
           emulator and serves the page; the page is loaded from the host in
           headless Chrome (adb forward) and must show the board with no
           failed request, uncaught exception or console error;
         - taps "Run": the build must start in its own window (WasmView's
           "[wasm-init] done" line, WAMR's interpreter; no fatal signal) and
           show the board;
         then runs every other template on the web the same way (each must
         compile on the emulator, the @Observable ones with the staged macro
         plugins, and its page show its title: "out of the box"); then
         puts a 2048 an earlier build shipped and an edited Counter in the
         app's files and relaunches: the first must take this build's
         template, the second keep its source (TemplateHistory).
ios      Builds the simulator app (the embedded compiler when it is staged),
         installs it on this harness's own simulator (`playground-e2e`),
         and taps "Run on the web" in the app: the app compiles its first
         project in-process, and the page opens in the app's Safari view
         (WebKit, as on the phone) and must show the project; then the
         template check, on projects from before the store kept hashes; then
         compiles every project with the app's compiler (ISO_PLAYGROUND_AUTORUN
         =all; the host toolchain, as the simulator has no embedded one).
         Driven by Isomer's XCUITest driver (ISOMER, default the parent
         checkout: examples/tests/safari_probe).

Neither touches a phone unless ANDROID_SERIAL names one. Exit status 1 when
anything failed.
"""
import json, os, re, subprocess, sys, time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
# The isomer checkout this module lives in (playground/ is its subdirectory).
ISOMER = os.environ.get("ISOMER", os.path.dirname(ROOT))
ANDROID_PACKAGE = "dev.isomer.playground"
IOS_BUNDLE = "com.LoganShire.Playground"
SIMULATOR_NAME, SIMULATOR_TYPE = "playground-e2e", "iPhone 17 Pro"
BOARD = "Swipe the board to merge tiles."
# The web/Android templates (WebTemplate.all) and what each one's page shows
# first; the iOS app seeds the same but "This website".
TEMPLATES = {"Counter": "Tapped 0 times", "2048": BOARD, "Hacker News": "Hacker News", "Wikipedia": "Wikipedia",
             "Meme Creator": "Meme Creator", "Pokédex": "Pokédex", "This website": "What it is"}

failures = []

def log(message): print(f"[e2e] {message}", flush=True)

def check(ok, what, detail=""):
    log(("ok    " if ok else "FAIL  ") + what + (f": {detail}" if detail and not ok else ""))
    if not ok: failures.append(what)
    return ok

def sh(command, check_status=True, **kwargs):
    result = subprocess.run(command, shell=isinstance(command, str), cwd=kwargs.pop("cwd", ROOT),
                            capture_output=True, text=True, **kwargs)
    if check_status and result.returncode != 0:
        raise SystemExit(f"{command}\n{result.stdout}{result.stderr}")
    return result

def bazel_output(target, *flags, suffix=""):
    sh(["bazel", "build", target, *flags])
    files = sh(["bazel", "cquery", "--output=files", target, *flags]).stdout.split()
    return os.path.join(ROOT, next(f for f in files if f.endswith(suffix)))

def page_check(url, text, seconds=60):
    result = subprocess.run(["node", os.path.join(ROOT, "tests/e2e/page_check.js"), url, text, str(seconds)],
                            capture_output=True, text=True)
    try: seen = json.loads(result.stdout)
    except ValueError: seen = {"ok": False, "problems": [result.stdout + result.stderr]}
    return seen

# --- Android

def android():
    adb = sh("find -L \"$(bazel info output_base)/external\" -maxdepth 4 -path '*androidsdk*platform-tools*' -name adb -type f | head -1").stdout.strip()
    apk = bazel_output("//android/playground_android_application:playground_android_application_apk", "-c", "opt", suffix="_apk.apk")
    # A test phone when ANDROID_SERIAL names one (with ADB_SERVER_SOCKET when
    # its adb server is not this Mac's), else this Mac's emulator.
    serial = os.environ.get("ANDROID_SERIAL", "emulator-5554")
    a = [adb, "-s", serial]
    started = None
    if serial.startswith("emulator-") and f"{serial}\tdevice" not in sh([adb, "devices"]).stdout:
        log("booting the hermetic emulator")
        started = subprocess.Popen(["bazel", "run", "@isomer//tools/android/emulator", "--", "-no-window", "-no-audio", "-port", "5554"],
                                   cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(200):
            time.sleep(3)
            if sh(a + ["shell", "getprop", "sys.boot_completed"], check_status=False).stdout.strip() == "1": break
    def launch():
        """The app's launcher activity, as a tap on its icon starts it. Not
        `monkey -p … 1`: its one random event can be a keyboard-lid flip,
        which on a test phone (a Pixel 3a) turned the screen to landscape
        whatever the rotation lock said."""
        component = sh(a + ["shell", "cmd", "package", "resolve-activity", "--brief",
                            "-c", "android.intent.category.LAUNCHER", ANDROID_PACKAGE]).stdout.split()[-1]
        sh(a + ["shell", "am", "start", "-n", component])

    phone = not serial.startswith("emulator-")
    if phone:
        # A test phone (no passcode): woken and unlocked, in case its screen
        # went off.
        sh(a + ["shell", "input", "keyevent", "KEYCODE_WAKEUP"], check_status=False)
        sh(a + ["shell", "wm", "dismiss-keyguard"], check_status=False)
        # Portrait, the reader's way, however the phone lies on the desk (the
        # sensor off): taps land where the emulator's do.
        sh(a + ["shell", "wm", "user-rotation", "lock", "0"], check_status=False)
        sh(a + ["shell", "settings", "put", "system", "accelerometer_rotation", "0"], check_status=False)
        sh(a + ["shell", "settings", "put", "system", "user_rotation", "0"], check_status=False)
    try:
        sh(a + ["install", "-r", apk])
        # A reader's first launch: projects made from the templates this build
        # carries (an earlier run's projects keep the sources of its day).
        sh(a + ["shell", "pm", "clear", ANDROID_PACKAGE])
        sh(a + ["shell", "am", "force-stop", ANDROID_PACKAGE])
        sh(a + ["logcat", "-c"])
        launch()

        def bounds(attribute, value, tries=20):
            """The centre of the node whose text / content-desc is `value`."""
            for _ in range(tries):
                sh(a + ["shell", "uiautomator", "dump", "/sdcard/playground-e2e.xml"], check_status=False)
                dump = sh(a + ["shell", "cat", "/sdcard/playground-e2e.xml"], check_status=False).stdout
                found = re.search(rf'{attribute}="{re.escape(value)}"[^>]*bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"', dump)
                if found:
                    x1, y1, x2, y2 = map(int, found.groups())
                    return (x1 + x2) // 2, (y1 + y2) // 2
                time.sleep(1)
            return None

        def tap(attribute, value):
            at = bounds(attribute, value)
            if at: sh(a + ["shell", "input", "tap", str(at[0]), str(at[1])])
            return at is not None

        def evidence(label):
            """What the device showed when a check failed: its screen and the
            log lines of the app, its engine and the runtime."""
            shot = f"/tmp/playground-e2e-{label}.png"
            with open(shot, "wb") as f:
                subprocess.run(a + ["exec-out", "screencap", "-p"], stdout=f, check=False)
            lines = [l for l in sh(a + ["logcat", "-d"], check_status=False).stdout.splitlines()
                     if re.search(r"wasm|Fatal|AndroidRuntime|playground|Isomer|ANR|lowmemorykiller", l, re.I)]
            log(f"      evidence: {shot}")
            for line in lines[-25:]:
                log(f"      | {line[:220]}")

        def logcat(pattern, seconds):
            for _ in range(seconds):
                found = re.search(pattern, sh(a + ["logcat", "-d"], check_status=False).stdout)
                if found: return found
                time.sleep(1)
            return None

        if not check(tap("text", "2048"), "android: the 2048 project is listed"): return

        # Run on the web: compiled on the emulator, served by the app, loaded here.
        if check(tap("content-desc", "Run on the web"), "android: Run on the web is offered"):
            published = logcat(r"\[web-run\] http://127\.0\.0\.1:(\d+)/index\.html", 180)
            if check(published is not None, "android: the app compiled the project and published its page"):
                sh(a + ["forward", "tcp:8794", f"tcp:{published.group(1)}"])
                seen = page_check("http://127.0.0.1:8794/index.html", BOARD)
                check(seen.get("ok"), "android: the web run's page shows the board, nothing failed on the way", json.dumps(seen))
                sh(a + ["forward", "--remove", "tcp:8794"], check_status=False)
        # Back from the browser to the project.
        sh(a + ["shell", "am", "start", "-n", f"{ANDROID_PACKAGE}/.MainActivity"], check_status=False)
        time.sleep(2)

        # Run: the build in its own window, on the wasm engine.
        sh(a + ["logcat", "-c"])
        if check(tap("content-desc", "Run"), "android: Run is offered"):
            done = logcat(r"\[wasm-init\] done in (\d+)ms", 240)
            if done is None:
                evidence("run-not-started")
            if check(done is not None, "android: the run started"):
                log(f"      start-up {done.group(1)} ms")
                check(bounds("text", BOARD) is not None, "android: the run shows the board")
                sh(a + ["shell", "input", "swipe", "300", "900", "800", "900", "200"])
                time.sleep(1)
                fatal = re.search(r"Fatal signal.*", sh(a + ["logcat", "-d"], check_status=False).stdout)
                check(fatal is None and bounds("text", BOARD, tries=3) is not None,
                      "android: a swipe leaves the run alive", fatal.group(0) if fatal else "the board is gone")

        # Every other template, out of the box: compiled on the emulator (the
        # @Observable ones only with the staged macro plugins) and its page shown.
        for name, text in TEMPLATES.items():
            if name == "2048": continue
            sh(a + ["shell", "am", "force-stop", ANDROID_PACKAGE])
            sh(a + ["logcat", "-c"])
            launch()
            listed = tap("text", name)
            if not listed:
                evidence(f"not-listed-{name}")
            if not (check(listed, f"android: the {name} project is listed") and
                    check(tap("content-desc", "Run on the web"), f"android: Run on the web is offered for {name}")):
                continue
            published = logcat(r"\[web-run\] http://127\.0\.0\.1:(\d+)/index\.html", 240)
            if check(published is not None, f"android: the app compiled {name}",
                     (logcat(r"error: .*", 1) or [""])[0]):
                sh(a + ["forward", "tcp:8794", f"tcp:{published.group(1)}"])
                seen = page_check("http://127.0.0.1:8794/index.html", text)
                check(seen.get("ok"), f"android: {name}'s page shows, nothing failed on the way", json.dumps(seen))
                sh(a + ["forward", "--remove", "tcp:8794"], check_status=False)

        # Templates out of the box: a project still holding a template an
        # earlier build shipped takes this build's at launch; an edited one
        # keeps its source. Written as root into the app's own files (the
        # emulator's image allows `adb root`; a phone's does not: skipped).
        if not serial.startswith("emulator-"):
            log("      the template check writes as root: emulator only, skipped on " + serial)
            return
        sys.path.insert(0, os.path.join(ROOT, "tools", "playground"))
        import template_history
        shipped = template_history.history(ISOMER)
        sh(a + ["shell", "am", "force-stop", ANDROID_PACKAGE])
        sh(a + ["root"]); sh(a + ["wait-for-device"])
        home = f"/data/data/{ANDROID_PACKAGE}/files/Library/Application Support/playground"
        read = lambda path: sh(a + ["exec-out", f"cat '{home}/{path}'"], check_status=False).stdout
        def write(path, text):
            with open("/tmp/playground-e2e-source.swift", "w") as file: file.write(text)
            sh(a + ["push", "/tmp/playground-e2e-source.swift", "/data/local/tmp/playground-e2e-source.swift"])
            sh(a + ["shell", f"cat /data/local/tmp/playground-e2e-source.swift > '{home}/{path}'"])
        ids = {p["name"]: p["id"] for p in json.loads(read("projects.json") or "{}").get("projects", [])}
        if check("2048" in ids and "Counter" in ids, "android: the 2048 and Counter projects are on disk", str(ids)):
            fresh = read(f"{ids['2048']}/App.swift")
            older = [source.decode() for name, source in shipped.values()
                     if name == "Game2048.swift" and source.decode() != fresh]
            counter = [source.decode() for name, source in shipped.values() if name == "Counter.swift"]
            edited = counter[-1] + "\n// The reader's own line.\n"
            write(f"{ids['2048']}/App.swift", older[-1])
            write(f"{ids['Counter']}/App.swift", edited)
            check(read(f"{ids['2048']}/App.swift") == older[-1], "android: an older 2048 is written over this build's")
            launch()
            check(bounds("text", "2048") is not None, "android: the Playground launches over the older projects")
            check(read(f"{ids['2048']}/App.swift") == fresh,
                  f"android: an untouched 2048 from an earlier build ({len(older)} older versions) takes this build's template")
            check(read(f"{ids['Counter']}/App.swift") == edited, "android: an edited Counter keeps its source")
        sh(a + ["unroot"], check_status=False); sh(a + ["wait-for-device"], check_status=False)
    finally:
        sh(a + ["shell", "am", "force-stop", ANDROID_PACKAGE], check_status=False)
        if started: sh(a + ["emu", "kill"], check_status=False)

# --- iOS (the simulator)

def simulator():
    listing = json.loads(sh("xcrun simctl list -j").stdout)
    devices = [d for runtime in listing["devices"].values() for d in runtime if d.get("isAvailable")]
    device = next((d for d in devices if d["name"] == SIMULATOR_NAME), None)
    if device is None:
        kind = next(t["identifier"] for t in listing["devicetypes"] if t["name"] == SIMULATOR_TYPE)
        runtime = [r for r in listing["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]][-1]["identifier"]
        log(f"creating the simulator {SIMULATOR_NAME}")
        return sh(["xcrun", "simctl", "create", SIMULATOR_NAME, kind, runtime]).stdout.strip(), False
    return device["udid"], device["state"] == "Booted"

def ios():
    probe = os.path.join(ISOMER, "examples")
    if not os.path.isdir(os.path.join(probe, "tests/safari_probe")):
        check(False, f"ios: Isomer's XCUITest driver ({probe}/tests/safari_probe; set ISOMER)")
        return
    flags = ["--ios_multi_cpus=sim_arm64", "-c", "opt"]
    if os.path.isdir(os.path.join(ROOT, "apple/playground_ios_application/embedded_toolchain/iphonesimulator/lib")):
        flags.append("--define=iso_playground_embedded=1")
    ipa = bazel_output("//apple/playground_ios_application", *flags, suffix=".ipa")
    udid, was_booted = simulator()
    if not was_booted: sh(["xcrun", "simctl", "boot", udid])
    sh(["xcrun", "simctl", "bootstatus", udid, "-b"])
    folder = "/private/tmp/safari_probe"
    driver = None
    try:
        sh(f"rm -rf /tmp/playground-e2e-app && mkdir /tmp/playground-e2e-app && unzip -oq '{ipa}' -d /tmp/playground-e2e-app")
        app = sh("find /tmp/playground-e2e-app/Payload -maxdepth 1 -name '*.app' | head -1").stdout.strip()
        sh(["xcrun", "simctl", "uninstall", udid, IOS_BUNDLE], check_status=False)
        sh(["xcrun", "simctl", "install", udid, app])
        # Past the sign-in screen (the key is never used: nothing here asks
        # the agent anything), with the host's toolchain for a build without
        # the embedded compiler.
        output_base = sh("bazel info output_base").stdout.strip()
        toolchain = f"{output_base}/external/rules_swift++swift+swift_toolchain_xcode/usr/bin"
        slice_dir = sh(f"find '{output_base}/external/rules_swift++swift+swift_toolchain_wasm_sdk_xcode' -maxdepth 3 -name wasm32-unknown-wasip1 -type d | head -1").stdout.strip()
        environment = dict(os.environ,
                           SIMCTL_CHILD_ISO_PLAYGROUND_OPENROUTER_KEY="sk-or-e2e-not-a-key",
                           SIMCTL_CHILD_ISO_PLAYGROUND_TOOLCHAIN_BIN=toolchain,
                           SIMCTL_CHILD_ISO_PLAYGROUND_WASI_SDK=f"{slice_dir}/WASI.sdk",
                           SIMCTL_CHILD_ISO_PLAYGROUND_SWIFT_STATIC=f"{slice_dir}/swift.xctoolchain/usr/lib/swift_static")
        sh(["xcrun", "simctl", "launch", udid, IOS_BUNDLE], env=environment)

        sh(f"mkdir -p {folder} && rm -f {folder}/cmd.txt {folder}/out.txt")
        driver = subprocess.Popen(
            ["bazel", "test", "//tests/safari_probe:safari_driver", "--nocache_test_results", "--ios_multi_cpus=sim_arm64",
             f"--test_arg=--destination=platform=ios_simulator,id={udid}", "--spawn_strategy=local", "--test_timeout=3600"],
            cwd=probe, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        def drive(*commands, seconds=180):
            if os.path.exists(f"{folder}/out.txt"): os.remove(f"{folder}/out.txt")
            open(f"{folder}/cmd.txt", "w").write("\n".join(commands) + "\n")
            for _ in range(seconds):
                if os.path.exists(f"{folder}/out.txt"): return open(f"{folder}/out.txt").read()
                time.sleep(1)
            return ""

        for _ in range(600):
            if os.path.exists(f"{folder}/out.txt"): break
            time.sleep(1)
        if not check(os.path.exists(f"{folder}/out.txt"), "ios: the XCUITest driver started"): return
        # A fresh install opens on its first project (the Pokédex sample).
        said = drive(f"bundle {IOS_BUNDLE}", "sleep 2", "tapany Run on the web", "sleep 40", "tree")
        check("tapped Run on the web" in said, "ios: Run on the web is offered", said[:200])
        # The page's own text, inside the app's Safari view (`tree` is the
        # web view's elements): the project's title, there with no network.
        check(re.search(r"StaticText[^\n]*label: 'Pokédex'", said) is not None,
              "ios: the web run's page shows the project in the app's Safari view", said[-400:])

        # Templates out of the box, as on Android, for projects from before the
        # store kept their template's hash: one still holding a template an
        # earlier build shipped takes this build's at launch; an edited one
        # keeps its source.
        sys.path.insert(0, os.path.join(ROOT, "tools", "playground"))
        import template_history
        shipped = template_history.history(ISOMER)
        sh(["xcrun", "simctl", "terminate", udid, IOS_BUNDLE], check_status=False)
        projects = os.path.join(sh(["xcrun", "simctl", "get_app_container", udid, IOS_BUNDLE, "data"]).stdout.strip(),
                                "Documents", "Projects")
        metas = {}
        for project in os.listdir(projects):
            path = os.path.join(projects, project, "project.json")
            if os.path.exists(path):
                meta = json.load(open(path))
                metas[meta["name"]] = (project, meta, path)
        if check("2048" in metas and "Counter" in metas, "ios: the 2048 and Counter projects are on disk", str(list(metas))):
            source = lambda name: os.path.join(projects, metas[name][0], "files", "App.swift")
            fresh = open(source("2048")).read()
            older = [text.decode() for name, text in shipped.values() if name == "Game2048.swift" and text.decode() != fresh]
            edited = [text.decode() for name, text in shipped.values() if name == "Counter.swift"][-1] + "\n// The reader's own line.\n"
            for name, text in (("2048", older[-1]), ("Counter", edited)):
                open(source(name), "w").write(text)
                _, meta, path = metas[name]
                meta.pop("sampleHash", None)
                json.dump(meta, open(path, "w"))
            sh(["xcrun", "simctl", "launch", udid, IOS_BUNDLE], env=environment)
            time.sleep(8)
            check(open(source("2048")).read() == fresh,
                  f"ios: an untouched 2048 from an earlier build ({len(older)} older versions) takes this build's template")
            check(open(source("Counter")).read() == edited, "ios: an edited Counter keeps its source")

        # Every project with the app's compiler, out of the box (the edited
        # Counter included: a comment line). Its log, read from the simulator.
        sh(["xcrun", "simctl", "terminate", udid, IOS_BUNDLE], check_status=False)
        started_at = time.strftime("%Y-%m-%d %H:%M:%S")
        sh(["xcrun", "simctl", "launch", udid, IOS_BUNDLE], env=dict(environment, SIMCTL_CHILD_ISO_PLAYGROUND_AUTORUN="all"))
        lines = ""
        for _ in range(120):
            time.sleep(3)
            lines = sh(["xcrun", "simctl", "spawn", udid, "log", "show", "--start", started_at, "--style", "compact",
                        "--predicate", 'eventMessage CONTAINS "[playground] compile"'], check_status=False).stdout
            if "[playground] compiled all" in lines: break
        compiled = re.findall(r"\[playground\] compiled (.+?): \d+ bytes", lines)
        failed = re.findall(r"\[playground\] compile failed (.+?): (.*)", lines)
        check("[playground] compiled all" in lines and not failed and len(compiled) >= 6,
              f"ios: every project compiles with the app's compiler ({', '.join(compiled)})", str(failed)[:600])
    finally:
        if driver:
            open(f"{folder}/cmd.txt", "w").write("quit\n")
            try: driver.wait(timeout=60)
            except subprocess.TimeoutExpired: driver.kill()
        sh(["xcrun", "simctl", "terminate", udid, IOS_BUNDLE], check_status=False)
        if not was_booted: sh(["xcrun", "simctl", "shutdown", udid], check_status=False)

if __name__ == "__main__":
    targets = sys.argv[1:] or ["android", "ios"]
    for target in targets:
        {"android": android, "ios": ios}[target]()
    log("FAILED: " + "; ".join(failures) if failures else "all passed")
    sys.exit(1 if failures else 0)
