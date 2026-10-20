"""The network probe's server and driver (see BUILD.bazel).

The server answers what NetworkProbe.swift asks over HTTP and WebSockets on
127.0.0.1:18080, standard library only: an echo of each request, a 404,
redirects, a slow answer, gzip, a large body, and a WebSocket endpoint that
echoes, offers a subprotocol, says a handshake's header field, sends a
fragmented message with a ping inside it, a large message, and closes when
asked, keeping what it saw of each close for the app to ask after.

The driver runs it, points the emulator's localhost:18080 at it
(`adb reverse`), installs the probe, launches it `--launches` times
(clearing its data first, so the second launch reads only what the first
left) and prints the report each launch posts to /report. It drives an
emulator only: `--serial` must name one (emulator-5554), never a phone.

    bazel run //android/network_probe_android_application:network_check -- --serial emulator-5554
    bazel run //android/network_probe_wasm_android_application:network_check -- --serial emulator-5554
    bazel run //android/network_probe_android_application:network_check -- --serve-only
"""

import argparse
import base64
import gzip
import hashlib
import http.server
import json
import os
import queue
import struct
import subprocess
import sys
import threading
import time

PORT = 18080
PACKAGE = "dev.isomer.networkprobe"
ACCEPT_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

# What the server saw of the last closes ("echo": the app's answer to the
# server's close; "client": the app's own), each taken by the one request
# that reads it; frames the protocol forbids (a client's unmasked); and the
# probe's reports, one per launch.
closes = {}
violations = []
lock = threading.Lock()
reports = queue.Queue()


def log(line):
    print(line, flush=True)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        log("[server] " + format % args)

    def answer(self, status, body=b"", fields=()):
        self.send_response(status)
        for name, value in fields:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def route(self):
        try:
            self.handle_route()
        except (BrokenPipeError, ConnectionResetError):
            pass  # the app went (a timeout's whole point)

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_PATCH = route

    def handle_route(self):
        path, _, query = self.path.partition("?")
        body = self.body() if not path.startswith("/ws") else b""
        if path == "/echo":
            echo = {
                "method": self.command,
                "path": self.path,
                "headers": {name.lower(): value for name, value in self.headers.items()},
                "body": body.decode("utf-8", "replace"),
            }
            return self.answer(200, json.dumps(echo).encode(), [
                ("Content-Type", "application/json"), ("Set-Cookie", "a=1"), ("Set-Cookie", "b=2")])
        if path == "/missing":
            return self.answer(404, b"not found", [("Content-Type", "text/plain")])
        if path == "/redirect":
            return self.answer(302, b"", [("Location", "/echo?redirected=1")])
        if path == "/redirect303":
            return self.answer(303, b"", [("Location", "/echo?after=303")])
        if path == "/redirect307":
            return self.answer(307, b"", [("Location", "/echo?after=307")])
        if path == "/loop":
            return self.answer(302, b"", [("Location", "/loop")])
        if path == "/slow":
            time.sleep(5)
            return self.answer(200, b"late")
        if path == "/gzip":
            plain = b"compressed hello " * 100
            if "gzip" in (self.headers.get("Accept-Encoding") or ""):
                return self.answer(200, gzip.compress(plain), [("Content-Encoding", "gzip"), ("Content-Type", "text/plain")])
            return self.answer(200, plain, [("Content-Type", "text/plain")])
        if path == "/large":
            return self.answer(200, bytes(i % 251 for i in range(1_000_000)), [("Content-Type", "application/octet-stream")])
        if path == "/report":
            reports.put(body.decode("utf-8", "replace"))
            return self.answer(204)
        if path == "/last-close":
            kind = query.partition("=")[2]
            with lock:
                seen = closes.pop(kind, "none")
            return self.answer(200, seen.encode(), [("Content-Type", "text/plain")])
        if path == "/ws":
            return self.websocket()
        return self.answer(404, b"no such path")

    # MARK: WebSocket

    def websocket(self):
        key = self.headers.get("Sec-WebSocket-Key")
        if (self.headers.get("Upgrade") or "").lower() != "websocket" or not key:
            return self.answer(400, b"not a WebSocket handshake")
        accept = base64.b64encode(hashlib.sha1((key + ACCEPT_GUID).encode()).digest()).decode()
        offered = [p.strip() for p in (self.headers.get("Sec-WebSocket-Protocol") or "").split(",") if p.strip()]
        self.send_response(101)
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        if "probe.v1" in offered:
            self.send_header("Sec-WebSocket-Protocol", "probe.v1")
        self.end_headers()
        self.wfile.flush()
        self.close_connection = True
        if self.headers.get("X-Probe"):
            self.send_frame(0x1, ("header " + self.headers["X-Probe"]).encode())
        while True:
            message = self.read_message()
            if message is None:
                return
            opcode, payload = message
            if opcode == 0x8:
                code = struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else 1005
                with lock:
                    closes["client"] = f"{code} {payload[2:].decode()}"
                self.send_frame(0x8, payload[:2])
                return
            if opcode == 0xA:
                self.send_frame(0x1, b"pong " + payload)
            elif opcode == 0x2:
                self.send_frame(0x2, payload)
            elif payload == b"fragments":
                self.send_frame(0x1, b"frag", fin=False)
                self.send_frame(0x9, b"inside")
                self.send_frame(0x0, b"men", fin=False)
                self.send_frame(0x0, b"ted")
            elif payload == b"large":
                self.send_frame(0x2, bytes(i % 251 for i in range(200_000)))
            elif payload == b"close":
                self.send_frame(0x8, struct.pack(">H", 1001) + b"bye")
                answer = self.read_message()
                if answer and answer[0] == 0x8:
                    code = struct.unpack(">H", answer[1][:2])[0] if len(answer[1]) >= 2 else 1005
                    with lock:
                        closes["echo"] = str(code)
                return
            else:
                self.send_frame(0x1, payload)

    def send_frame(self, opcode, payload, fin=True):
        head = bytes([(0x80 if fin else 0) | opcode])
        length = len(payload)
        if length < 126:
            head += bytes([length])
        elif length < 65536:
            head += bytes([126]) + struct.pack(">H", length)
        else:
            head += bytes([127]) + struct.pack(">Q", length)
        self.wfile.write(head + payload)
        self.wfile.flush()

    def read_frame(self):
        head = self.rfile.read(2)
        if len(head) < 2:
            return None
        fin, opcode = head[0] & 0x80, head[0] & 0x0F
        length = head[1] & 0x7F
        if length == 126:
            length = struct.unpack(">H", self.rfile.read(2))[0]
        elif length == 127:
            length = struct.unpack(">Q", self.rfile.read(8))[0]
        if not head[1] & 0x80:
            with lock:
                violations.append(f"an unmasked client frame (opcode {opcode})")
            mask = None
        else:
            mask = self.rfile.read(4)
        payload = self.rfile.read(length)
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        return bool(fin), opcode, payload

    def read_message(self):
        """The next message (fragments put together) or control frame; pings answered."""
        kind, parts = None, []
        while True:
            frame = self.read_frame()
            if frame is None:
                return None
            fin, opcode, payload = frame
            if opcode == 0x9:
                self.send_frame(0xA, payload)
                continue
            if opcode >= 0x8:
                return opcode, payload
            if opcode != 0x0:
                kind = opcode
            parts.append(payload)
            if fin:
                return kind, b"".join(parts)


def serve(port):
    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log(f"[server] listening on 127.0.0.1:{port}")
    return server


# MARK: The driver


def run(adb, serial, *args, check=True):
    result = subprocess.run([adb, "-s", serial, *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise SystemExit(f"adb {' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout


def launch(adb, serial, package, number, timeout=180):
    """Starts the probe and returns the lines of the report it posts."""
    while not reports.empty():
        reports.get_nowait()
    run(adb, serial, "logcat", "-c")
    run(adb, serial, "shell", "am", "start", "-S", "-n", f"{package}/.MainActivity")
    try:
        return reports.get(timeout=timeout).splitlines()
    except queue.Empty:
        log = run(adb, serial, "logcat", "-d", "-s", "Isomer:*", "IsomerBridge:*", "AndroidRuntime:E", "*:F")
        raise SystemExit(f"launch {number} reported nothing in {timeout} s\n{log}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--serial", help="the emulator to drive (emulator-5554)")
    parser.add_argument("--serve-only", action="store_true", help="run the server until interrupted")
    parser.add_argument("--port", type=int, default=PORT)
    parser.add_argument("--package", default=PACKAGE, help="the probe's package")
    parser.add_argument("--launches", type=int, default=2)
    parser.add_argument("apk", nargs="?")
    parser.add_argument("adb", nargs="?")
    options = parser.parse_args()

    server = serve(options.port)
    if options.serve_only:
        try:
            threading.Event().wait()
        except KeyboardInterrupt:
            pass
        server.shutdown()
        return 0

    if not options.serial or not options.serial.startswith("emulator-"):
        raise SystemExit("--serial must name an emulator (emulator-5554): the probe never runs on a phone")
    # `bazel run` starts in the runfiles' main repository; rlocationpaths are
    # relative to its parent.
    apk = os.path.join("..", options.apk)
    adb = os.path.join("..", options.adb)
    failed = 0
    try:
        run(adb, options.serial, "reverse", f"tcp:{options.port}", f"tcp:{options.port}")
        run(adb, options.serial, "install", "-r", apk)
        run(adb, options.serial, "shell", "pm", "clear", options.package)
        for number in range(1, options.launches + 1):
            lines = launch(adb, options.serial, options.package, number)
            if not any(line.startswith("done launch") for line in lines):
                lines.append("FAIL the report has no summary")
            for line in lines:
                print(f"[launch {number}] {line}", flush=True)
            failed += sum(1 for line in lines if line.startswith("FAIL"))
        with lock:
            for violation in violations:
                print(f"[server] FAIL {violation}")
            failed += len(violations)
    finally:
        run(adb, options.serial, "shell", "am", "force-stop", options.package, check=False)
        run(adb, options.serial, "reverse", "--remove", f"tcp:{options.port}", check=False)
        server.shutdown()
    print("PASS" if failed == 0 else f"FAIL: {failed} checks failed", flush=True)
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
