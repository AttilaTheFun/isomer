#!/bin/sh
# Shireworks' REST API for CI (docs/no-oss.md): what a job does with a
# machine, in place of the `oss` command. Every repository's CI copies this
# file byte for byte from AttilaTheFun/shireworks, so there is one place to
# fix it. It needs python3 alone (no curl, no jq): the program is below.
#
# Whom it asks, as what:
#   SHIREWORKS_GRANT      a CI job's grant URL (in its runner's environment):
#                         its server, and the job's holder
#   SHIREWORKS_SERVERS    else the first of these (http://host:7480, …), with
#   SHIREWORKS_API_KEY    an application's key, or
#   SHIREWORKS_TOKEN      the server's token and SHIREWORKS_HOLDER (else $USER)
# Until Shireworks 0.3 the OSS_ names of the first two are read too.
#
#   shireworks.sh lease <platform> [--config=…] [--minutes=N] [--label=…] [--kind=…]
#                 [--key=<public key file>] [--image=…] [--cpus=N] [--memory=GB] [--disk=GB]
#                 [--rosetta] [--volume=<name>:<path>[:<GB>[:keep]]]… [--device="iPhone 17 Pro"]
#                 [--runtime=…] [--no-wait] [--json]
#                                  a machine, once it's ready (waiting for room as long as it
#                                  takes, unless --no-wait): its SHIREWORKS_* exports, or JSON
#   shireworks.sh release <id>
#   shireworks.sh list [--label=<text>] [--json]
#                                  the leases you hold (a CI job: its own), those whose label
#                                  holds <text>: a line each, "<id> <platform> <state> <label>"
#   shireworks.sh renew <id> [--minutes=N]
#   shireworks.sh run <id> [--gui] [--cd=<dir>] [--env=K=V …] -- <command…>
#                                  a command on a container or a Mac slot, its output as it
#                                  comes; exits with its status (255: no status came)
#   shireworks.sh put <id> <file> <path> [--mode=755]
#   shireworks.sh get <id> <path> <file>
#   shireworks.sh simctl <id> [--env=NAME=VALUE]… <arguments…>
#                                  an iOS lease's simulator; --env reaches a launched app
#   shireworks.sh adb <id> <arguments…>        an Android lease's emulator
#   shireworks.sh install <id> <sha256>        a stored app, on an iOS lease
#   shireworks.sh screenshot <id> <file.png> [--window=…]
#   shireworks.sh xctest <id> --tests=<file | object> [--host=<file | object>] [--ui] [--gui]
#                 [--only-testing=Class[/method]]… [--junit=<file.xml>] [--result=<file.xcresult.zip>]
#                                  tests on an iOS lease's simulator or a Mac slot (a file here
#                                  is stored first; else a stored object's sha256 or name): xcodebuild's output as it comes, its JUnit and
#                                  zipped result bundle saved if asked; exits with its status
#   shireworks.sh storage-put <file> [--name=…] [--ttl=…]   its JSON (sha256 and all)
#   shireworks.sh cache-token     the Bazel cache's read token (for .netrc: never log it)
#   shireworks.sh files-url <sha256>                        a served file's URL
#   shireworks.sh capabilities
#   shireworks.sh volume-delete <name>         a kept container volume (the token or a key; not a job's grant)
#
# A refusal is printed with its status and the script exits 1.

program=$(cat << 'PYTHON'
import hashlib, http.client, json, os, re, shlex, sys, tempfile, time, urllib.parse, uuid

me = "shireworks.sh"

def die(message, status=1):
    sys.stderr.write(f"{me}: {message}\n")
    sys.exit(status)

def env(name):
    value = os.environ.get("SHIREWORKS_" + name) or os.environ.get("OSS_" + name) or ""
    return value.strip()

# Whom to ask, as what.
grant = env("GRANT")
# The API level this script speaks: a server shows an older client only
# what it knows (no containers below 6, no Mac slots below 17).
API = "22"
headers = {"Shireworks-API": API, "OSS-API": API}
if grant:
    url = urllib.parse.urlsplit(grant)
    token = dict(urllib.parse.parse_qsl(url.query)).get("grant", "")
    if not url.hostname or not token:
        die("SHIREWORKS_GRANT isn't a grant URL")
    server = url
    headers["Authorization"] = "Bearer " + token
else:
    first = re.split(r"[ ,]+", env("SERVERS"))[0]
    if not first:
        die("no server: set SHIREWORKS_GRANT (a CI job has it) or SHIREWORKS_SERVERS")
    server = urllib.parse.urlsplit(first if "://" in first else "http://" + first)
    key = os.environ.get("SHIREWORKS_API_KEY", "").strip()
    secret = os.environ.get("SHIREWORKS_TOKEN", "").strip()
    if key:
        headers["Authorization"] = "Bearer " + key
    elif secret:
        headers["Authorization"] = "Bearer " + secret
        headers["OSS-Holder"] = os.environ.get("SHIREWORKS_HOLDER") or os.environ.get("USER", "")
    else:
        die("no credential: set SHIREWORKS_GRANT, SHIREWORKS_API_KEY or SHIREWORKS_TOKEN")
host = server.hostname
port = server.port or 7480

def connect(timeout=600):
    if server.scheme == "https":
        return http.client.HTTPSConnection(host, port, timeout=timeout)
    return http.client.HTTPConnection(host, port, timeout=timeout)

def request(method, path, body=None, query=None, extra=None, timeout=600):
    """The answer, its body still to read; a refusal ends the script."""
    if query:
        path += "?" + urllib.parse.urlencode(query)
    sent = dict(headers, **(extra or {}))
    if isinstance(body, (dict, list)):
        body = json.dumps(body).encode()
        sent["Content-Type"] = "application/json"
    if body is None and method in ("POST", "PUT"):
        body = b""
    connection = connect(timeout)
    try:
        connection.request(method, path, body=body, headers=sent)
        answer = connection.getresponse()
    except OSError as error:
        raise Unanswered(f"{host}:{port} didn't answer: {error}")
    if not 200 <= answer.status < 300:
        refusal(answer)
    return answer

class Unanswered(Exception):
    pass

class Refused(Exception):
    def __init__(self, status, message, code):
        super().__init__(message)
        self.status, self.message, self.code = status, message, code

def refusal(answer):
    text = answer.read().decode(errors="replace")
    try:
        parsed = json.loads(text)
        message, code = parsed.get("error", text), parsed.get("code")
    except ValueError:
        message, code = text.strip(), None
    raise Refused(answer.status, message, code)

def call(method, path, body=None, query=None):
    """The answer's JSON."""
    data = request(method, path, body, query).read()
    return json.loads(data) if data.strip() else None

def option(arguments, name, default=None):
    for argument in arguments:
        if argument.startswith(f"--{name}="):
            return argument.split("=", 1)[1]
    return default

def flag(arguments, name):
    return f"--{name}" in arguments

def positional(arguments, count, usage):
    given = [a for a in arguments if not a.startswith("--")]
    if len(given) != count:
        die("usage: " + usage, 2)
    return given

def lease_path(lease):
    return "/v1/machines/" + urllib.parse.quote(lease, safe="")

# Commands.

def lease(arguments):
    (platform,) = positional(arguments, 1, "lease <platform> [--config=…] [--minutes=N] …")
    body = {"platform": platform}
    if os.environ.get("SHIREWORKS_TOKEN") and not grant and "OSS-Holder" in headers:
        body["holder"] = headers["OSS-Holder"]
    for name in ("config", "label", "kind", "device", "runtime"):
        if option(arguments, name):
            body[name] = option(arguments, name)
    if option(arguments, "minutes"):
        body["minutes"] = int(option(arguments, "minutes"))
    if option(arguments, "key"):
        with open(option(arguments, "key")) as file:
            body["sshPublicKey"] = file.read().strip()
    if platform == "container":
        spec = {"image": option(arguments, "image", "ubuntu:24.04")}
        if option(arguments, "cpus"):
            spec["cpus"] = int(option(arguments, "cpus"))
        if option(arguments, "memory"):
            spec["memoryBytes"] = int(float(option(arguments, "memory")) * (1 << 30))
        if option(arguments, "disk"):
            spec["diskBytes"] = int(float(option(arguments, "disk")) * (1 << 30))
        if flag(arguments, "rosetta"):
            spec["rosetta"] = True
        volumes = []
        for given in (a[len("--volume="):] for a in arguments if a.startswith("--volume=")):
            parts = given.split(":")
            if len(parts) < 2 or not parts[0] or not parts[1].startswith("/"):
                die(f"--volume={given}: <name>:<absolute path>[:<GB>[:keep]]", 2)
            volumes.append({"name": parts[0], "destination": parts[1],
                            "sizeBytes": int(float(parts[2]) * (1 << 30)) if len(parts) > 2 and parts[2] else 16 << 30,
                            "keep": len(parts) > 3 and parts[3] == "keep"})
        if volumes:
            spec["volumes"] = volumes
        body["container"] = spec
    wait = not flag(arguments, "no-wait")
    if wait:
        # The same ticket every time: the server keeps this one's place in line.
        body["waitTicket"] = str(uuid.uuid4())
    unanswered = 0
    while True:
        try:
            made = call("POST", "/v1/machines", body)
            break
        except Refused as error:
            if wait and (error.code in ("busy", "volumeInUse", "restarting") or error.message.startswith("busy")):
                sys.stderr.write(f"{me}: {error.message}; waiting\n")
                time.sleep(15)
                continue
            raise
        except Unanswered as error:
            # A server restarting is back in seconds, and keeps the place in line.
            if not wait or unanswered >= 300:
                raise
            sys.stderr.write(f"{me}: {error}; asking again\n")
            unanswered += 15
            time.sleep(15)
    sys.stderr.write(f"{me}: lease {made['id']}: making {made.get('name', '')}\n")
    current = made
    while current["state"] == "creating":
        time.sleep(3)
        current = call("GET", lease_path(made["id"]))
    if current.get("error"):
        die(f"lease {made['id']} failed: {current['error']}")
    if current["state"] != "ready":
        die(f"lease {made['id']} is {current['state']}")
    if flag(arguments, "json"):
        print(json.dumps(current, indent=2))
    else:
        for name, value in exports(current).items():
            print(f"export {name}={shlex.quote(value)}")

def exports(lease):
    platform = lease["platform"]
    known = os.path.join(tempfile.gettempdir(), f"shireworks-known_hosts-{lease['id']}")
    values = {"ID": lease["id"], "PLATFORM": platform, "CONFIG": lease.get("config", ""), "HOST": host,
              "EXPIRES": lease.get("expires", "")}
    if platform in ("macos", "linux", "windows"):
        ssh_port, user = str(lease.get("sshPort") or 0), lease.get("sshUser") or "runner"
        values.update({"SSH_PORT": ssh_port, "SSH_USER": user,
                       "SSH": f"ssh -p {ssh_port} -o UserKnownHostsFile={known} -o StrictHostKeyChecking=accept-new {user}@{host}",
                       "VNC_PORT": str(lease.get("vncPort") or 0), "VNC_PASSWORD": lease.get("vncPassword") or "",
                       "VNC": f"vnc://{host}:{lease.get('vncPort') or 0}"})
    if platform == "ios":
        values["UDID"] = lease.get("udid") or ""
        if lease.get("device"):
            values["DEVICE"] = lease["device"]
    if platform == "android":
        values.update({"ADB": f"{host}:{lease.get('adbPort') or 0}", "ADB_PORT": str(lease.get("adbPort") or 0)})
    for forwarded in lease.get("ports") or []:
        values[f"PORT_{forwarded['port']}"] = f"{forwarded.get('host') or host}:{forwarded['hostPort']}"
    return {"SHIREWORKS_" + name: value for name, value in values.items()}

def release(arguments):
    (lease,) = positional(arguments, 1, "release <id>")
    request("DELETE", lease_path(lease)).read()

def list_leases(arguments):
    label = option(arguments, "label")
    leases = [l for l in call("GET", "/v1/machines") or [] if not label or label in (l.get("label") or "")]
    if flag(arguments, "json"):
        print(json.dumps(leases, indent=2))
        return
    for l in leases:
        print(f"{l['id']} {l['platform']} {l['state']} {l.get('label') or ''}".rstrip())

def volume_delete(arguments):
    (name,) = positional(arguments, 1, "volume-delete <name>")
    request("DELETE", "/v1/volumes/" + urllib.parse.quote(name, safe="")).read()

def renew(arguments):
    (lease,) = positional(arguments, 1, "renew <id> [--minutes=N]")
    minutes = option(arguments, "minutes")
    renewed = call("POST", lease_path(lease) + "/renew", {"minutes": int(minutes)} if minutes else {})
    print(renewed.get("expires", ""))

# The last line `run` answers with: `shireworks: exit <status>`.
MARKER = b"shireworks: exit "

def held_from(pending):
    """Where the end of `pending` could be the start of the last line: it's held back until more comes."""
    for start in range(max(0, len(pending) - len(MARKER) - 13), len(pending)):
        tail = pending[start:]
        if MARKER.startswith(tail[:len(MARKER)]) and (len(tail) <= len(MARKER) or re.fullmatch(rb"-?\d{0,11}\n?", tail[len(MARKER):])):
            return start
    return len(pending)

def run(arguments):
    if "--" not in arguments:
        die("usage: run <id> [--gui] [--cd=<dir>] [--env=K=V …] -- <command…>", 2)
    split = arguments.index("--")
    options, command = arguments[:split], arguments[split + 1:]
    (lease,) = positional(options, 1, "run <id> [--gui] [--cd=<dir>] [--env=K=V …] -- <command…>")
    if not command:
        die("run: no command after --", 2)
    body = {"arguments": command}
    environment = dict(a[len("--env="):].split("=", 1) for a in options if a.startswith("--env=") and "=" in a[len("--env="):])
    if environment:
        body["environment"] = environment
    if option(options, "cd"):
        body["workingDirectory"] = option(options, "cd")
    if flag(options, "gui"):
        body["gui"] = True
    # No time limit: a command may be quiet for long; the server ends it if this goes.
    answer = request("POST", lease_path(lease) + "/run", body, timeout=None)
    sys.exit(exit_code(streamed(answer)))

def exit_code(status):
    return status if 0 <= status <= 255 else 1

def streamed(answer):
    """The answer's text to stdout as it comes, without its last line: the status it gives."""
    out = sys.stdout.buffer
    pending = b""
    while True:
        data = answer.read1(1 << 16)
        if not data:
            break
        pending += data
        keep = held_from(pending)
        if keep:
            out.write(pending[:keep])
            out.flush()
            pending = pending[keep:]
    found = re.fullmatch(rb"shireworks: exit (-?\d+)\n", pending)
    if not found:
        out.write(pending)
        out.flush()
        die("the command's status never came (the connection ended first)", 255)
    return int(found.group(1))

def stored(given):
    """A stored object: a file here is stored first (its sha256); else as given, a stored object's sha256 or name."""
    if not os.path.isfile(given):
        return given
    return store(given, {"name": os.path.basename(given)})["object"]["sha256"]

def xctest(arguments):
    (lease,) = positional(arguments, 1, "xctest <id> --tests=<file | sha256> [--host=…] [--ui] [--gui] [--only-testing=…]… "
                                         "[--junit=<file>] [--result=<file>]")
    if not option(arguments, "tests"):
        die("xctest: --tests=<the test bundle, zipped, or its stored object's sha256>", 2)
    body = {"tests": stored(option(arguments, "tests"))}
    if option(arguments, "host"):
        body["host"] = stored(option(arguments, "host"))
    if flag(arguments, "ui"):
        body["ui"] = True
    if flag(arguments, "gui"):
        body["gui"] = True
    only = [a.split("=", 1)[1] for a in arguments if a.startswith("--only-testing=")]
    if only:
        body["onlyTesting"] = only
    answer = request("POST", lease_path(lease) + "/xctest/run", body, timeout=None)
    run = answer.getheader("Shireworks-XCTest-Run") or ""
    status = streamed(answer)
    # Its results, whatever the tests said (a failed run has them too).
    for name, what in (("junit", "junit"), ("result", "result")):
        target = option(arguments, name)
        if not target:
            continue
        try:
            save(request("GET", f"{lease_path(lease)}/xctest/{run}/{what}", timeout=3600), target)
        except (Refused, Unanswered) as error:
            sys.stderr.write(f"{me}: no {what} from run {run}: {error}\n")
            status = status or 1
    sys.exit(exit_code(status))

def put(arguments):
    lease, file, path = positional(arguments, 3, "put <id> <file> <path> [--mode=755]")
    query = {"path": path}
    if option(arguments, "mode"):
        query["mode"] = option(arguments, "mode")
    with open(file, "rb") as body:
        size = os.fstat(body.fileno()).st_size
        print(json.dumps(json.loads(request("PUT", lease_path(lease) + "/files", body, query,
                                            {"Content-Type": "application/octet-stream", "Content-Length": str(size)},
                                            timeout=3600).read()), indent=2))

def get(arguments):
    lease, path, file = positional(arguments, 3, "get <id> <path> <file>")
    answer = request("GET", lease_path(lease) + "/files", query={"path": path}, timeout=3600)
    save(answer, file)

def save(answer, file):
    partial = file + ".partial"
    with open(partial, "wb") as out:
        while True:
            data = answer.read(1 << 20)
            if not data:
                break
            out.write(data)
    os.replace(partial, file)

def device(tool):
    def command(arguments):
        if not arguments or arguments[0].startswith("--"):
            die(f"usage: {tool} <id> [--env=NAME=VALUE]… <arguments…>", 2)
        rest = arguments[1:]
        # Leading --env=NAME=VALUE: the launched app's environment (simctl's SIMCTL_CHILD_*).
        environment = {}
        while rest and rest[0].startswith("--env=") and "=" in rest[0][len("--env="):]:
            name, value = rest[0][len("--env="):].split("=", 1)
            environment[name] = value
            rest = rest[1:]
        body = {"arguments": rest}
        if environment:
            body["environment"] = environment
        result = call("POST", lease_path(arguments[0]) + "/" + tool, body)
        sys.stdout.write(result.get("output", ""))
        sys.stderr.write(result.get("error", ""))
        sys.exit(result.get("status", 1) if 0 <= result.get("status", 1) <= 255 else 1)
    return command

def install(arguments):
    lease, sha256 = positional(arguments, 2, "install <id> <sha256>")
    print(json.dumps(call("POST", lease_path(lease) + "/install", {"object": sha256}), indent=2))

def screenshot(arguments):
    lease, file = positional(arguments, 2, "screenshot <id> <file.png> [--window=…]")
    window = option(arguments, "window")
    save(request("GET", lease_path(lease) + "/screenshot", query={"window": window} if window else None), file)

def storage_put(arguments):
    (file,) = positional(arguments, 1, "storage-put <file> [--name=…] [--ttl=…]")
    query = {k: option(arguments, k) for k in ("name", "ttl") if option(arguments, k)}
    print(json.dumps(store(file, query), indent=2))

def store(file, query):
    """The file in the store (its hash alone if it's there already): the store's answer."""
    digest = hashlib.sha256()
    with open(file, "rb") as body:
        for block in iter(lambda: body.read(1 << 20), b""):
            digest.update(block)
    sha256 = digest.hexdigest()
    sent = {"Content-Type": "application/octet-stream", "Shireworks-SHA256": sha256, "OSS-SHA256": sha256}
    # Stored already: its hash alone.
    try:
        request("HEAD", f"/v1/storage/objects/{sha256}").read()
        return call_put(query, b"", dict(sent, **{"Content-Length": "0"}))
    except Refused as error:
        if error.status != 404 and error.code != "noObject":
            raise
    with open(file, "rb") as body:
        size = os.fstat(body.fileno()).st_size
        return call_put(query, body, dict(sent, **{"Content-Length": str(size)}))

def call_put(query, body, sent):
    return json.loads(request("PUT", "/v1/storage/objects", body, query, sent, timeout=3600).read())

def cache_token(arguments):
    print(call("GET", "/v1/cache")["readToken"])

def files_url(arguments):
    (sha256,) = positional(arguments, 1, "files-url <sha256>")
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        die("files-url: a SHA-256 is 64 lowercase hex digits", 2)
    print(f"http://{host}:{call('GET', '/v1/cache')['port']}/files/sha256/{sha256}")

def capabilities(arguments):
    print(json.dumps(call("GET", "/v1/capabilities"), indent=2))

commands = {"lease": lease, "release": release, "list": list_leases, "volume-delete": volume_delete, "renew": renew, "run": run, "put": put, "get": get,
            "simctl": device("simctl"), "adb": device("adb"), "install": install, "screenshot": screenshot, "xctest": xctest,
            "storage-put": storage_put, "cache-token": cache_token, "files-url": files_url, "capabilities": capabilities}

if len(sys.argv) < 2 or sys.argv[1] not in commands:
    die("usage: shireworks.sh <" + "|".join(commands) + "> … (the file's head says more)", 2)
try:
    commands[sys.argv[1]](sys.argv[2:])
except Refused as error:
    die(f"{error.status}: {error.message}")
except Unanswered as error:
    die(str(error))
except KeyboardInterrupt:
    sys.exit(130)
PYTHON
)
exec python3 -I -c "$program" "$@"
