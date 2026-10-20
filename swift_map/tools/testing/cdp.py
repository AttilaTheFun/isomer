#!/usr/bin/env python3
"""Minimal CDP driver for headless Chrome: navigate, click (trusted input
events), type, evaluate JS, screenshot. Stdlib only (raw WebSocket client).

This exists because synthetic MouseEvent dispatch and --virtual-time-budget
screenshots are unreliable against the React renderer (React 18 event
delegation): CDP Input.dispatchMouseEvent sends *trusted* events in real
time, which is the only thing that clicks reliably. WebGPU works headless
via --enable-unsafe-webgpu. The profile dir /tmp/iso-cdp-profile caches
aggressively — `rm -rf` it if you see a stale build.

Usage:
  cdp.py <url> <out.png> [wait=SECONDS] [click=X,Y ...] [type=TEXT] [eval=JS] [width=W] [height=H]
Steps run in argv order; `wait` sleeps, `click` sends a real mouse press+release.
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

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PORT = 9223


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

    chrome = subprocess.Popen(
        [CHROME, "--headless=new", "--enable-unsafe-webgpu", "--enable-features=Vulkan",
         f"--remote-debugging-port={PORT}",
         f"--window-size={width},{height}", "--user-data-dir=/tmp/iso-cdp-profile",
         "about:blank"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(50):
            try:
                targets = json.loads(urllib.request.urlopen(
                    f"http://127.0.0.1:{PORT}/json/list", timeout=1).read())
                page = next(t for t in targets if t["type"] == "page")
                break
            except Exception:
                time.sleep(0.3)
        ws = WS(page["webSocketDebuggerUrl"])
        ws.send("Page.enable")
        ws.send("Emulation.setDeviceMetricsOverride",
                {"width": width, "height": height, "deviceScaleFactor": 1, "mobile": False})
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
            elif s.startswith("type="):
                for ch in s.split("=", 1)[1]:
                    ws.send("Input.dispatchKeyEvent", {"type": "char", "text": ch})
                    time.sleep(0.03)
            elif s.startswith("eval="):
                result = ws.send("Runtime.evaluate",
                                 {"expression": s.split("=", 1)[1], "returnByValue": True})
                print("EVAL:", json.dumps(result.get("result", {}).get("value"))[:600])
        shot = ws.send("Page.captureScreenshot", {"format": "png"})
        with open(out, "wb") as fh:
            fh.write(base64.b64decode(shot["data"]))
        print("saved", out)
    finally:
        chrome.terminate()
        chrome.wait()


if __name__ == "__main__":
    main()
