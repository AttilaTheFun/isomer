#!/usr/bin/env python3
"""Minimal CDP driver for headless Chrome: navigate, click (trusted input
events), type, evaluate JS, screenshot. Stdlib only (raw WebSocket client).

This exists because synthetic MouseEvent dispatch and --virtual-time-budget
screenshots are unreliable against the React renderer (React 18 event
delegation): CDP Input.dispatchMouseEvent sends *trusted* events in real
time, which is the only thing that clicks reliably. WebGPU works headless
via --enable-unsafe-webgpu. The profile dir /tmp/iso-cdp-profile caches
aggressively — `rm -rf` it if you see a stale build; CDP_PROFILE names
another (a run's own, which a page's stored state can't outlast).

Usage:
  cdp.py <url> <out.png> [wait=SECONDS] [until=JS] [click=X,Y ...] [drag=X1,Y1,X2,Y2] [wheel=X,Y,DY] [type=TEXT] [key=[Shift+]Enter] [eval=JS] [shot=PATH] [width=W] [height=H]
Steps run in argv order; `wait` sleeps, `until` waits (at most 60 s) for a
JS expression to be truthy (the page drawn: `until=window.__isoLastTree`),
`click` sends a real mouse
press+release, `drag` presses, moves in steps, and releases, `wheel` scrolls
by DY at (X,Y) — all trusted input events.
Handy evals against the React renderer (committed hooks in react_renderer.js):
  eval=window.__isoLastTree            # serialized tree JSON
  eval=document.querySelector('[data-tap]')…  # tap targets carry data-tap ids
"""
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import time
import urllib.request

# The Mac's Chrome, else Linux's; CDP_CHROME names another (a Chromium).
CHROME = os.environ.get("CDP_CHROME") or next(
    (path for path in ("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/usr/bin/google-chrome",
                       "/usr/bin/chromium") if os.path.exists(path)),
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")


class WS:
    def __init__(self, url):
        # ws://host:port/path
        rest = url.split("://", 1)[1]
        hostport, path = rest.split("/", 1)
        host, port = hostport.split(":")
        self.sock = socket.create_connection((host, int(port)))
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            (f"GET /{path} HTTP/1.1\r\nHost: {hostport}\r\nUpgrade: websocket\r\n"
             f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
             f"Sec-WebSocket-Version: 13\r\n\r\n").encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.sock.recv(4096)
        self.msg_id = 0

    def send(self, method, params=None):
        self.msg_id += 1
        payload = json.dumps(
            {"id": self.msg_id, "method": method, "params": params or {}}).encode()
        header = bytearray([0x81])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        self.sock.sendall(bytes(header) + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
        return self.wait_for(self.msg_id)

    def recv_frame(self):
        def read(n):
            out = b""
            while len(out) < n:
                chunk = self.sock.recv(n - len(out))
                if not chunk:
                    raise ConnectionError("closed")
                out += chunk
            return out
        b1, b2 = read(2)
        n = b2 & 0x7F
        if n == 126:
            n = struct.unpack(">H", read(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", read(8))[0]
        if b2 & 0x80:
            read(4)
        return read(n)

    def wait_for(self, msg_id, timeout=30):
        self.sock.settimeout(timeout)
        while True:
            msg = json.loads(self.recv_frame())
            if msg.get("id") == msg_id:
                return msg.get("result", msg)
            # Surface page errors/console while waiting (needs Runtime.enable,
            # sent when ISO_CDP_CONSOLE is set).
            method = msg.get("method")
            if method == "Runtime.exceptionThrown":
                detail = msg["params"]["exceptionDetails"]
                text = (detail.get("exception") or {}).get("description") or detail.get("text")
                print("PAGE EXCEPTION:", str(text)[:500])
            elif method == "Runtime.consoleAPICalled":
                args = " ".join(
                    str(a.get("value", a.get("description", "?")))[:200]
                    for a in msg["params"].get("args", []))
                print(f"PAGE CONSOLE[{msg['params'].get('type')}]:", args[:500])


def main():
    url, out = sys.argv[1], sys.argv[2]
    steps = sys.argv[3:]
    width = height = None
    for s in steps:
        if s.startswith("width="):
            width = int(s.split("=", 1)[1])
        if s.startswith("height="):
            height = int(s.split("=", 1)[1])
    width, height = width or 1220, height or 880

    profile = os.environ.get("CDP_PROFILE", "/tmp/iso-cdp-profile")
    # DevTools on a port Chrome picks, read back from the profile: on a fixed
    # one, two drivers at once (another checkout's cdp.py) reached each
    # other's Chrome.
    active_port = os.path.join(profile, "DevToolsActivePort")
    if os.path.exists(active_port):
        os.remove(active_port)
    chrome = subprocess.Popen(
        # No keychain or keyring: Chrome's cookie store waits for Linux's
        # GNOME keyring, locked or out of reach from a shell, and every
        # http(s) page then hangs (the JS drivers pass the same).
        [CHROME, "--headless=new", "--enable-unsafe-webgpu", "--enable-features=Vulkan",
         "--use-mock-keychain", "--password-store=basic",
         "--remote-debugging-port=0",
         f"--window-size={width},{height}",
         "--user-data-dir=" + profile,
         # CDP_CHROME_FLAGS: extra switches (e.g. --disable-features=
         # LocalNetworkAccessChecks to reach a tailnet host from a page).
         *os.environ.get("CDP_CHROME_FLAGS", "").split(),
         "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        port = None
        for _ in range(50):
            try:
                if port is None:
                    port = int(open(active_port).read().split()[0])
                targets = json.loads(urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/json/list", timeout=1).read())
                page = next(t for t in targets if t["type"] == "page")
                break
            except Exception:
                time.sleep(0.3)
        ws = WS(page["webSocketDebuggerUrl"])
        ws.send("Page.enable")
        if os.environ.get("ISO_CDP_CONSOLE"):
            ws.send("Runtime.enable")
        ws.send("Emulation.setDeviceMetricsOverride",
                {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": False})
        # CDP_COLOR_SCHEME=light|dark: the page's prefers-color-scheme,
        # whatever the machine's appearance is (the proof holds it still).
        if os.environ.get("CDP_COLOR_SCHEME"):
            ws.send("Emulation.setEmulatedMedia", {"features": [
                {"name": "prefers-color-scheme", "value": os.environ["CDP_COLOR_SCHEME"]}]})
        ws.send("Page.navigate", {"url": url})
        for s in steps:
            if s.startswith("wait="):
                time.sleep(float(s.split("=", 1)[1]))
            elif s.startswith("click="):
                x, y = (float(v) for v in s.split("=", 1)[1].split(","))
                for kind, count in (("mousePressed", 1), ("mouseReleased", 1)):
                    ws.send("Input.dispatchMouseEvent",
                            {"type": kind, "x": x, "y": y, "button": "left",
                             "clickCount": count})
                time.sleep(0.15)
            elif s.startswith("drag="):
                x1, y1, x2, y2 = (float(v) for v in s.split("=", 1)[1].split(","))
                ws.send("Input.dispatchMouseEvent",
                        {"type": "mousePressed", "x": x1, "y": y1,
                         "button": "left", "clickCount": 1})
                for i in range(1, 13):
                    ws.send("Input.dispatchMouseEvent",
                            {"type": "mouseMoved", "button": "left",
                             "x": x1 + (x2 - x1) * i / 12,
                             "y": y1 + (y2 - y1) * i / 12})
                    time.sleep(0.02)
                ws.send("Input.dispatchMouseEvent",
                        {"type": "mouseReleased", "x": x2, "y": y2,
                         "button": "left", "clickCount": 1})
                time.sleep(0.15)
            elif s.startswith("wheel="):
                x, y, dy = (float(v) for v in s.split("=", 1)[1].split(","))
                ws.send("Input.dispatchMouseEvent",
                        {"type": "mouseWheel", "x": x, "y": y,
                         "deltaX": 0, "deltaY": dy})
                time.sleep(0.15)
            elif s.startswith("type="):
                for ch in s.split("=", 1)[1]:
                    ws.send("Input.dispatchKeyEvent", {"type": "char", "text": ch})
                    time.sleep(0.03)
            elif s.startswith("key="):
                # A named key pressed and released (Enter, Escape, Tab,
                # Backspace, ArrowUp…), with shift/ctrl/alt/meta prefixes
                # joined by "+": key=Shift+Enter.
                *mods, name = s.split("=", 1)[1].split("+")
                codes = {"Enter": 13, "Escape": 27, "Tab": 9, "Backspace": 8,
                         "ArrowUp": 38, "ArrowDown": 40, "ArrowLeft": 37, "ArrowRight": 39}
                bits = {"Alt": 1, "Ctrl": 2, "Meta": 4, "Shift": 8}
                modifiers = sum(bits[m] for m in mods)
                down = {"type": "keyDown", "key": name, "code": name,
                        "windowsVirtualKeyCode": codes.get(name, 0), "modifiers": modifiers}
                if name == "Enter":
                    down["text"] = "\r"
                ws.send("Input.dispatchKeyEvent", down)
                ws.send("Input.dispatchKeyEvent", {"type": "keyUp", "key": name, "code": name,
                                                   "windowsVirtualKeyCode": codes.get(name, 0), "modifiers": modifiers})
                time.sleep(0.1)
            elif s.startswith("shot="):
                # A screenshot mid-run (the final one still goes to <out.png>).
                frame = ws.send("Page.captureScreenshot", {"format": "png"})
                with open(s.split("=", 1)[1], "wb") as fh:
                    fh.write(base64.b64decode(frame["data"]))
            elif s.startswith("until="):
                expression = s.split("=", 1)[1]
                deadline = time.time() + 60
                while time.time() < deadline:
                    result = ws.send("Runtime.evaluate", {"expression": f"!!({expression})", "returnByValue": True})
                    if result.get("result", {}).get("value") is True:
                        break
                    time.sleep(0.25)
                else:
                    print("UNTIL timed out:", expression)
            elif s.startswith("eval="):
                result = ws.send("Runtime.evaluate",
                                 {"expression": s.split("=", 1)[1], "returnByValue": True})
                print("EVAL:", json.dumps(result.get("result", {}).get("value"))[:int(os.environ.get("CDP_EVAL_LIMIT", "600"))])
        shot = ws.send("Page.captureScreenshot", {"format": "png"})
        with open(out, "wb") as fh:
            fh.write(base64.b64decode(shot["data"]))
        print("saved", out)
    finally:
        chrome.terminate()
        chrome.wait()


if __name__ == "__main__":
    main()
