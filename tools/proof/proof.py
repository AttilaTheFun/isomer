#!/usr/bin/env python3
"""Isomer's release proof: its two apps on its six platforms, each platform
with its one renderer (SwiftUI on iOS and the Mac, Compose on Android, React
on the web, OpenGL on Linux, DirectX on Windows).

  * The Storybook (examples/*/storybook_*_application): its opening screen
    and every story's page (ISO_STORYBOOK_STORY=<id>), the code, what it
    does, and the code running.
  * On the iPhone, the Storybook compiled against Isomer's frameworks too
    (examples/apple/storybook_isomer_ios_application, a test, not released):
    each story beside its Apple-SwiftUI shot, with a diff, which should be
    empty (review-ios-storybook-isomer). A difference is Isomer's.
  * The Playground (examples/playground/): its projects, a project open, and 2048 and
    the Pokédex built on the device by the compiler it carries and running
    (ISO_PLAYGROUND_RUN_PROJECT=<name>).

  tools/proof/proof.py [ios] [macos] [android] [web] [linux] [windows] --review <dir>
      [--commit <sha>] [--version 0.38.N] [--stories text.styles,controls.picker]
      [--quick [--base origin/main]] [--held windows=<file>] [--web-toolchain <dir>]

--quick is a pull request's proof: both apps still built on every platform
(building is what catches most), a core set of stories (QUICK_STORIES) and
every story in a story file the change touches, and the Playground. Its
runs say `"scope": "quick"` and name no release, so they never stand for
one: a release is always proven whole.

The Storybook is launched once a platform and taken through its stories
in place (its control file, ISO_STORYBOOK_CONTROL, or on Android the URL
iso://story/<id>): a second or two a story where a launch each took five
to fourteen. A story that doesn't open so is launched to on its own.

What changes between runs without the apps changing is held still or left
out: the iPhone's and Android's status bars (simctl's override, SystemUI's
demo mode: 9:41), and on the desktops everything but the app's window (a
Mac's and Windows' screenshots are cropped to the app's frontmost window, a
Mac's rounded corners cut away, Linux's below GNOME's top bar and right of
its dock).

Each platform's apps are folders of the review store's snapshots,
<dir>/review-<platform>-<app>/manifest.json (reviews/MANIFEST.md; the
review server files only review- folders). The launch hooks reach each
platform as it passes a process environment: simctl's SIMCTL_CHILD_, `open
--env`, an Android intent's ISO_ extras, the web page's ISO_ query, the
desktops' environment.

The builds are this checkout's, made here (-c opt) before the platforms
start, except Linux's (a Linux container: tools/linux/build.sh) and
Windows' (on its VM). Then the platforms run at once, each on a lease of
its own (an iOS simulator, an Android emulator, macOS, Linux and Windows
VMs; the web in this Mac's headless Chrome), released however the run
ends. Stamp the build's version into both modules first, as CI does
(examples/playground/tools/playground/stamp.py and examples/tools/stamp_storybook.py),
and check the files out after.
"""
import argparse, json, os, re, shlex, shutil, subprocess, sys, tempfile, threading, time, urllib.parse

ISOMER = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXAMPLES = os.path.join(ISOMER, "examples")
PLAYGROUND = os.path.join(EXAMPLES, "playground")   # in the examples' module
APPS = {
    "storybook": {"name": "Storybook", "bundle": "com.LoganShire.IsomerStorybook"},
    "playground": {"name": "Playground", "bundle": "com.LoganShire.IsomerPlayground"},
}
# The Storybook compiled against Isomer's frameworks (iPhone only; a test,
# not released): every story shot again and set beside the Storybook's own,
# which is Apple's SwiftUI throughout. They should match.
ISOMER_STORYBOOK = {"name": "Storybook", "bundle": "com.LoganShire.IsomerStorybookCompiled"}
# The Playground's screens: its opening screen, a project open, and two
# projects built on the device and running (2048; the Pokédex, whose
# @Observable needs the compiler's macro plugins).
PLAYGROUND_SHOTS = [
    ("projects", "Projects", {}, "open"),
    ("project", "A project (2048)", {"ISO_PLAYGROUND_OPEN_PROJECT": "2048"}, "open"),
    ("game2048", "2048, built here and running", {"ISO_PLAYGROUND_RUN_PROJECT": "2048"}, "run"),
    ("pokedex", "The Pokédex, built here and running", {"ISO_PLAYGROUND_RUN_PROJECT": "Pokédex"}, "run"),
]

failures = []
lock = threading.Lock()


def log(message):
    name = threading.current_thread().name
    with lock:
        print(f"[proof {name}] {message}", flush=True)


def sh(command, check=True, cwd=ISOMER, **kwargs):
    result = subprocess.run(command, shell=isinstance(command, str), cwd=cwd, capture_output=True, text=True, **kwargs)
    if check and result.returncode != 0:
        raise RuntimeError(f"{command}\n{result.stdout[-3000:]}{result.stderr[-3000:]}")
    return result


def bazel_output(cwd, target, *flags, suffix=""):
    sh(["bazel", "build", target, *flags], cwd=cwd)
    files = sh(["bazel", "cquery", "--output=files", target, *flags], cwd=cwd).stdout.split()
    return os.path.join(cwd, next(f for f in files if f.endswith(suffix)))


def stories(only=None):
    """The Storybook's stories, (id, title), in its sidebar's order: the
    areas as Story.swift lists them, each area's stories as its file does."""
    root = os.path.join(EXAMPLES, "storybook")
    order = re.search(r"areas: \[StoryArea\] = \[(.*?)\]", open(os.path.join(root, "Story.swift")).read(), re.S).group(1)
    order = [name.strip() for name in order.split(",") if name.strip()]
    areas = {}
    for name in os.listdir(os.path.join(root, "stories")):
        text = open(os.path.join(root, "stories", name)).read()
        area = re.search(r"static let (\w+) = StoryArea\(", text).group(1)
        areas[area] = re.findall(r'^\s+"([a-z]+\.[a-z]+)", "([^"]+)"', text, re.M)
    found = [story for area in order for story in areas[area]]
    return [story for story in found if not only or story[0] in only]


# A pull request's proof (--quick): a story from most areas, the ones that
# hold still (no animation).
QUICK_STORIES = ["text.styles", "text.markdown", "images.symbols", "buttons.styles", "controls.toggle",
                 "controls.picker", "layout.stacks", "layout.grid", "lists.sections", "navigation.toolbar",
                 "presentation.sheet", "scrolling.vertical", "shapes.gradients", "input.field", "state.observable"]


def changed_stories(base):
    """Every story in a story file this checkout changes from `base` (its
    commits since they parted, and what isn't committed)."""
    merge_base = sh(["git", "merge-base", base, "HEAD"], cwd=ISOMER).stdout.strip()
    names = sh(["git", "diff", "--name-only", merge_base, "--", "examples/storybook/stories/"], cwd=ISOMER).stdout.split()
    found = set()
    for name in names:
        path = os.path.join(ISOMER, name)
        if os.path.exists(path):
            found.update(re.findall(r'^\s+"([a-z]+\.[a-z]+)", "', open(path).read(), re.M))
    return found


def crop(path, box):
    """A screenshot cut down to `box` (left, top, right, bottom), within the
    screenshot (a window larger than the screen is cut to what shows); kept
    whole when nothing of the box is on it."""
    try:
        from PIL import Image
        image = Image.open(path)
        left, top, right, bottom = box
        left, top, right, bottom = max(0, left), max(0, top), min(image.width, right), min(image.height, bottom)
        if left < right and top < bottom:
            image.crop((left, top, right, bottom)).save(path)
    except Exception as error:
        log(f"crop {os.path.basename(path)}: {error}")


# A Mac window's corners in the VM's screenshots (macOS 27, at 1x): the curve
# is 14 pixels in from its outer pixel; two more for a darker shadow.
CORNER_RADIUS = 16


def cut_corners(path):
    """A Mac window's shot without what isn't the window's: its outer pixel
    and the curve of its corners, where its edge blends with its shadow and
    the desktop behind (OS Server's proof saw the edge 15-20 levels darker
    in one of two runs, the window's own pixels the same), made transparent."""
    try:
        from PIL import Image, ImageDraw
        image = Image.open(path).convert("RGBA")
        image = image.crop((1, 1, image.width - 1, image.height - 1))
        mask = Image.new("L", image.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, image.width - 1, image.height - 1), radius=CORNER_RADIUS, fill=255)
        Image.composite(image, Image.new("RGBA", image.size, (0, 0, 0, 0)), mask).save(path)
    except Exception as error:
        log(f"corners {os.path.basename(path)}: {error}")


# Stories that load something (a picture from the network, a web page, map
# tiles, a video) get longer to settle after they open.
SLOW_STORIES = {"images.async": 4, "isomer.webview": 5, "isomer.map": 5, "isomer.video": 4}


def wait_until(check, seconds):
    """Whether `check()` came true within `seconds`."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            if check():
                return True
        except Exception:
            pass
        time.sleep(0.25)
    return False


class Switcher:
    """The Storybook taken through its stories in one launch. `start(path)`
    launches it (its control file set) and shoots its opening screen;
    `request(story)` asks for a story; `shown()` says which story it last
    opened (None where it can't say: then a fixed wait); `shoot(path)`."""

    def __init__(self, start, request, shoot, shown=None, settle=1.0):
        self.start, self.request, self.shoot, self.shown, self.settle = start, request, shoot, shown, settle

    def show(self, story, path):
        """The story shot in place: False when it didn't open."""
        self.request(story)
        if self.shown is None:
            time.sleep(self.settle + 1.0)
        elif not wait_until(lambda: self.shown() == story, 10):
            return False
        time.sleep(self.settle + SLOW_STORIES.get(story, 0))
        self.shoot(path)
        return True


# --- oss

held = {}


def lease(platform, *flags):
    """An oss lease's exports (OSS_ID, OSS_SSH_PORT, OSS_UDID…)."""
    if platform in held:
        env = dict(re.findall(r"(OSS_[A-Z_]+)='([^']*)'", open(held[platform]).read()))
        env["held"] = True
        log(f"using held {platform} {env['OSS_ID']}")
        return env
    out = sh(["oss", "machine", "lease", platform, "--exports", "--minutes=180", *flags]).stdout
    env = dict(re.findall(r"(OSS_[A-Z_]+)='([^']*)'", out))
    log(f"leased {platform} {env['OSS_ID']}")
    return env


def release(env):
    if env and not env.get("held"):
        sh(["oss", "machine", "release", env["OSS_ID"]], check=False)


def ssh(env, command, check=True):
    return sh(["oss", "machine", "ssh", env["OSS_ID"], "--", command], check=check)


def scp(env, source, destination):
    sh(["scp", "-q", "-P", env["OSS_SSH_PORT"], "-o", f"UserKnownHostsFile={os.path.expanduser('~/.local/state/oss/known_hosts-' + env['OSS_ID'])}",
        "-o", "StrictHostKeyChecking=accept-new", source, f"{env.get('OSS_SSH_USER', 'runner')}@127.0.0.1:{destination}"])


def oss_shot(env, path):
    sh(["oss", "machine", "screenshot", env["OSS_ID"], path])


# --- The review store

class Review:
    def __init__(self, folder, commit, version, quick=False):
        self.folder, self.commit, self.version, self.quick = folder, commit, version, quick

    def manifest(self, name, app, device, orientation, items):
        """A cell's manifest. A quick run's names no release and says so:
        it never stands for one."""
        manifest = {"schema": 1, "app": APPS[app]["name"], "version": self.version,
                    "release": None if self.quick else self.version, "commit": self.commit, "kind": "snapshots",
                    "target": name, "device": device, "orientation": orientation,
                    "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "items": items}
        if self.quick:
            manifest["scope"] = "quick"
        return manifest

    def dir(self, name):
        path = os.path.join(self.folder, f"review-{name}")
        os.makedirs(path, exist_ok=True)
        return path

    def compared_cell(self, name, app, device, orientation, shots):
        """`shots`: (item name, capture file, reference file) in the cell's
        folder: each item the capture against its reference, with a diff
        image and the count of pixels that differ (`same` when none do)."""
        out = self.dir(name)
        items, missing = [], []
        for item, capture, reference in shots:
            if not os.path.exists(os.path.join(out, capture)):
                missing.append(item)
                continue
            entry = {"name": item, "status": "new", "capture": capture}
            if os.path.exists(os.path.join(out, reference)):
                entry["reference"] = reference
                # Parity: held to the other app's same screen, which Reviews
                # shows whatever ran before on this target.
                entry["parity"] = reference
                entry["parity_with"] = f"Storybook (SwiftUI) {self.version}"
                changed = diff_images(os.path.join(out, reference), os.path.join(out, capture),
                                      os.path.join(out, capture.replace(".png", ".diff.png")))
                if changed is not None:
                    entry.update(status="same" if changed == 0 else "changed", changed_px=changed)
                    if changed:
                        entry["diff"] = capture.replace(".png", ".diff.png")
            items.append(entry)
        with lock:
            failures.extend(f"{name}: {item}" for item in missing)
        json.dump(self.manifest(name, app, device, orientation, items), open(os.path.join(out, "manifest.json"), "w"), indent=1)
        changed = [i["name"] for i in items if i.get("status") == "changed"]
        log(f"{name}: {len(items)} screens, {len(changed)} differ from their reference"
            + (f", MISSING {missing}" if missing else ""))

    def cell(self, name, app, device, orientation, shots):
        """`shots`: (item name, capture file) pairs; a missing capture is a failure."""
        out = self.dir(name)
        items = [{"name": item, "status": "new", "capture": capture} for item, capture in shots
                 if os.path.exists(os.path.join(out, capture))]
        missing = [item for item, capture in shots if not os.path.exists(os.path.join(out, capture))]
        with lock:
            failures.extend(f"{name}: {item}" for item in missing)
        json.dump(self.manifest(name, app, device, orientation, items), open(os.path.join(out, "manifest.json"), "w"), indent=1)
        log(f"{name}: {len(items)} screens" + (f", MISSING {missing}" if missing else ""))


def diff_images(reference, capture, out):
    """Pixels that differ between two screenshots (a channel off by more than
    24), with the difference drawn in red over a faded capture at `out`;
    None when they can't be compared (Pillow missing, sizes differ)."""
    try:
        from PIL import Image, ImageChops
    except ImportError:
        return None
    a, b = Image.open(reference).convert("RGB"), Image.open(capture).convert("RGB")
    if a.size != b.size:
        return None
    mask = ImageChops.difference(a, b).convert("L").point(lambda v: 255 if v > 24 else 0)
    changed = sum(1 for v in mask.getdata() if v)
    if changed:
        faded = Image.blend(b, Image.new("RGB", b.size, "white"), 0.6)
        faded.paste(Image.new("RGB", b.size, (255, 0, 0)), mask=mask)
        faded.save(out)
    return changed


def storybook_shots(out, story_list, launcher, waits, switcher, app="storybook"):
    """The Storybook's opening screen and every story's page into `out`:
    in place through `switcher` where the platform has one, a launch each
    otherwise (and for a story that didn't open in place)."""
    shots = [("Stories", "stories.png")]
    try:
        if switcher:
            switcher.start(os.path.join(out, "stories.png"))
        else:
            launcher(app, {}, waits["open"], os.path.join(out, "stories.png"))
    except Exception as error:
        log(f"{app} stories: {error}")
    for story, title in story_list:
        capture = os.path.join(out, f"{story}.png")
        try:
            if not (switcher and switcher.show(story, capture)):
                if switcher:
                    log(f"{app} {story}: didn't open in place; launched to")
                launcher(app, {"ISO_STORYBOOK_STORY": story}, waits["story"] + SLOW_STORIES.get(story, 0), capture)
        except Exception as error:
            log(f"{app} {story}: {error}")
        shots.append((title, f"{story}.png"))
    return shots


def shoot_apps(review, platform, device, orientation, launcher, story_list, waits, switcher=None):
    """Both apps on one platform. `launcher(app, environment, wait, path)`
    launches the app afresh with `environment`, waits, and shoots `path`.
    `waits`: seconds after a launch: open (the app's opening screen or a
    page), story, run (a project built and running). `switcher`: the
    Storybook's stories in one launch (Switcher)."""
    out = review.dir(f"{platform}-storybook")
    shots = storybook_shots(out, story_list, launcher, waits, switcher)
    review.cell(f"{platform}-storybook", "storybook", device, orientation, shots)

    out = review.dir(f"{platform}-playground")
    shots = []
    for slug, title, environment, kind in PLAYGROUND_SHOTS:
        capture = f"{slug}.png"
        try:
            launcher("playground", environment, waits[kind], os.path.join(out, capture))
        except Exception as error:
            log(f"playground {slug}: {error}")
        shots.append((title, capture))
    review.cell(f"{platform}-playground", "playground", device, orientation, shots)


# --- iOS (an oss simulator lease: simctl on the server, which is this Mac)

def build_ios():
    return {
        "storybook": bazel_output(EXAMPLES, "//apple/storybook_ios_application:storybook_ios_sim_application",
                                  "-c", "opt", "--ios_multi_cpus=sim_arm64", suffix=".ipa"),
        "storybook-isomer": bazel_output(EXAMPLES, "//apple/storybook_isomer_ios_application", "-c", "opt",
                                         "--ios_multi_cpus=sim_arm64", suffix=".ipa"),
        # The compiler linked into the app (its staged embedded_toolchain).
        "playground": bazel_output(EXAMPLES, "//playground/apple/playground_ios_application", "-c", "opt",
                                   "--ios_multi_cpus=sim_arm64", "--define", "iso_playground_embedded=1", suffix=".ipa"),
    }


def ios(review, story_list, builds):
    env = lease("ios")
    try:
        udid = env["OSS_UDID"]
        for app, ipa in builds.items():
            work = tempfile.mkdtemp(prefix=f"proof-ios-{app}-")
            sh(["unzip", "-q", ipa, "-d", work])
            payload = os.path.join(work, "Payload")
            sh(["xcrun", "simctl", "install", udid, os.path.join(payload, os.listdir(payload)[0])])
        # The status bar held still, as every snapshot here holds it (~/Developer/AGENTS.md):
        # 9:41, full Wi-Fi and signal, a full battery, no carrier.
        sh(["xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--dataNetwork", "wifi", "--wifiMode", "active",
            "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4", "--operatorName", "",
            "--batteryState", "charged", "--batteryLevel", "100"], check=False)

        def launcher(app, environment, wait, path):
            bundle = ISOMER_STORYBOOK["bundle"] if app == "storybook-isomer" else APPS[app]["bundle"]
            # Every app closed: launched with another in front, iOS shows a
            # "◀ <that app>" link in the status bar.
            for other in list(APPS.values()) + [ISOMER_STORYBOOK]:
                sh(["xcrun", "simctl", "terminate", udid, other["bundle"]], check=False)
            variables = dict(os.environ)
            for key, value in environment.items(): variables["SIMCTL_CHILD_" + key] = value
            subprocess.run(["xcrun", "simctl", "launch", udid, bundle], env=variables, capture_output=True)
            time.sleep(wait)
            sh(["xcrun", "simctl", "io", udid, "screenshot", "--mask=black", path])

        def switcher(app):
            # The simulator runs on this Mac (oss's server is here): its apps
            # read and write the control file where the proof does.
            control = os.path.join(tempfile.mkdtemp(prefix=f"proof-ios-{app}-"), "control")

            def read(path):
                return open(path).read().strip() if os.path.exists(path) else None
            return Switcher(start=lambda path: launcher(app, {"ISO_STORYBOOK_CONTROL": control}, 5, path),
                            request=lambda story: open(control, "w").write(story),
                            shown=lambda: read(control + ".shown"),
                            shoot=lambda path: sh(["xcrun", "simctl", "io", udid, "screenshot", "--mask=black", path]))

        waits = {"open": 5, "story": 4, "run": 25}
        shoot_apps(review, "ios", "iPhone (simulator)", "portrait", launcher, story_list, waits, switcher("storybook"))
        # The Storybook compiled against Isomer's frameworks, each story
        # beside the one just shot with Apple's SwiftUI.
        native = review.dir("ios-storybook")
        out = review.dir("ios-storybook-isomer")
        shots = []
        for title, capture in storybook_shots(out, story_list, launcher, waits, switcher("storybook-isomer"), app="storybook-isomer"):
            reference = capture.replace(".png", ".reference.png")
            if os.path.exists(os.path.join(native, capture)):
                shutil.copyfile(os.path.join(native, capture), os.path.join(out, reference))
            shots.append((title, capture, reference))
        review.compared_cell("ios-storybook-isomer", "storybook", "iPhone (simulator), Isomer's SwiftUI against Apple's",
                             "portrait", shots)
        for app in list(APPS.values()) + [ISOMER_STORYBOOK]:
            sh(["xcrun", "simctl", "terminate", udid, app["bundle"]], check=False)
    finally:
        release(env)


# --- macOS (a vanilla oss VM: no Xcode, no Swift; the apps copied in)

def build_macos():
    return {
        "storybook": bazel_output(EXAMPLES, "//apple/storybook_macos_application", "-c", "opt", suffix=".zip"),
        "playground": bazel_output(EXAMPLES, "//playground/apple/playground_macos_application", "-c", "opt", suffix=".zip"),
    }


def macos(review, story_list, builds):
    env = lease("macos")
    try:
        for app, archive in builds.items():
            scp(env, archive, f"/tmp/{app}.zip")
            ssh(env, f"cd /tmp && rm -rf {APPS[app]['name']}.app && ditto -x -k {app}.zip .")
        # The app's window, where the screenshot is cropped to (window_rect.swift).
        helper = os.path.join(tempfile.mkdtemp(prefix="proof-macos-"), "window_rect")
        sh(["swiftc", "-O", "-target", "arm64-apple-macos14", os.path.join(ISOMER, "tools", "proof", "window_rect.swift"), "-o", helper])
        scp(env, helper, "/tmp/window_rect")
        names = " ".join(APPS[app]["name"] for app in APPS)
        # Scroll bars as overlays, shown only while scrolling. "Automatic" (the
        # default) chose by the pointing devices it saw, so one lease drew
        # legacy scroll bars, which take the sidebar's width, and another
        # didn't. Set before the apps open, which read it as they start.
        ssh(env, "sudo launchctl asuser $(id -u runner) defaults write -g AppleShowScrollBars -string WhenScrolling")

        def shoot(path):
            oss_shot(env, path)
            rect = ssh(env, f"sudo launchctl asuser $(id -u runner) /tmp/window_rect {names}", check=False).stdout.split()
            if len(rect) == 4:
                x, y, w, h = map(int, rect)
                crop(path, (x, y, x + w, y + h))
                cut_corners(path)

        def launcher(app, environment, wait, path):
            name = APPS[app]["name"]
            ssh(env, f"pkill -x {name}; sleep 1", check=False)
            flags = " ".join(f"--env {k}={shlex.quote(v)}" for k, v in environment.items())
            ssh(env, f"sudo launchctl asuser $(id -u runner) open -n {flags} /tmp/{name}.app")
            time.sleep(wait)
            shoot(path)

        control = "/tmp/storybook-control"
        ssh(env, f"rm -f {control} {control}.shown", check=False)
        switcher = Switcher(start=lambda path: launcher("storybook", {"ISO_STORYBOOK_CONTROL": control}, 6, path),
                            request=lambda story: ssh(env, f"printf %s {shlex.quote(story)} > {control}"),
                            shown=lambda: ssh(env, f"cat {control}.shown 2>/dev/null", check=False).stdout.strip(),
                            shoot=shoot)
        shoot_apps(review, "macos", "Mac (macOS 27 VM)", "landscape", launcher, story_list,
                   {"open": 6, "story": 4, "run": 30}, switcher)
        ssh(env, "pkill -x Storybook; pkill -x Playground", check=False)
    finally:
        release(env)


# --- Android (an oss emulator lease)

def build_android():
    return {
        "storybook": bazel_output(EXAMPLES, "//android/storybook_android_application:storybook_android_application_apk",
                                  "-c", "opt", suffix="_apk.apk"),
        "playground": bazel_output(EXAMPLES, "//playground/android/playground_android_application:playground_android_application_apk",
                                   "-c", "opt", suffix="_apk.apk"),
    }


def android(review, story_list, builds):
    env = lease("android")
    try:
        adb = ["oss", "machine", "adb", env["OSS_ID"], "--"]
        for app, apk in builds.items():
            sh(adb + ["install", "-r", apk])
            sh(adb + ["shell", "pm", "clear", APPS[app]["bundle"]], check=False)

        def launcher(app, environment, wait, path):
            bundle = APPS[app]["bundle"]
            sh(adb + ["shell", "am", "force-stop", bundle], check=False)
            arguments = []
            for key, value in environment.items(): arguments += ["--es", key, value]
            # adb shell joins its arguments into one line for the device's sh.
            sh(adb + ["shell", "am", "start", "-n", f"{bundle}/.MainActivity", *map(shlex.quote, arguments)])
            time.sleep(wait)
            oss_shot(env, path)

        # The status bar held still (SystemUI's demo mode), as every snapshot
        # holds it (~/Developer/AGENTS.md): 9:41, Wi-Fi, a full battery, no
        # cellular network (shown, the emulator drew it differently from run
        # to run), no notifications. Twice, a few seconds apart: SystemUI may
        # still be settling after boot.
        sh(adb + ["shell", "settings", "put", "global", "sysui_demo_allowed", "1"], check=False)
        for attempt in range(2):
            if attempt:
                time.sleep(4)
            for command in (["exit"], ["enter"], ["clock", "-e", "hhmm", "0941"], ["battery", "-e", "level", "100", "-e", "plugged", "false"],
                            ["network", "-e", "wifi", "show", "-e", "level", "4", "-e", "fully", "true"],
                            ["network", "-e", "mobile", "hide"], ["network", "-e", "nosim", "hide"],
                            ["notifications", "-e", "visible", "false"]):
                sh(adb + ["shell", "am", "broadcast", "-a", "com.android.systemui.demo", "-e", "command", *command], check=False)
        # The first launch after an install shows the splash a while longer.
        for app in APPS:
            launcher(app, {}, 8, os.path.join(tempfile.mkdtemp(), "warm.png"))
        # The running Storybook takes iso://story/<id> (a VIEW intent to its
        # single-task activity, onOpenURL); it can't say when it has opened
        # one, so a fixed wait.
        bundle = APPS["storybook"]["bundle"]
        switcher = Switcher(start=lambda path: launcher("storybook", {}, 6, path),
                            request=lambda story: sh(adb + ["shell", "am", "start", "-a", "android.intent.action.VIEW",
                                                            "-d", shlex.quote(f"iso://story/{story}"), bundle]),
                            shoot=lambda path: oss_shot(env, path), settle=1.5)
        shoot_apps(review, "android", "Android phone (emulator)", "portrait", launcher, story_list,
                   {"open": 6, "story": 5, "run": 30}, switcher)
        for app in APPS.values():
            sh(adb + ["shell", "am", "force-stop", app["bundle"]], check=False)
    finally:
        release(env)


# --- The web (this Mac's headless Chrome, the optimized sites served here)

def build_web(toolchain):
    """The Storybook's site, and the Playground's whole site (the splash page
    and the Playground under playground/), with the in-browser compiler
    staged from `toolchain` (package_site.sh)."""
    storybook = bazel_output(EXAMPLES, "//web/storybook_web_application:storybook_web_application_site", "-c", "opt")
    work = tempfile.mkdtemp(prefix="proof-web-")
    sh([os.path.join(PLAYGROUND, "tools", "playground", "package_site.sh"), "--toolchain-from", toolchain,
        "--out", os.path.join(work, "site.tar.gz")], cwd=PLAYGROUND)
    os.makedirs(os.path.join(work, "site"))
    sh(["tar", "-xzf", os.path.join(work, "site.tar.gz"), "-C", os.path.join(work, "site")])
    return {"storybook": storybook, "playground": os.path.join(work, "site")}


def web(review, story_list, builds):
    port = 8700 + os.getpid() % 150
    servers = {
        "storybook": (port, subprocess.Popen([sys.executable, "-m", "http.server", str(port), "--bind", "127.0.0.1"],
                                             cwd=builds["storybook"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)),
        "playground": (port + 1, subprocess.Popen([sys.executable, "-m", "http.server", str(port + 1), "--bind", "127.0.0.1"],
                                                  cwd=builds["playground"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)),
    }
    cdp = os.path.join(ISOMER, "tools", "testing", "cdp.py")
    try:
        time.sleep(1)

        def launcher(app, environment, wait, path):
            app_port = servers[app][0]
            page = "" if app == "storybook" else "playground/"
            query = "&".join(["renderer=react"] + [f"{k}={urllib.parse.quote(v)}" for k, v in environment.items()])
            url = f"http://127.0.0.1:{app_port}/{page}?{query}"
            # The page drawn (the renderer's first tree committed) before the
            # wait, which is then the settling: a fixed wait alone shot a blank
            # page when a load ran slow (0.39.1's web Storybook, three stories).
            sh([sys.executable, cdp, url, path, "until=window.__isoLastTree", f"wait={wait}", "width=1280", "height=800"])

        # A fresh Chrome profile's first load compiles the reactor: warm both
        # sites up before the shots.
        for app in APPS:
            launcher(app, {}, 15, os.path.join(tempfile.mkdtemp(), "warm.png"))
        shoot_apps(review, "web", "Chrome (desktop width)", "landscape", launcher, story_list,
                   # A run fetches and starts the in-browser compiler first.
                   {"open": 8, "story": 6, "run": 75})
    finally:
        for _, server in servers.values():
            server.terminate()


# --- Linux (built in a Linux container here, run on an oss VM)

def build_linux():
    """Both apps built and packaged in the container, each one directory."""
    work = tempfile.mkdtemp(prefix="proof-linux-")
    script = os.path.join(ISOMER, "tools", "linux", "build.sh")
    sh([script, "--module", "examples",
        "--after", "linux/storybook_linux_application/package.sh /root/storybook-linux -c opt",
        "--out", "storybook-linux", os.path.join(work, "storybook-linux"),
        "-c", "opt", "//linux/storybook_linux_application:storybook_linux_application_bin"])
    sh([script, "--module", "examples",
        "--after", "playground/linux/playground_linux_application/package.sh /root/playground-linux -c opt",
        "--out", "playground-linux", os.path.join(work, "playground-linux"),
        "-c", "opt", "//playground/linux/playground_linux_application:playground_linux_application_bin",
        "//playground/linux/playground_linux_application:playground_wasm_loader", "//playground/shared/compiler:toolchain",
        "//playground/apple/playground_ios_application:playground_sdk"])
    packages = {}
    for app in APPS:
        package = os.path.join(work, f"{app}-linux.tgz")
        sh(["tar", "-czf", package, "-C", work, f"{app}-linux"], env=dict(os.environ, COPYFILE_DISABLE="1"))
        packages[app] = package
    return packages


def linux(review, story_list, builds):
    env = lease("linux", "--config=dev")
    try:
        for app, package in builds.items():
            scp(env, package, f"/tmp/{app}-linux.tgz")
            ssh(env, f"cd /tmp && tar -xzf {app}-linux.tgz")
        ssh(env, "sudo apt-get install -y -q libsdl2-2.0-0 libsdl2-ttf-2.0-0 libwebkit2gtk-4.1-0 libgtk-3-0t64 libcurl4t64 >/dev/null")
        session = "XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 DISPLAY=:0"
        kill = "for p in $(pgrep -x storybook) $(pgrep -x playground) $(pgrep -x playground_wasm); do kill $p; done"

        def shoot(path):
            oss_shot(env, path)
            # Below GNOME's top bar (its clock) and right of its dock.
            from PIL import Image
            width, height = Image.open(path).size
            crop(path, (67, 32, width, height))

        def launcher(app, environment, wait, path):
            ssh(env, f"{kill}; sleep 1", check=False)
            assignments = " ".join(f"{k}={shlex.quote(v)}" for k, v in environment.items())
            ssh(env, f"cd /tmp && ({session} {assignments} nohup /tmp/{app}-linux/run.sh >/tmp/{app}.log 2>&1 &)")
            time.sleep(wait)
            shoot(path)

        control = "/tmp/storybook-control"
        ssh(env, f"rm -f {control} {control}.shown", check=False)
        switcher = Switcher(start=lambda path: launcher("storybook", {"ISO_STORYBOOK_CONTROL": control}, 8, path),
                            request=lambda story: ssh(env, f"printf %s {shlex.quote(story)} > {control}"),
                            shown=lambda: ssh(env, f"cat {control}.shown 2>/dev/null", check=False).stdout.strip(),
                            shoot=shoot, settle=2.0)
        shoot_apps(review, "linux", "Ubuntu 26.04 (VM, llvmpipe)", "landscape", launcher, story_list,
                   {"open": 8, "story": 6, "run": 50}, switcher)
        ssh(env, kill, check=False)
    finally:
        release(env)


# --- Windows (built and run on an oss VM with the Swift build layer)

def build_windows():
    """What the Windows VM takes from here: the Playground SDK and the wasm
    SDK's sysroot and static stdlib (platform-independent files; the VM's
    own Swift toolchain gives the frontend and wasm-ld)."""
    work = tempfile.mkdtemp(prefix="proof-windows-")
    sdk = bazel_output(EXAMPLES, "//playground/apple/playground_ios_application:playground_sdk", "-c", "opt")
    toolchain = bazel_output(EXAMPLES, "//playground/shared/compiler:toolchain", "-c", "opt")
    environment = dict(os.environ, COPYFILE_DISABLE="1")
    sh(["tar", "--no-xattrs", "-czhf", os.path.join(work, "playground_sdk.tgz"), "-C", os.path.dirname(sdk), os.path.basename(sdk)], env=environment)
    sh(["tar", "--no-xattrs", "-czhf", os.path.join(work, "wasm_data.tgz"), "-C", os.path.join(toolchain, "playground_toolchain"), "data"], env=environment)
    source = os.path.join(work, "isomer-src.tgz")
    sh(f"git ls-files -co --exclude-standard -z | tar --no-xattrs -czf {shlex.quote(source)} --null -T -", cwd=ISOMER, env=environment)
    return {"sdk": os.path.join(work, "playground_sdk.tgz"), "data": os.path.join(work, "wasm_data.tgz"), "source": source}


# PowerShell, with $bin a module's bazel-bin: an app in C:\proof\<app> as it
# would ship: its executables with the DLLs their runfiles name beside them,
# version.txt, and (the Storybook's) images with a runfiles manifest beside
# the executable, which the renderer finds an image by.
def windows_package(app, version):
    if app == "storybook":
        out, executables = "$bin\\windows\\storybook_windows_application", ["storybook_windows_application.exe"]
    else:
        out, executables = "$bin\\playground\\windows\\playground_windows_application", ["playground.exe", "playground_wasm_loader.exe"]
    steps = [
        f"$out = \"{out}\"; $app = 'C:\\proof\\{app}'",
        "Remove-Item -Recurse -Force $app -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $app | Out-Null",
        "Copy-Item " + ", ".join(f"\"$out\\{e}\"" for e in executables) + " $app",
        "foreach ($m in " + ", ".join(f"'{e}'" for e in executables) + ") { Get-Content \"$out\\$m.runfiles_manifest\" | "
        "ForEach-Object { $real = $_.Substring($_.IndexOf(' ') + 1); if ($real.EndsWith('.dll')) { Copy-Item $real $app -Force } } }",
        f"Set-Content \"$app\\version.txt\" '{version}'",
    ]
    if app == "storybook":
        steps += [
            "Copy-Item -Recurse C:\\isomer\\examples\\storybook\\assets \"$app\\assets\"",
            "$lines = Get-ChildItem -Recurse \"$app\\assets\" -Filter *.png | ForEach-Object { "
            "'storybook/' + $_.FullName.Substring($app.Length + 1).Replace('\\', '/') + ' ' + $_.FullName }",
            "$lines | Set-Content \"$app\\storybook_windows_application.exe.runfiles_manifest\"",
        ]
    else:
        # The compiler beside the app: the VM's Swift toolchain's frontend,
        # wasm-ld, macro plugin server and plugins with the DLLs they load
        # (Windows' toolchain keeps them all in usr\bin), the wasm SDK's
        # data and the Playground SDK from the Mac.
        steps += [
            "$tc = (Get-ChildItem \"$env:LOCALAPPDATA\\Programs\\Swift\\Toolchains\" | Select-Object -First 1).FullName + '\\usr\\bin'",
            "New-Item -ItemType Directory -Force \"$app\\playground_toolchain\\usr\\bin\" | Out-Null",
            "Copy-Item \"$tc\\swift-frontend.exe\", \"$tc\\wasm-ld.exe\", \"$tc\\*.dll\" \"$app\\playground_toolchain\\usr\\bin\"",
            "tar -xzf C:\\Users\\runner\\wasm_data.tgz -C \"$app\\playground_toolchain\"",
            "tar -xzf C:\\Users\\runner\\playground_sdk.tgz -C $app",
            # Its projects start from the templates (a VM that ran an
            # earlier build keeps that build's in Application Support).
            # Guarded: on a fresh VM there is none, and a failed Remove-Item,
            # silent or not, as the last command fails the whole step.
            "if (Test-Path \"$env:LOCALAPPDATA\\playground\") { Remove-Item -Recurse -Force \"$env:LOCALAPPDATA\\playground\" }",
        ]
    return "; ".join(steps)


def windows(review, story_list, builds):
    env = lease("windows", "--config=swift-6.3.2")
    try:
        for name, path in builds.items():
            scp(env, path, f"C:/Users/runner/{os.path.basename(path)}")
        ps = lambda command, check=True: ssh(env, command, check)
        # Python for rules_swift's autoconfiguration (the build layer carries
        # it from tools/ci/oss/windows-swift.ps1; older ones don't).
        ps("if (-not (Test-Path 'C:\\Program Files\\Python312-arm64\\python.exe')) { winget install --id Python.Python.3.12 --silent --scope machine "
           "--accept-package-agreements --accept-source-agreements | Out-Null }; "
           "Remove-Item -Recurse -Force C:\\isomer-src -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force C:\\isomer-src | Out-Null; "
           "tar -xzf C:\\Users\\runner\\isomer-src.tgz -C C:\\isomer-src")
        # The checkout mirrored into the workspace Bazel built before (its
        # output base keyed by the path, so builds stay warm): files this
        # commit deleted go too, Bazel's convenience junctions are left alone.
        ps("robocopy C:\\isomer-src C:\\isomer /MIR /XJ /XD bazel-* /NFL /NDL /NJH /NJS /NP | Out-Null; "
           "if ($LASTEXITCODE -ge 8) { exit 1 } else { exit 0 }")
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
            # The module, then the command and its arguments.
            "cd /d C:\\isomer\\%1",
            "shift",
            "set command=%1",
            "shift",
            # Startup option, then the command, its --repo_env flags (`info`
            # must see the same ones to name the same output base), then the rest.
            f"bazel --output_user_root=C:/b %command% {repo_env} %1 %2 %3 %4 %5 %6 %7 %8 %9",
        ]) + "\r\n")
        scp(env, build, "C:/Users/runner/build.cmd")
        for module, app, targets in (
                ("examples", "storybook", "//windows/storybook_windows_application:storybook_windows_application"),
                ("examples", "playground", "//playground/windows/playground_windows_application:playground "
                                           "//playground/windows/playground_windows_application:playground_wasm_loader")):
            ps(f"cmd /c C:\\Users\\runner\\build.cmd {module} build -c opt {targets}")
            ps(f"$bin = (cmd /c C:\\Users\\runner\\build.cmd {module} info -c opt bazel-bin 2>$null | Select-Object -Last 1); "
               + windows_package(app, review.version))

        executables = {"storybook": "storybook_windows_application.exe", "playground": "playground.exe"}
        stop = "Stop-Process -Name storybook_windows_application,playground,playground_wasm_loader -ErrorAction SilentlyContinue"
        scripts = tempfile.mkdtemp(prefix="proof-windows-run-")

        def powershell_string(value):
            # ASCII only, whatever the console's code page: other characters
            # as [char] codes ("Pokédex").
            return '"' + "".join(c if ord(c) < 128 and c not in '"$`' else f"$([char]0x{ord(c):X})" for c in value) + '"'

        # The foreground window's visible bounds (DWM's, without the shadow)
        # within the desktop's work area (the screen less the taskbar), read
        # in the desktop's session as the launch is: what a screenshot is
        # cropped to, so the taskbar's clock and the wallpaper don't count. A
        # window taller than the screen reaches behind the taskbar.
        rect_script = os.path.join(scripts, "rect.ps1")
        open(rect_script, "w").write("\r\n".join([
            'Add-Type @"',
            "using System; using System.Runtime.InteropServices;",
            "public static class ProofWindow {",
            '  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();',
            '  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr w, int a, out Rect r, int s);',
            '  [DllImport("user32.dll")] public static extern bool SystemParametersInfo(int a, int b, ref Rect r, int c);',
            "  [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L, T, R, B; }",
            "}",
            '"@',
            "$r = New-Object ProofWindow+Rect",
            "[ProofWindow]::DwmGetWindowAttribute([ProofWindow]::GetForegroundWindow(), 9, [ref]$r, 16) | Out-Null",
            "$w = New-Object ProofWindow+Rect",
            "[ProofWindow]::SystemParametersInfo(0x30, 0, [ref]$w, 0) | Out-Null",
            '"$([Math]::Max($r.L, $w.L)) $([Math]::Max($r.T, $w.T)) $([Math]::Min($r.R, $w.R)) $([Math]::Min($r.B, $w.B))" | Set-Content C:\\proof\\rect.txt',
        ]) + "\r\n")
        scp(env, rect_script, "C:/proof/rect.ps1")

        def window_box():
            ps("if (Test-Path C:\\proof\\rect.txt) { Remove-Item C:\\proof\\rect.txt }; "
               "schtasks /create /f /tn IsomerProofRect /tr 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\\proof\\rect.ps1' "
               "/sc once /st 23:59 /ru runner /it | Out-Null; schtasks /run /tn IsomerProofRect | Out-Null", check=False)
            for _ in range(10):
                time.sleep(1)
                found = ssh(env, "if (Test-Path C:\\proof\\rect.txt) { Get-Content C:\\proof\\rect.txt }", check=False).stdout.split()
                if len(found) == 4:
                    return tuple(map(int, found))
            return None

        def launcher(app, environment, wait, path):
            # The logged-in desktop session runs it (SSH's has no desktop),
            # through a task: a script of its own, copied in, sets the
            # environment and starts the app.
            script = os.path.join(scripts, "run.ps1")
            open(script, "w").write("\r\n".join(
                [f"Set-Location C:\\proof\\{app}"]
                + [f"$env:{k} = {powershell_string(v)}" for k, v in environment.items()]
                + [f"Start-Process .\\{executables[app]}"]) + "\r\n")
            scp(env, script, "C:/proof/run.ps1")
            ps(f"{stop}; "
               "schtasks /create /f /tn IsomerProof /tr 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\\proof\\run.ps1' "
               "/sc once /st 23:59 /ru runner /it | Out-Null; schtasks /run /tn IsomerProof | Out-Null")
            time.sleep(wait)
            shoot(path)

        def shoot(path):
            oss_shot(env, path)
            box = window_box()
            if box:
                crop(path, box)

        # The first launch after packaging is scanned by Windows first: longer.
        launcher("storybook", {}, 30, os.path.join(tempfile.mkdtemp(), "warm.png"))
        launcher("playground", {}, 30, os.path.join(tempfile.mkdtemp(), "warm.png"))
        control = "C:\\proof\\storybook-control.txt"
        ps(f"if (Test-Path {control}.shown) {{ Remove-Item {control}.shown }}", check=False)
        switcher = Switcher(start=lambda path: launcher("storybook", {"ISO_STORYBOOK_CONTROL": control}, 12, path),
                            request=lambda story: ps(f"Set-Content -NoNewline -Path {control} -Value '{story}'"),
                            shown=lambda: ps(f"if (Test-Path {control}.shown) {{ Get-Content {control}.shown }}", check=False).stdout.strip(),
                            shoot=shoot, settle=2.0)
        shoot_apps(review, "windows", "Windows 11 (VM, ARM64)", "landscape", launcher, story_list,
                   {"open": 12, "story": 10, "run": 60}, switcher)
        ps(stop, check=False)
    finally:
        release(env)


PLATFORMS = {
    "ios": (build_ios, ios), "macos": (build_macos, macos), "android": (build_android, android),
    "web": (None, web), "linux": (build_linux, linux), "windows": (build_windows, windows),
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("platforms", nargs="*", default=list(PLATFORMS))
    parser.add_argument("--review", required=True)
    parser.add_argument("--commit", default=sh(["git", "rev-parse", "HEAD"]).stdout.strip())
    parser.add_argument("--version", default=None)
    parser.add_argument("--stories", default="", help="story ids, comma-separated (default: every story)")
    parser.add_argument("--quick", action="store_true",
                        help="a pull request's proof: QUICK_STORIES and the stories in story files changed from --base")
    parser.add_argument("--base", default="origin/main", help="what --quick compares with (default origin/main)")
    parser.add_argument("--web-toolchain", default=None,
                        help="a staged in-browser compiler (an earlier site's playground/toolchain) for the web Playground")
    parser.add_argument("--held", action="append", default=[], metavar="PLATFORM=FILE",
                        help="a lease you hold, its `oss machine lease --exports` output in FILE: used, not released")
    args = parser.parse_args()
    held.update(item.split("=", 1) for item in args.held)
    version = args.version or re.search(r'version_name = "([^"]+)"', open(os.path.join(
        PLAYGROUND, "android/playground_android_application/BUILD.bazel")).read()).group(1)
    chosen = set(args.stories.split(",")) if args.stories else None
    if args.quick:
        chosen = (chosen or set()) | set(QUICK_STORIES) | changed_stories(args.base)
    story_list = stories(chosen)
    review = Review(args.review, args.commit, version, quick=args.quick)
    log(f"{version} at {args.commit[:10]}: {len(story_list)} stories, platforms {', '.join(args.platforms)}")

    # This Mac's builds first (Bazel runs one command a workspace at a time);
    # Linux's and Windows' are made where they run, so in their threads.
    builds = {}
    for name in args.platforms:
        make, _ = PLATFORMS[name]
        if name == "web":
            if not args.web_toolchain:
                raise SystemExit("the web needs --web-toolchain (an earlier site's playground/toolchain)")
            builds[name] = lambda toolchain=os.path.abspath(args.web_toolchain): build_web(toolchain)
        elif name in ("linux", "windows"):
            builds[name] = make
        else:
            log(f"building {name}")
            built = make()
            builds[name] = lambda built=built: built

    def run(name):
        try:
            PLATFORMS[name][1](review, story_list, builds[name]())
        except BaseException as error:
            with lock:
                failures.append(f"{name}: {error}")
            log(f"FAILED: {error}")

    threads = [threading.Thread(target=run, args=(name,), name=name) for name in args.platforms]
    for thread in threads: thread.start()
    for thread in threads: thread.join()
    log("done" if not failures else f"{len(failures)} missing or failed: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
