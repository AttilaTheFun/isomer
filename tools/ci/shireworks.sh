#!/bin/sh
# Shireworks' REST API for CI (docs/no-oss.md): what a job does with a
# machine, in place of the `oss` command. Every repository's CI copies this
# file byte for byte from AttilaTheFun/shireworks, so there is one place to
# fix it. It needs python3 alone (no curl, no jq): the program is below.
# Linux CI images have it; a Mac has it with the Command Line Tools.
#
# Whom it asks, as what:
#   SHIREWORKS_GRANT      a CI job's grant URL (in its runner's environment):
#                         its server, and the job's holder
#   SHIREWORKS_SERVERS    else the first of these (http://host:7480, …), with
#   SHIREWORKS_API_KEY    an application's key, or
#   SHIREWORKS_TOKEN      the server's token and SHIREWORKS_HOLDER (else $USER)
#   SHIREWORKS_SESSION    a terminal's session (Settings › Devices › Add a Terminal): the owner's, the admin
#                         commands' and the rest's (2026-11-14: it replaces the admin key)
#   SHIREWORKS_ADMIN_KEY  the admin key, read until it's gone
# Until Shireworks 0.4 the OSS_ names of the first two are read too.
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
#   shireworks.sh fresh-app <id> <bundle id> [--group=<app group>]…
#                                  a Mac slot's app made new for the primary's console user (quit, its container,
#                                  group containers, preferences, saved state and caches removed): a first launch
#   shireworks.sh screenshot <id> <file.png> [--window=…]
#   shireworks.sh xctest <id> --tests=<file | object> [--host=<file | object>] [--ui] [--gui]
#                 [--only-testing=Class[/method]]… [--junit=<file.xml>] [--result=<file.xcresult.zip>] [--attachments=<file.zip>]
#                                  tests on an iOS lease's simulator or a Mac slot (a file here
#                                  is stored first; else a stored object's sha256 or name): xcodebuild's output as it comes, its JUnit,
#                                  zipped result bundle and its tests' attachments (kept for the run, exported, zipped with
#                                  xcresulttool's manifest.json at the top: API 23) saved if asked; exits with its status
#   shireworks.sh storage-put <file> [--name=…] [--ttl=…]   its JSON (sha256 and all)
#   shireworks.sh cache-token     the Bazel cache's read token (for .netrc: never log it)
#   shireworks.sh files-url <sha256>                        a served file's URL
#   shireworks.sh capabilities
#   shireworks.sh sign <file> [--package=ipa|mac|dmg|tool|apk] [--bundle-id=…] [--out=<file>] [--audience=shireworks] [--promote]
#                                  a CI job's build signed on Shireworks' Mac (pure-mac §3): stored, signed as the job's
#                                  GitHub OIDC token allows (the job needs `permissions: id-token: write`; else
#                                  SHIREWORKS_OIDC_TOKEN), and written back (in place unless --out); prints what signed it;
#                                  --promote (a release's run): a tested Alpha's app stamped Production first. An .apk is
#                                  checked (v2 signature, its package its repository's) and described, never re-signed
#
# With SHIREWORKS_ADMIN_KEY (and SHIREWORKS_SERVERS), the admin's:
#   shireworks.sh secret-remove <account>           (admin) a secret forgotten, its Keychain item and its file:
#                                  client/works-builder-app.json|.pem, client/ci-github-app.json|.pem
#   shireworks.sh issues-key-import <file.pem>      (admin) the factory's GitHub App's private key into the Keychain, for the
#                                  issues dispatcher (server.json issuesDispatcher.appID); delete the file after
#   shireworks.sh agent-key-import <file.pem> --app-id=N [--installation=N]
#                                  (admin) the agents' GitHub App's key into the Keychain alone, for
#                                  agent-proxy's GitHub tokens (no installation: agent-proxy finds it); delete the .pem after
#   shireworks.sh agent-proxy-key-set              (admin) agent-proxy's key for this server's API and MCP (an
#                                  agent-scope key: key-create agent-proxy --scope=agent), its value on standard
#                                  input alone, into the Keychain as agent-proxy/shireworks-key
#   shireworks.sh runner-key-import <file.pem> --app-id=N [--repositories=…] [--max-concurrent=N]
#                                  (admin) CI's GitHub App's key into the Keychain alone, its files gone;
#                                  delete the .pem after
#   shireworks.sh agent-secret-set <NAME>          (admin) a secret for the runner's agents (agentRunner.secrets), its
#                                  value on standard input alone, into the Keychain as agents/<NAME>; removed with
#                                  secret-remove agents/<NAME>
#   shireworks.sh relay-token [--new]               (admin) the containers' relay's token, printed alone, once (--new: another),
#                                  for `shireworks.sh relay-token | multipass-agent relay token set`
#   shireworks.sh signing          (admin) what signing holds: identities, profiles, whether the notary key is set
#   shireworks.sh signing-identity-import <file.p12>   (admin) its password read from SHIREWORKS_P12_PASSWORD, else asked
#   shireworks.sh signing-identity-remove <sha1> | signing-profile-import <file> | signing-profile-remove <uuid>
#   shireworks.sh signing-notary-key [<file.p8>]       (admin) the App Store Connect key notarizing uses: the .p8 (else
#                                  APP_STORE_CONNECT_KEY_PATH's), its id and issuer from APP_STORE_CONNECT_KEY_ID and
#                                  APP_STORE_CONNECT_ISSUER_ID (never on the command line, nor printed)
#   shireworks.sh restart [--hold | --now | --cancel] [--reason=…]
#                                  alone: the restart's status; --hold or --now ask for one
#   shireworks.sh files | files-add <sha256> [--name=…] | files-remove <sha256>
#                                  the files every build's downloader trusts, served by their hash
#   shireworks.sh volumes | volume-delete <name>
#   shireworks.sh terminal-session [--name=…]   (the admin key, on the server's Mac) a terminal's session, its line
#                                  `export SHIREWORKS_SESSION=…` printed once, for ~/.zshrc (never to a terminal)
#   shireworks.sh keys | key-create <application> [--scope=agent] | key-rotate <application> | key-revoke <application>
#                                  a made or rotated key is printed once (rotated: the old stops at once)
#   shireworks.sh image-build <platform> <config> [--from=<base config>] [--script=<file | sha256>]
#                 [--copy=<file | sha256>:<path in the machine>]… [--device=…] [--runtime=…] [--api=N] [--tag=…]
#                 [--no-wait]          a layer built on a base, in the server (was `oss image build`; a file
#                                      here is stored first); waited for unless --no-wait
#   shireworks.sh image-builds [<id>]  the builds asked for, or one
#   shireworks.sh components | component-install <id> [--file=<file | sha256>] | component-remove <id>
#                                  what the server's Mac lends, a component at a time (was `oss component`)
#
# A refusal is printed with its status and the script exits 1.

program=$(cat << 'PYTHON'
import hashlib, http.client, ipaddress, json, os, re, shlex, sys, tempfile, time, urllib.parse, uuid

me = "shireworks.sh"

def die(message, status=1):
    sys.stderr.write(f"{me}: {message}\n")
    sys.exit(status)

def env(name):
    value = os.environ.get("SHIREWORKS_" + name) or os.environ.get("OSS_" + name) or ""
    return value.strip()

def origin(text):
    parts = urllib.parse.urlsplit(text if "://" in text else "http://" + text)
    scheme = (parts.scheme or "http").lower()
    return f"{scheme}://{(parts.hostname or '').lower()}:{parts.port or (7445 if scheme == 'https' else 7480)}"

# A terminal's session for `server` (as `sw`'s Token.session(for:)): SHIREWORKS_SESSION_FOR's entry for its origin,
# else SHIREWORKS_SESSION for this computer's loopback (or any server, when there's no SHIREWORKS_SESSION_FOR).
def terminal_session_for(server):
    entries = {}
    for entry in re.split(r"[ ,\n]+", os.environ.get("SHIREWORKS_SESSION_FOR", "").strip()):
        name, _, token = entry.partition("=")
        if token.startswith("sws_"):
            entries[origin(name)] = token
    here = origin(urllib.parse.urlunsplit(server))
    if here in entries:
        return entries[here]
    session = os.environ.get("SHIREWORKS_SESSION", "").strip()
    if not session.startswith("sws_"):
        return ""
    return session if not entries or is_loopback_host(server.hostname) else ""

# localhost, or an address (never a name: 127.0.0.1.evil.com is one) in 127/8, ::1 or ::ffff:127/104.
def is_loopback_host(host):
    host = (host or "").lower().strip("[]")
    if host == "localhost":
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    mapped = getattr(address, "ipv4_mapped", None)
    return address.is_loopback or bool(mapped and mapped.is_loopback)

# Whom to ask, as what.
grant = env("GRANT")
# The API level this script speaks: a server shows an older client only
# what it knows (no containers below 6, no Mac slots below 17).
API = "22"
headers = {"Shireworks-API": API}
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
    key = (terminal_session_for(server) or os.environ.get("SHIREWORKS_API_KEY", "").strip()
           or os.environ.get("SHIREWORKS_ADMIN_KEY", "").strip())
    secret = os.environ.get("SHIREWORKS_TOKEN", "").strip()
    if key:
        headers["Authorization"] = "Bearer " + key
    elif secret:
        headers["Authorization"] = "Bearer " + secret
        headers["Shireworks-Holder"] = os.environ.get("SHIREWORKS_HOLDER") or os.environ.get("USER", "")
    else:
        die("no credential: set SHIREWORKS_GRANT, SHIREWORKS_API_KEY or SHIREWORKS_TOKEN")
host = server.hostname
port = server.port or (7445 if server.scheme == "https" else 7480)

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
    if os.environ.get("SHIREWORKS_TOKEN") and not grant and "Shireworks-Holder" in headers:
        body["holder"] = headers["Shireworks-Holder"]
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
    as_admin()
    request("DELETE", "/v1/volumes/" + urllib.parse.quote(name, safe="")).read()

# The admin's commands: a terminal's session (the owner's) for this server, else the admin key, when it's set (a job's grant
# never is).
def as_admin(required=False):
    admin = terminal_session_for(server) or os.environ.get("SHIREWORKS_ADMIN_KEY", "").strip()
    if admin:
        headers["Authorization"] = "Bearer " + admin
    elif required:
        die("this is the admin's: set SHIREWORKS_SESSION (Settings › Devices › Add a Terminal) and SHIREWORKS_SERVERS", 2)

def secret_remove(arguments):
    (account,) = positional(arguments, 1, "secret-remove <account>")
    as_admin(required=True)
    print(json.dumps(call("DELETE", "/v1/server/secrets/" + account), indent=2))

def issues_key_import(arguments):
    (path,) = positional(arguments, 1, "issues-key-import <file.pem>")
    as_admin(required=True)
    with open(path) as file:
        pem = file.read()
    print(json.dumps(call("PUT", "/v1/server/issues-key", {"pem": pem}), indent=2))

def agent_key_import(arguments):
    (path,) = positional(arguments, 1, "agent-key-import <file.pem> --app-id=N [--installation=N]")
    app_id = option(arguments, "app-id")
    if not (app_id or "").isdigit():
        die("agent-key-import: --app-id=N, the agents' GitHub App's id", 2)
    installation = option(arguments, "installation")
    if installation is not None and not installation.isdigit():
        die("agent-key-import: --installation=N, the App's installation id", 2)
    as_admin(required=True)
    with open(path) as file:
        body = {"appId": int(app_id), "pem": file.read()}
    if installation:
        body["installationId"] = int(installation)
    print(json.dumps(call("PUT", "/v1/server/agent-key", body), indent=2))

def runner_key_import(arguments):
    (path,) = positional(arguments, 1, "runner-key-import <file.pem> --app-id=N [--repositories=a/b,c/d] [--max-concurrent=N]")
    app_id = option(arguments, "app-id")
    if not (app_id or "").isdigit():
        die("runner-key-import: --app-id=N, the CI App's id", 2)
    as_admin(required=True)
    with open(path) as file:
        body = {"appId": int(app_id), "pem": file.read()}
    repositories = option(arguments, "repositories")
    if repositories:
        body["repositories"] = [r for r in repositories.split(",") if r]
    most = option(arguments, "max-concurrent")
    if most:
        body["maxConcurrent"] = int(most)
    print(json.dumps(call("PUT", "/v1/server/runner-key", body), indent=2))

def agent_secret_set(arguments):
    # The value on standard input alone (never the command line): e.g.
    # printf %s "$TOKEN" | shireworks.sh agent-secret-set CLAUDE_CODE_OAUTH_TOKEN
    (name,) = positional(arguments, 1, "agent-secret-set <NAME>  (the value on standard input)")
    as_admin(required=True)
    if sys.stdin.isatty():
        sys.exit("shireworks.sh: agent-secret-set reads the value from standard input (pipe it in)")
    value = sys.stdin.read()
    if value.endswith("\n"):
        value = value[:-1]
    if not value:
        sys.exit("shireworks.sh: no value on standard input")
    print(json.dumps(call("PUT", "/v1/server/agent-secrets/" + name, {"value": value}), indent=2))

def agent_proxy_key_set(arguments):
    # The value on standard input alone (never the command line): e.g.
    # shireworks.sh key-create agent-proxy --scope=agent | shireworks.sh agent-proxy-key-set
    positional(arguments, 0, "agent-proxy-key-set  (the key on standard input)")
    as_admin(required=True)
    if sys.stdin.isatty():
        sys.exit("shireworks.sh: agent-proxy-key-set reads the key from standard input (pipe it in)")
    key = sys.stdin.read().strip()
    if not key:
        sys.exit("shireworks.sh: no key on standard input")
    print(json.dumps(call("PUT", "/v1/server/agent-proxy-key", {"key": key}), indent=2))

def relay_token(arguments):
    as_admin(required=True)
    answer = call("POST", "/v1/server/relay-token", {"new": True} if "--new" in arguments else {})
    sys.stdout.write(answer["token"] + "\n")

def signing(arguments):
    as_admin(required=True)
    print(json.dumps(call("GET", "/v1/signing"), indent=2))

def signing_identity_import(arguments):
    (path,) = positional(arguments, 1, "signing-identity-import <file.p12>")
    as_admin(required=True)
    import base64, getpass
    password = os.environ.get("SHIREWORKS_P12_PASSWORD")
    if password is None:
        password = getpass.getpass(f"{path}'s password: ") if sys.stdin.isatty() else sys.stdin.readline().rstrip("\n")
    with open(path, "rb") as file:
        p12 = base64.b64encode(file.read()).decode()
    print(json.dumps(call("POST", "/v1/signing/identities", {"p12": p12, "password": password}), indent=2))

def signing_identity_remove(arguments):
    (sha1,) = positional(arguments, 1, "signing-identity-remove <sha1>")
    as_admin(required=True)
    print(json.dumps(call("DELETE", "/v1/signing/identities/" + sha1), indent=2))

def signing_profile_import(arguments):
    (path,) = positional(arguments, 1, "signing-profile-import <file>")
    as_admin(required=True)
    with open(path, "rb") as file:
        print(json.dumps(call("POST", "/v1/signing/profiles", file.read()), indent=2))

def signing_profile_remove(arguments):
    (uuid_text,) = positional(arguments, 1, "signing-profile-remove <uuid>")
    as_admin(required=True)
    print(json.dumps(call("DELETE", "/v1/signing/profiles/" + uuid_text), indent=2))

def signing_notary_key(arguments):
    given = [a for a in arguments if not a.startswith("--")]
    if len(given) > 1:
        die("usage: signing-notary-key [<file.p8>]", 2)
    path = given[0] if given else os.environ.get("APP_STORE_CONNECT_KEY_PATH")
    key_id, issuer = os.environ.get("APP_STORE_CONNECT_KEY_ID"), os.environ.get("APP_STORE_CONNECT_ISSUER_ID")
    if not (path and key_id and issuer):
        die("signing-notary-key: needs the .p8 (or APP_STORE_CONNECT_KEY_PATH), APP_STORE_CONNECT_KEY_ID and APP_STORE_CONNECT_ISSUER_ID", 2)
    as_admin(required=True)
    with open(path) as file:
        key = file.read()
    print(json.dumps(call("PUT", "/v1/signing/notary-key", {"key": key, "keyID": key_id, "issuer": issuer}), indent=2))

def restart(arguments):
    as_admin(required=True)
    if flag(arguments, "cancel"):
        print(json.dumps(call("DELETE", "/v1/server/restart"), indent=2))
        return
    # Alone, only the status: a restart is asked for by --hold or --now (a
    # bare one restarted CI by accident once: `oss restart status`'s habit).
    if not (flag(arguments, "hold") or flag(arguments, "now")):
        print(json.dumps(call("GET", "/v1/server/restart"), indent=2))
        return
    body = {}
    if flag(arguments, "hold"):
        body["hold"] = True
    if flag(arguments, "now"):
        body["now"] = True
    if option(arguments, "reason"):
        body["reason"] = option(arguments, "reason")
    print(json.dumps(call("POST", "/v1/server/restart", body), indent=2))

def files(arguments):
    as_admin(required=True)
    for entry in call("GET", "/v1/files") or []:
        print(f"{entry['sha256']}  {entry['bytes']}  {entry['name']}")

def files_add(arguments):
    (sha256,) = positional(arguments, 1, "files-add <sha256> [--name=…]")
    as_admin(required=True)
    body = {"sha256": sha256}
    if option(arguments, "name"):
        body["name"] = option(arguments, "name")
    entry = call("POST", "/v1/files", body)
    print(f"{entry['name']}: {files_url_for(entry['sha256'])}")

def files_remove(arguments):
    (sha256,) = positional(arguments, 1, "files-remove <sha256>")
    as_admin(required=True)
    request("DELETE", "/v1/files/" + sha256).read()

def image_build(arguments):
    platform, config = positional(arguments, 2, "image-build <platform> <config> [--from=…] [--script=<file | sha256>] "
                                                "[--copy=<file | sha256>:<path>]… [--device=…] [--runtime=…] [--api=N] [--tag=…] [--no-wait]")
    as_admin(required=True)
    body = {"platform": platform, "config": config}
    for name in ("from", "device", "runtime", "tag"):
        if option(arguments, name):
            body[name] = option(arguments, name)
    if option(arguments, "api"):
        body["api"] = int(option(arguments, "api"))
    if option(arguments, "script"):
        body["script"] = stored(option(arguments, "script"))
    copies = []
    for given in (a[len("--copy="):] for a in arguments if a.startswith("--copy=")):
        source, _, path = given.rpartition(":")
        if not source or not path:
            die(f"--copy={given}: <file | sha256>:<path in the machine>", 2)
        copies.append({"object": stored(source), "path": path})
    if copies:
        body["copies"] = copies
    build = call("POST", "/v1/images", body)
    print(f"image build {build['id']}: {platform} {config} {build['state']}", flush=True)
    if flag(arguments, "no-wait"):
        return
    # Waited for: a build takes minutes to an hour (its place in the limits first).
    while build["state"] == "running":
        time.sleep(15)
        build = call("GET", f"/v1/images/builds/{build['id']}")
    print(f"image build {build['id']}: {build['state']}" + (f": {build['error']}" if build.get("error") else ""))
    if build["state"] != "succeeded":
        sys.exit(1)

def image_builds(arguments):
    as_admin(required=True)
    given = [a for a in arguments if not a.startswith("--")]
    if given:
        print(json.dumps(call("GET", f"/v1/images/builds/{given[0]}"), indent=2))
        return
    for build in call("GET", "/v1/images/builds") or []:
        line = f"{build['id']} {build['platform']} {build['config']} {build['state']} {build['started']}"
        print(line + (f" {build['error']}" if build.get("error") else ""))

def components(arguments):
    as_admin(required=True)
    for component in call("GET", "/v1/components") or []:
        print(f"{component['id']}\t{component['name']}: {component['state']}" + (f" ({component['detail']})" if component.get("detail") else ""))

def component_install(arguments):
    (component,) = positional(arguments, 1, "component-install <id> [--file=<file | sha256>]")
    as_admin(required=True)
    body = {"file": stored(option(arguments, "file"))} if option(arguments, "file") else {}
    answer = call("POST", "/v1/components/" + urllib.parse.quote(component, safe=""), body)
    # Waited for: it installs in the server.
    while answer["state"] == "installing":
        time.sleep(5)
        answer = next((c for c in call("GET", "/v1/components") or [] if c["id"] == component), answer)
    print(f"{answer['id']}: {answer['state']}" + (f" ({answer['detail']})" if answer.get("detail") else ""))
    if answer["state"] != "installed":
        sys.exit(1)

def component_remove(arguments):
    (component,) = positional(arguments, 1, "component-remove <id>")
    as_admin(required=True)
    print(call("DELETE", "/v1/components/" + urllib.parse.quote(component, safe=""))["state"])

def volumes(arguments):
    as_admin()
    for volume in call("GET", "/v1/volumes") or []:
        print(" ".join(str(volume.get(k, "")) for k in ("name", "kind", "sizeBytes", "lease")).rstrip())

def keys(arguments):
    as_admin(required=True)
    for key in call("GET", "/v1/keys") or []:
        print(f"{key['application']}  {key.get('scope', 'user')}  {key.get('created', '')}")

def key_create(arguments):
    (application,) = positional(arguments, 1, "key-create <application>")
    as_admin(required=True)
    # Never over a key that's there (POST /v1/keys replaces it: the admin's
    # own, made again by mistake, would end at once): that's key-rotate's.
    if any(key.get("application") == application for key in call("GET", "/v1/keys") or []):
        die(f"{application} has a key already: key-rotate {application} makes a new one (the old stops at once)", 2)
    # Shown once: the caller keeps it (never logged).
    body = {"application": application}
    if option(arguments, "scope"):
        body["scope"] = option(arguments, "scope")
    print(call("POST", "/v1/keys", body)["key"])

def terminal_session(arguments):
    # A terminal's session (the owner's), made with the admin key on the server's Mac itself: its line for ~/.zshrc,
    # printed alone and once (never logged). Refused to a terminal: pipe it into what keeps it.
    positional(arguments, 0, "terminal-session [--name=\"This Mac's terminal\"] [--for=https://<this Mac's TLS address>]")
    if sys.stdout.isatty():
        die("terminal-session prints a secret once: pipe it into what keeps it (shireworks.sh terminal-session >> ~/.zshrc)", 2)
    admin = os.environ.get("SHIREWORKS_ADMIN_KEY", "").strip()
    if not admin:
        die("terminal-session is made with the admin key (SHIREWORKS_ADMIN_KEY), on the server's Mac", 2)
    headers["Authorization"] = "Bearer " + admin
    made = call("POST", "/v1/auth/sessions", {"device": option(arguments, "name", "This Mac's terminal")})
    # --for=<the server's address as another computer reaches it (its TLS one)>: that computer's line, its session
    # named for this server; else this computer's own.
    reached = option(arguments, "for")
    if reached:
        print(f'export SHIREWORKS_SESSION_FOR="${{SHIREWORKS_SESSION_FOR:+$SHIREWORKS_SESSION_FOR }}{origin(reached)}={made["token"]}"')
    else:
        print("export SHIREWORKS_SESSION=" + made["token"])

def key_rotate(arguments):
    (application,) = positional(arguments, 1, "key-rotate <application>")
    as_admin(required=True)
    # Shown once: the caller keeps it (never logged).
    print(call("POST", f"/v1/keys/{urllib.parse.quote(application, safe='')}/rotate")["key"])

def key_revoke(arguments):
    (application,) = positional(arguments, 1, "key-revoke <application>")
    as_admin(required=True)
    request("DELETE", f"/v1/keys/{urllib.parse.quote(application, safe='')}").read()

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
                                         "[--junit=<file>] [--result=<file>] [--attachments=<file.zip>]")
    if not option(arguments, "tests"):
        die("xctest: --tests=<the test bundle, zipped, or its stored object's sha256>", 2)
    body = {"tests": stored(option(arguments, "tests"))}
    if option(arguments, "host"):
        body["host"] = stored(option(arguments, "host"))
    if flag(arguments, "ui"):
        body["ui"] = True
    if flag(arguments, "gui"):
        body["gui"] = True
    # --attachments keeps the run's attachments as well as fetching them.
    if option(arguments, "attachments"):
        body["keepAttachments"] = True
    only = [a.split("=", 1)[1] for a in arguments if a.startswith("--only-testing=")]
    if only:
        body["onlyTesting"] = only
    answer = request("POST", lease_path(lease) + "/xctest/run", body, timeout=None)
    run = answer.getheader("Shireworks-XCTest-Run") or ""
    status = streamed(answer)
    # Its results, whatever the tests said (a failed run has them too).
    for name, what in (("junit", "junit"), ("result", "result"), ("attachments", "attachments")):
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
        if tool != "simctl" and rest and rest[0].startswith("--env="):
            die("--env is simctl's (a launched app's environment); adb takes none", 2)
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

def fresh_app(arguments):
    lease, bundle = positional(arguments, 2, "fresh-app <id> <bundle id> [--group=<app group>]…")
    groups = [a.split("=", 1)[1] for a in arguments if a.startswith("--group=")]
    print(json.dumps(call("POST", lease_path(lease) + "/fresh-app", {"bundleID": bundle, "groups": groups}), indent=2))

def screenshot(arguments):
    lease, file = positional(arguments, 2, "screenshot <id> <file.png> [--window=…]")
    window = option(arguments, "window")
    save(request("GET", lease_path(lease) + "/screenshot", query={"window": window} if window else None), file)

def oidc_token(audience):
    """The job's GitHub OIDC token for `audience`: never printed."""
    if os.environ.get("SHIREWORKS_OIDC_TOKEN"):
        return os.environ["SHIREWORKS_OIDC_TOKEN"]
    url, bearer = os.environ.get("ACTIONS_ID_TOKEN_REQUEST_URL"), os.environ.get("ACTIONS_ID_TOKEN_REQUEST_TOKEN")
    if not (url and bearer):
        die("sign: no OIDC token: run it in a GitHub Actions job with `permissions: id-token: write`, or set SHIREWORKS_OIDC_TOKEN", 2)
    import urllib.request
    asked = urllib.request.Request(url + "&audience=" + urllib.parse.quote(audience), headers={"Authorization": "Bearer " + bearer})
    try:
        with urllib.request.urlopen(asked, timeout=60) as answer:
            return json.loads(answer.read())["value"]
    except (OSError, KeyError, ValueError) as error:
        die(f"sign: GitHub gave no OIDC token: {error}")

def sign(arguments):
    (file,) = positional(arguments, 1, "sign <file> [--package=ipa|mac|dmg|tool|apk] [--bundle-id=…] [--out=<file>] [--audience=…]")
    package = option(arguments, "package") or {".ipa": "ipa", ".zip": "mac", ".dmg": "dmg", ".apk": "apk"}.get(os.path.splitext(file)[1])
    if package not in ("ipa", "mac", "dmg", "tool", "apk"):
        die("sign: say what it is: --package=ipa (an iPhone app), mac (a Mac app's .zip), dmg (a disk image), "
            "tool (one command-line executable, zipped alone, with --bundle-id=<its identifier>) "
            "or apk (an Android app, signed by its build: checked, never re-signed)", 2)
    if package == "tool" and not option(arguments, "bundle-id"):
        die("sign: a tool is signed under its identifier: --bundle-id=<identifier>", 2)
    token = oidc_token(option(arguments, "audience", "shireworks"))
    name = os.path.basename(file)
    stored = store(file, {"name": name})
    body = {"object": stored["object"]["sha256"], "package": package, "token": token, "name": "signed-" + name}
    if option(arguments, "bundle-id"):
        body["bundleID"] = option(arguments, "bundle-id")
    # A release's promotion of a tested Alpha: stamped Production, then signed as production (an APK: checked as production).
    if flag(arguments, "promote"):
        body["promote"] = True
    answer = json.loads(request("POST", "/v1/signing/requests", body, timeout=3600).read())
    save(request("GET", "/v1/storage/objects/" + answer["put"]["object"]["sha256"], timeout=3600), option(arguments, "out", file))
    print(json.dumps(answer["result"], indent=2))

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
    sent = {"Content-Type": "application/octet-stream", "Shireworks-SHA256": sha256}
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
    print(files_url_for(sha256))

def files_url_for(sha256):
    return f"http://{host}:{call('GET', '/v1/cache')['port']}/files/sha256/{sha256}"

def capabilities(arguments):
    print(json.dumps(call("GET", "/v1/capabilities"), indent=2))

commands = {"lease": lease, "release": release, "list": list_leases, "volume-delete": volume_delete, "renew": renew,
            "restart": restart, "secret-remove": secret_remove, "relay-token": relay_token, "agent-secret-set": agent_secret_set, "issues-key-import": issues_key_import, "runner-key-import": runner_key_import,
            "agent-key-import": agent_key_import, "agent-proxy-key-set": agent_proxy_key_set,
            "signing": signing, "signing-identity-import": signing_identity_import, "signing-identity-remove": signing_identity_remove,
            "signing-profile-import": signing_profile_import, "signing-profile-remove": signing_profile_remove,
            "signing-notary-key": signing_notary_key, "files": files, "files-add": files_add, "files-remove": files_remove, "volumes": volumes,
            "keys": keys, "key-create": key_create, "terminal-session": terminal_session, "key-rotate": key_rotate, "key-revoke": key_revoke, "run": run, "put": put, "get": get,
            "simctl": device("simctl"), "adb": device("adb"), "install": install, "fresh-app": fresh_app, "screenshot": screenshot, "xctest": xctest,
            "storage-put": storage_put, "sign": sign, "cache-token": cache_token, "files-url": files_url, "capabilities": capabilities,
            "image-build": image_build, "image-builds": image_builds, "components": components,
            "component-install": component_install, "component-remove": component_remove}

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
