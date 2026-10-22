#!/usr/bin/env python3
"""The Isomer app's proof across platforms: every Gallery entry, on every
platform, with each of its renderers, compiled into the app and as wasm (the
Gallery's reactor on the platform's engine, WasmKit or the browser's), and
the app's main menu. Machines come from oss (an iOS simulator, an Android
emulator, macOS, Linux and Windows VMs); the web runs in this Mac's
headless Chrome.

  tests/proof/proof.py [ios] [macos] [android] [web] [linux] [windows] --review <dir> [--commit <sha>] [--entries pokedex,todo]

Each platform and renderer is a folder of the review store's snapshots
(<dir>/<platform>-<cell>/manifest.json, reviews/MANIFEST.md): its screens,
named for the Gallery's entries. Screens are opened with the app's launch
hooks: ISO_OPEN_APP=<entry> (the Gallery's entry), ISO_RUN_GALLERY_WASM=1
(the entry as wasm), passed as each platform passes a process environment
(simctl's SIMCTL_CHILD_, `open --env`, an Android intent's ISO_ extras, the
web page's ISO_ query parameters, the desktops' environment).

The builds are this checkout's, made here (-c opt), except Linux's (built in
an oss container: isomer's tools/linux/build.sh) and Windows' (built on the
Windows VM; its reactor is the one built here). Leases are released however
the run ends.
"""
import argparse, json, os, re, shlex, shutil, subprocess, sys, tempfile, time, urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ISOMER = os.path.dirname(ROOT)
BUNDLE = "com.LoganShire.Isomer"
# The Gallery's entries (GalleryEntry.slug), in the sidebar's order.
ENTRIES = [("pokedex", "Pokédex"), ("wikipedia", "Wikipedia"), ("hackernews", "Hacker News"), ("todo", "To-Do"),
           ("meme", "Meme Creator"), ("dateplanner", "Date Planner"), ("map", "Map Explorer"), ("game2048", "2048"),
           ("counter", "Counter"), ("floatingmenu", "Floating Menu"), ("controls", "Controls"),
           ("layout", "Layout & Motion"), ("media", "Media"), ("system", "System")]

leases = []
failures = []

def log(message): print(f"[proof] {message}", flush=True)

def sh(command, check=True, cwd=ROOT, **kwargs):
    result = subprocess.run(command, shell=isinstance(command, str), cwd=cwd, capture_output=True, text=True, **kwargs)
    if check and result.returncode != 0:
        raise SystemExit(f"{command}\n{result.stdout}{result.stderr}")
    return result

def bazel_output(target, *flags, suffix="", cwd=ROOT):
    sh(["bazel", "build", target, *flags], cwd=cwd)
    files = sh(["bazel", "cquery", "--output=files", target, *flags], cwd=cwd).stdout.split()
    return os.path.join(cwd, next(f for f in files if f.endswith(suffix)))

# Leases the caller holds, by platform: their `oss machine lease --exports`
# output (--held), used as they are and not released (a Windows VM that has
# built once builds again in minutes).
held = {}

def lease(platform, *flags):
    """An oss lease: its exports (OSS_ID, OSS_SSH_PORT, OSS_UDID…), released at exit."""
    if platform in held:
        env = dict(re.findall(r"(OSS_[A-Z_]+)='([^']*)'", open(held[platform]).read()))
        log(f"using held {platform} {env['OSS_ID']}")
        return env
    out = sh(["oss", "machine", "lease", platform, "--exports", "--minutes=120", *flags]).stdout
    env = dict(re.findall(r"(OSS_[A-Z_]+)='([^']*)'", out))
    leases.append(env["OSS_ID"])
    log(f"leased {platform} {env['OSS_ID']}")
    return env

def ssh(env, command, check=True):
    return sh(["oss", "machine", "ssh", env["OSS_ID"], "--", command], check=check)

def scp(env, source, destination):
    sh(["scp", "-q", "-P", env["OSS_SSH_PORT"], "-o", f"UserKnownHostsFile={os.path.expanduser('~/.local/state/oss/known_hosts-' + env['OSS_ID'])}",
        "-o", "StrictHostKeyChecking=accept-new", source, f"{env.get('OSS_SSH_USER', 'runner')}@127.0.0.1:{destination}"])

def oss_shot(env, path):
    sh(["oss", "machine", "screenshot", env["OSS_ID"], path])


class Review:
    """The run's snapshot folders, in the review store's manifest format."""
    def __init__(self, folder, commit, version):
        self.folder, self.commit, self.version = folder, commit, version

    def cell(self, name, device, orientation, shots):
        """`shots`: (item name, capture file) pairs already in the cell's folder."""
        out = os.path.join(self.folder, name)
        items = [{"name": item, "status": "new", "capture": capture} for item, capture in shots
                 if os.path.exists(os.path.join(out, capture))]
        missing = [item for item, capture in shots if not os.path.exists(os.path.join(out, capture))]
        for item in missing: failures.append(f"{name}: {item}")
        json.dump({"schema": 1, "app": "Isomer", "version": self.version, "release": self.version, "commit": self.commit,
                   "kind": "snapshots", "target": name, "device": device, "orientation": orientation,
                   "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "items": items},
                  open(os.path.join(out, "manifest.json"), "w"), indent=1)
        log(f"{name}: {len(items)} screens" + (f", MISSING {missing}" if missing else ""))

    def dir(self, name):
        path = os.path.join(self.folder, name)
        os.makedirs(path, exist_ok=True)
        return path


class Feed:
    """A hot reloader's feed for the run: two versions of the Gallery's
    reactor published with tools/playground/publish_hot_reload.sh, served
    over HTTP on this Mac while the run lasts, at each address a device
    reaches it by (127.0.0.1: Chrome and the simulator; the emulator's
    10.0.2.2 is this Mac's loopback; the VMs' NAT gateways, this Mac on
    their networks: 192.168.64.1 for Apple's virtualization, the macOS VMs
    and containers, 192.168.65.1 for UTM's others). A VM is told its own
    (`gateway`)."""
    VM_HOSTS = ("192.168.64.1", "192.168.65.1")

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="proof-feed-")
        reactor = bazel_output("//shared/gallery_reactor:gallery.wasm", "-c", "opt")
        publish = os.path.join(ROOT, "tools", "playground", "publish_hot_reload.sh")
        sh([publish, os.path.join(self.dir, "feed"), reactor, "0.38-a", "the Gallery, first version"])
        sh([publish, os.path.join(self.dir, "feed"), reactor, "0.38-b", "the Gallery, a newer version"])
        self.newest = json.load(open(os.path.join(self.dir, "feed", "versions.json")))
        self.newest = (self.newest["versions"] if isinstance(self.newest, dict) else self.newest)[0]["url"]
        self.port = 8900 + os.getpid() % 90
        # Any origin may read it (the web app's page fetches it from its own).
        server = ("import http.server, sys\n"
                  "class Handler(http.server.SimpleHTTPRequestHandler):\n"
                  "    def end_headers(self):\n"
                  "        self.send_header('Access-Control-Allow-Origin', '*')\n"
                  "        self.send_header('Cache-Control', 'no-store')\n"
                  "        super().end_headers()\n"
                  "http.server.ThreadingHTTPServer((sys.argv[1], int(sys.argv[2])), Handler).serve_forever()\n")
        self.servers = [subprocess.Popen([sys.executable, "-c", server, address, str(self.port)], cwd=self.dir,
                                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        for address in ("127.0.0.1",) + self.VM_HOSTS]
        time.sleep(1)

    def base(self, host="127.0.0.1"):
        return f"http://{host}:{self.port}/feed"

    def close(self):
        for server in self.servers: server.terminate()

feed = None

def gateway(env, platform):
    """This Mac's address on a VM's network: the VM's default gateway."""
    command = {
        "macos": "route -n get default | awk '/gateway:/ {print $2}'",
        "linux": "ip route show default | awk '{print $3; exit}'",
        "windows": "(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1).NextHop",
    }[platform]
    address = ssh(env, command).stdout.strip().splitlines()[-1].strip()
    log(f"{platform}: this Mac is {address} on its network")
    return address

def hot_cell(review, platform, device, orientation, launcher, host="127.0.0.1", run_wait=14):
    """The Hot Reloaders: a reloader following the feed (its page: the
    versions it lists), and its newest version running (the reactor from
    the feed's URL, as Run does)."""
    name = f"{platform}-hot-reloader"
    out = review.dir(name)
    base = feed.base(host)
    page = launcher({"ISO_ADD_RELOADER": f"Gallery feed|{base}/versions.json", "ISO_OPEN_RELOADER": "Gallery feed"}, 8)
    run = launcher({"ISO_RUN_REACTOR": f"{base}/{feed.newest}"}, run_wait)
    shots = []
    for title, capture, shoot, pause in (("A reloader's versions", "reloader.png", page, 8),
                                          ("Its newest version running", "run.png", run, run_wait)):
        try:
            shoot(None, os.path.join(out, capture), pause)
        except Exception as error:
            log(f"{name} {capture}: {error}")
        shots.append((title, capture))
    review.cell(name, device, orientation, shots)


def run_cells(review, platform, device, orientation, cells, entries, menu=None):
    """cells: (cell name, shoot(slug or None, path)) — None is the main menu."""
    for cell, shoot in cells:
        out = review.dir(f"{platform}-{cell}")
        shots = []
        if menu and cell == cells[0][0]:
            shoot(None, os.path.join(out, "menu.png"))
            shots.append(("Main menu", "menu.png"))
        for slug, title in entries:
            path = os.path.join(out, f"{slug}.png")
            try:
                shoot(slug, path)
            except Exception as error:  # a screen that failed is reported as missing
                log(f"{platform}-{cell} {slug}: {error}")
            shots.append((title, f"{slug}.png"))
        review.cell(f"{platform}-{cell}", device, orientation, shots)


# --- iOS (an oss simulator lease: simctl on the server, which is this Mac)

def ios(review, entries):
    ipa = bazel_output("//apple/playground_ios_application", "-c", "opt", "--ios_multi_cpus=sim_arm64", suffix=".ipa")
    work = tempfile.mkdtemp(prefix="proof-ios-")
    sh(["unzip", "-q", ipa, "-d", work])
    env = lease("ios")
    udid = env["OSS_UDID"]
    sh(["xcrun", "simctl", "install", udid, os.path.join(work, "Payload", "Isomer.app")])
    sh(["xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100"], check=False)

    def launcher(arguments, extra_env, wait):
        def shoot(slug, path, pause=None):
            sh(["xcrun", "simctl", "terminate", udid, BUNDLE], check=False)
            environment = dict(os.environ)
            for key, value in extra_env.items(): environment["SIMCTL_CHILD_" + key] = value
            if slug: environment["SIMCTL_CHILD_ISO_OPEN_APP"] = slug
            subprocess.run(["xcrun", "simctl", "launch", udid, BUNDLE, *arguments], env=environment, capture_output=True)
            time.sleep(pause or (wait if slug else 4))
            sh(["xcrun", "simctl", "io", udid, "screenshot", path])
        return shoot

    run_cells(review, "ios", "iPhone (simulator)", "portrait", [
        ("swiftui", launcher(["-playground.preferences.renderer", "native"], {}, 5)),
        ("wasm-swiftui", launcher(["-playground.preferences.renderer", "native"], {"ISO_RUN_GALLERY_WASM": "1"}, 12)),
        ("wasm-metal", launcher(["-playground.preferences.renderer", "gpu"], {"ISO_RUN_GALLERY_WASM": "1"}, 12)),
    ], entries, menu=True)
    hot_cell(review, "ios", "iPhone (simulator)", "portrait",
             lambda extra, wait: launcher(["-playground.preferences.renderer", "native"], extra, wait))
    sh(["xcrun", "simctl", "terminate", udid, BUNDLE], check=False)


# --- macOS (an oss VM: the app copied in, opened in its desktop session)

def macos(review, entries):
    archive = bazel_output("//apple/isomer_macos_application", "-c", "opt", suffix=".zip")
    env = lease("macos")
    scp(env, archive, "/tmp/isomer.zip")
    ssh(env, "cd /tmp && rm -rf Isomer.app && ditto -x -k isomer.zip .")

    def launcher(extra_env, wait):
        def shoot(slug, path, pause=None):
            ssh(env, "pkill -x Isomer; sleep 1", check=False)
            variables = dict(extra_env)
            if slug: variables["ISO_OPEN_APP"] = slug
            flags = " ".join(f"--env {k}={shlex.quote(v)}" for k, v in variables.items())
            ssh(env, f"sudo launchctl asuser $(id -u runner) open -n {flags} /tmp/Isomer.app")
            time.sleep(pause or (wait if slug else 6))
            oss_shot(env, path)
        return shoot

    run_cells(review, "macos", "Mac (macOS 27 VM)", "landscape", [
        ("swiftui", launcher({}, 6)),
        ("wasm-swiftui", launcher({"ISO_RUN_GALLERY_WASM": "1"}, 14)),
    ], entries, menu=True)
    hot_cell(review, "macos", "Mac (macOS 27 VM)", "landscape", launcher, host=gateway(env, "macos"))
    ssh(env, "pkill -x Isomer", check=False)


# --- Android (an oss emulator lease)

def android(review, entries):
    apk = bazel_output("//android/playground_android_application:playground_android_application_apk", "-c", "opt", suffix="_apk.apk")
    env = lease("android")
    # `--`: oss before 0.1.1 took the device command's options (am start's
    # --es) for its own.
    adb = ["oss", "machine", "adb", env["OSS_ID"], "--"]
    sh(adb + ["install", "-r", apk])
    sh(adb + ["shell", "pm", "clear", BUNDLE], check=False)

    def launcher(extras, wait):
        def shoot(slug, path, pause=None):
            sh(adb + ["shell", "am", "force-stop", BUNDLE], check=False)
            arguments = []
            for key, value in extras.items(): arguments += ["--es", key, value]
            if slug: arguments += ["--es", "ISO_OPEN_APP", slug]
            # adb shell joins its arguments into one line for the device's
            # sh: each quoted (a reloader's "name|url" has a pipe).
            sh(adb + ["shell", "am", "start", "-n", f"{BUNDLE}/.MainActivity", *map(shlex.quote, arguments)])
            time.sleep(pause or (wait if slug else 5))
            oss_shot(env, path)
        return shoot

    run_cells(review, "android", "Android phone (emulator)", "portrait", [
        ("compose", launcher({"renderer": "jetpackCompose"}, 6)),
        ("opengl", launcher({"renderer": "openGL"}, 6)),
        ("wasm-compose", launcher({"renderer": "jetpackCompose", "ISO_RUN_GALLERY_WASM": "1"}, 12)),
    ], entries, menu=True)
    hot_cell(review, "android", "Android phone (emulator)", "portrait",
             lambda extra, wait: launcher({"renderer": "jetpackCompose", **extra}, wait), host="10.0.2.2")
    sh(adb + ["shell", "am", "force-stop", BUNDLE], check=False)


# --- The web (this Mac's headless Chrome, the optimized site served locally)

def web(review, entries):
    site = bazel_output("//web/playground_web_application:playground_web_application_site", "-c", "opt")
    port = 8700 + os.getpid() % 200
    server = subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"], cwd=site,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cdp = os.path.join(ISOMER, "tools", "testing", "cdp.py")
    try:
        def page(query, wait, width=1280, height=800):
            def shoot(slug, path, pause=None, extra=""):
                url = f"http://127.0.0.1:{port}/?{query}" + (f"&ISO_OPEN_APP={slug}" if slug else "") + extra
                sh([sys.executable, cdp, url, path, f"wait={pause or wait}", f"width={width}", f"height={height}"])
            return shoot
        run_cells(review, "web", "Chrome (desktop width)", "landscape", [
            ("react", page("renderer=react", 10)),
            ("webgpu", page("renderer=webGPU", 12)),
            ("wasm-react", page("renderer=react&ISO_RUN_GALLERY_WASM=1", 16)),
        ], entries, menu=True)
        # The feed from another origin than the page's (its server allows it).
        hot_cell(review, "web", "Chrome (desktop width)", "landscape",
                 lambda extra, wait: (lambda slug, path, pause=None: page("renderer=react", wait)(
                     slug, path, pause, "".join(f"&{k}={urllib.parse.quote(v)}" for k, v in extra.items()))))
        run_cells(review, "web-phone", "Chrome (phone width)", "portrait", [
            ("react", page("renderer=react", 10, 400, 860)),
        ], entries, menu=True)
    finally:
        server.terminate()


# --- Linux (built in an oss container, run on an oss VM)

def linux(review, entries):
    # Built and packaged in the container, the package copied out here,
    # then to the VM as one tarball.
    work = tempfile.mkdtemp(prefix="proof-linux-")
    sh([os.path.join(ISOMER, "tools", "linux", "build.sh"), "--module", "playground",
        "--after", "linux/isomer_linux_application/package.sh /root/isomer-linux -c opt", "--out", "isomer-linux", os.path.join(work, "isomer-linux"),
        "-c", "opt", "//linux/isomer_linux_application:isomer_linux_application_bin",
        "//linux/isomer_linux_application:isomer_wasm_loader", "//shared/gallery_reactor:gallery.wasm"])
    sh(["chmod", "+x", os.path.join(work, "isomer-linux", "isomer"), os.path.join(work, "isomer-linux", "isomer_wasm_loader"),
        os.path.join(work, "isomer-linux", "run.sh")])
    package = os.path.join(work, "isomer-linux.tgz")
    sh(["tar", "-czf", package, "-C", work, "isomer-linux"])
    env = lease("linux", "--config=dev")
    scp(env, package, "/tmp/isomer-linux.tgz")
    ssh(env, "cd /tmp && tar -xzf isomer-linux.tgz && sudo apt-get install -y -q libsdl2-2.0-0 libsdl2-ttf-2.0-0 "
             "libwebkit2gtk-4.1-0 libgtk-3-0t64 libcurl4t64 >/dev/null")
    session = "XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DISPLAY=:0"

    def launcher(extra_env, wait):
        def shoot(slug, path, pause=None):
            ssh(env, "for p in $(pgrep -x isomer) $(pgrep -x isomer_wasm_lo); do kill $p; done; sleep 1", check=False)
            variables = dict(extra_env)
            if slug: variables["ISO_OPEN_APP"] = slug
            assignments = " ".join(f"{k}={shlex.quote(v)}" for k, v in variables.items())
            ssh(env, f"cd /tmp && ({session} {assignments} nohup /tmp/isomer-linux/run.sh >/tmp/isomer.log 2>&1 &)")
            time.sleep(pause or (wait if slug else 8))
            oss_shot(env, path)
        return shoot

    run_cells(review, "linux", "Ubuntu 26.04 (VM, llvmpipe)", "landscape", [
        ("opengl", launcher({}, 8)),
        ("wasm-opengl", launcher({"ISO_RUN_GALLERY_WASM": "1"}, 25)),
    ], entries, menu=True)
    hot_cell(review, "linux", "Ubuntu 26.04 (VM, llvmpipe)", "landscape", launcher, host=gateway(env, "linux"), run_wait=30)
    ssh(env, "for p in $(pgrep -x isomer) $(pgrep -x isomer_wasm_lo); do kill $p; done", check=False)


# --- Windows (built and run on an oss VM with the Windows build base)

# PowerShell, with $bin the build's bazel-bin: the app in C:\isomer-app.
WINDOWS_PACKAGE = "; ".join([
    "$out = \"$bin\\windows\\isomer_windows_application\"; $app = 'C:\\isomer-app'",
    "Remove-Item -Recurse -Force $app -ErrorAction SilentlyContinue; New-Item -ItemType Directory $app | Out-Null",
    "Copy-Item \"$out\\isomer.exe\", \"$out\\isomer_wasm_loader.exe\" $app",
    "foreach ($m in 'isomer.exe', 'isomer_wasm_loader.exe') { Get-Content \"$out\\$m.runfiles_manifest\" | "
    "ForEach-Object { $real = $_.Substring($_.IndexOf(' ') + 1); if ($real.EndsWith('.dll')) { Copy-Item $real $app -Force } } }",
    "Copy-Item C:\\Users\\runner\\gallery.wasm $app",
    "Set-Content \"$app\\version.txt\" '{version}'",
    "Copy-Item -Recurse C:\\isomer\\gallery\\assets \"$app\\assets\"",
    "$lines = Get-ChildItem -Recurse \"$app\\assets\" -Filter *.png | ForEach-Object { "
    "'gallery/' + $_.FullName.Substring($app.Length + 1).Replace('\\', '/') + ' ' + $_.FullName }",
    "$lines | Set-Content \"$app\\isomer.exe.runfiles_manifest\"; $lines | Set-Content \"$app\\isomer_wasm_loader.exe.runfiles_manifest\"",
])


def windows(review, entries):
    reactor = bazel_output("//shared/gallery_reactor:gallery.wasm", "-c", "opt")
    env = lease("windows", "--config=swift-6.3.2")
    archive = os.path.join(tempfile.mkdtemp(prefix="proof-windows-"), "isomer-src.tgz")
    sh(f"git ls-files -co --exclude-standard -z | COPYFILE_DISABLE=1 tar --no-xattrs -czf {shlex.quote(archive)} --null -T -", cwd=ISOMER)
    scp(env, archive, "C:/Users/runner/isomer-src.tgz")
    scp(env, reactor, "C:/Users/runner/gallery.wasm")
    ps = lambda command, check=True: ssh(env, command, check)
    ps("if (-not (Get-Command python -ErrorAction SilentlyContinue)) { winget install --id Python.Python.3.12 --silent --scope machine "
       "--accept-package-agreements --accept-source-agreements | Out-Null }; "
       "New-Item -ItemType Directory -Force C:\\isomer | Out-Null; tar -xzf C:\\Users\\runner\\isomer-src.tgz -C C:\\isomer")
    # Bazel in MSVC's environment (SwiftPM finds link.exe there) with Git's
    # bash for genrules, and Git's find, cp and od ahead of Windows' find
    # (rules_swift_package_manager runs them). Repository rules see the
    # environment only through --repo_env: Swift's SDKROOT and MSVC's.
    build = os.path.join(tempfile.mkdtemp(prefix="proof-windows-"), "build.cmd")
    repo_env = " ".join("--repo_env=" + name for name in [
        "SDKROOT", "PATH", "INCLUDE", "LIB", "LIBPATH", "UniversalCRTSdkDir", "UCRTVersion",
        "WindowsSdkDir", "WindowsSDKVersion", "VCToolsInstallDir", "VCINSTALLDIR", "VSINSTALLDIR"])
    open(build, "w").write("\r\n".join([
        "@echo off",
        'call "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvarsall.bat" arm64 >nul',
        'set "BAZEL_SH=C:\\Program Files\\Git\\bin\\bash.exe"',
        'set "PATH=%PATH:C:\\WINDOWS\\system32;=C:\\Program Files\\Git\\usr\\bin;C:\\WINDOWS\\system32;%"',
        "cd /d C:\\isomer\\playground",
        "set command=%1",
        "shift",
        # Startup option, then the command, its --repo_env flags (build
        # only: `info` takes them too, and must see the same ones to name
        # the same output base), then the rest.
        f"bazel --output_user_root=C:/b %command% {repo_env} %1 %2 %3 %4 %5 %6 %7 %8 %9",
    ]) + "\r\n")
    scp(env, build, "C:/Users/runner/build.cmd")
    ps("cmd /c C:\\Users\\runner\\build.cmd build -c opt "
       "//windows/isomer_windows_application:isomer //windows/isomer_windows_application:isomer_wasm_loader")
    # The app as it would ship: the app and its loader with the DLLs their
    # runfiles name (the cc libraries) beside them, the Gallery's reactor,
    # version.txt, and the Gallery's images with a runfiles manifest beside
    # each executable (the renderer finds an image by its imageset there;
    # the loader draws the reactor's).
    ps("$bin = (cmd /c C:\\Users\\runner\\build.cmd info -c opt bazel-bin 2>$null | Select-Object -Last 1); "
       + WINDOWS_PACKAGE.replace("{version}", review.version))

    def launcher(extra_env, wait):
        def shoot(slug, path, pause=None):
            variables = dict(extra_env)
            if slug: variables["ISO_OPEN_APP"] = slug
            sets = " ".join(f'set "{k}={v}"&&' for k, v in variables.items())
            # The logged-in desktop session runs it (SSH's session has no desktop).
            ps("Stop-Process -Name isomer,isomer_wasm_loader -ErrorAction SilentlyContinue; "
               f"Set-Content C:\\isomer-app\\run.cmd 'cd /d C:\\isomer-app && {sets} start \"\" isomer.exe'; "
               "schtasks /create /f /tn IsomerProof /tr C:\\isomer-app\\run.cmd /sc once /st 23:59 /ru runner /it | Out-Null; "
               "schtasks /run /tn IsomerProof | Out-Null")
            # The menu is the first launch after packaging, which Windows
            # scans first: it gets longer.
            time.sleep(pause or (wait if slug else 30))
            oss_shot(env, path)
        return shoot

    run_cells(review, "windows", "Windows 11 (VM, ARM64)", "landscape", [
        ("directx", launcher({}, 10)),
        ("wasm-directx", launcher({"ISO_RUN_GALLERY_WASM": "1"}, 30)),
    ], entries, menu=True)
    hot_cell(review, "windows", "Windows 11 (VM, ARM64)", "landscape", launcher, host=gateway(env, "windows"), run_wait=35)
    ps("Stop-Process -Name isomer,isomer_wasm_loader -ErrorAction SilentlyContinue", check=False)


PLATFORMS = {"ios": ios, "macos": macos, "android": android, "web": web, "linux": linux, "windows": windows}

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("platforms", nargs="*", default=list(PLATFORMS))
    parser.add_argument("--review", required=True)
    parser.add_argument("--commit", default=sh(["git", "rev-parse", "HEAD"], cwd=ISOMER).stdout.strip())
    parser.add_argument("--entries", default="")
    parser.add_argument("--version", default=None)
    parser.add_argument("--held", action="append", default=[], metavar="PLATFORM=FILE",
                        help="a lease you hold, its `oss machine lease --exports` output in FILE: used, not released")
    args = parser.parse_args()
    held.update(item.split("=", 1) for item in args.held)
    version = args.version or re.search(r'version_name = "([^"]+)"', open(os.path.join(
        ROOT, "android/playground_android_application/BUILD.bazel")).read()).group(1)
    entries = [e for e in ENTRIES if not args.entries or e[0] in args.entries.split(",")]
    review = Review(args.review, args.commit, version)
    global feed
    feed = Feed()
    try:
        for name in args.platforms:
            log(f"--- {name}")
            try:
                PLATFORMS[name](review, entries)
            except (Exception, SystemExit) as error:
                failures.append(f"{name}: {error}")
                log(f"{name} FAILED: {error}")
            finally:
                while leases:
                    sh(["oss", "machine", "release", leases.pop()], check=False)
    finally:
        feed.close()
        while leases:
            sh(["oss", "machine", "release", leases.pop()], check=False)
    log("done" if not failures else f"{len(failures)} missing: {failures}")
    sys.exit(1 if failures else 0)

if __name__ == "__main__":
    main()
