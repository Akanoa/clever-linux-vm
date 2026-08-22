#!/usr/bin/env python3
"""Status and federation endpoint on 0.0.0.0:8080.

The Clever Cloud linux runtime only considers an instance healthy once
something answers on port 8080, and 8080 is also the *only* port the
platform exposes - arbitrary ports are not routed between instances, on
either the public or the private address. So this doubles as the fleet's
inter-VM channel: every box is reachable from every other at
https://app-<id>.cleverapps.io over TLS, with no SSH key on the Clever
account and no port arithmetic.

Everything except `/` requires the fleet token, because that URL is
public to the internet.
"""
import json
import os
import shutil
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

STATE_FILE = os.environ.get("STATE_FILE", "/tmp/vm-agent-state")
BOOT_LOG = os.environ.get("BOOT_LOG", "/tmp/vm-agent-boot.log")
VM_NAME = os.environ.get("VM_AGENT_NAME", "vm-agent")
FLEET_TOKEN = os.environ.get("VM_AGENT_FLEET_TOKEN", "")
TOOLS = ["herdr", "claude", "opencode", "codex", "gh", "glab", "git", "s3cmd"]
MAX_BODY = 64 * 1024

HOME = os.path.expanduser("~")
SEARCH_PATH = os.pathsep.join([
    os.path.join(HOME, ".local/bin"),
    os.path.join(HOME, ".opencode/bin"),
    os.environ.get("PATH", ""),
])


def which(tool):
    return shutil.which(tool, path=SEARCH_PATH)


def herdr(*args, timeout=30):
    """Run a herdr subcommand and return its JSON, never through a shell."""
    exe = which("herdr")
    if not exe:
        return 503, {"error": "herdr is not installed on this VM"}
    try:
        proc = subprocess.run([exe, *args], capture_output=True, text=True,
                              timeout=timeout)
    except subprocess.TimeoutExpired:
        return 504, {"error": "herdr timed out", "argv": list(args)}
    out = (proc.stdout or "").strip()
    try:
        return (200 if proc.returncode == 0 else 500), json.loads(out)
    except (ValueError, TypeError):
        return (200 if proc.returncode == 0 else 500), {
            "output": out,
            "stderr": (proc.stderr or "").strip(),
            "exit": proc.returncode,
        }


def read_stage():
    try:
        with open(STATE_FILE) as fh:
            return fh.read().strip()
    except OSError:
        return "starting"


def agent_auth():
    """Which agents have credentials, without ever revealing them."""
    if os.environ.get("CLAUDE_CODE_OAUTH_TOKEN"):
        claude = "subscription-token"
    elif os.environ.get("ANTHROPIC_API_KEY"):
        claude = "api-key"
    elif os.path.exists(os.path.join(HOME, ".claude/.credentials.json")):
        claude = "session"
    else:
        claude = None

    if os.path.exists(os.path.join(HOME, ".codex/auth.json")):
        codex = "logged-in"
    elif os.environ.get("OPENAI_API_KEY"):
        codex = "api-key"
    else:
        codex = None

    providers = [name for name, var in (
        ("anthropic", "ANTHROPIC_API_KEY"),
        ("openai", "OPENAI_API_KEY"),
        ("openrouter", "OPENROUTER_API_KEY"),
    ) if os.environ.get(var)]
    if not providers and os.path.exists(
            os.path.join(HOME, ".local/share/opencode/auth.json")):
        providers = ["stored-credentials"]

    return {"claude": claude, "codex": codex, "opencode": providers or None}


def status_payload():
    return {
        "vm": VM_NAME,
        "app": os.environ.get("CC_APP_NAME", "vm-agent"),
        "instance": os.environ.get("CC_PRETTY_INSTANCE_NAME"),
        "deployment": os.environ.get("CC_DEPLOYMENT_ID"),
        "stage": read_stage(),
        "ready": read_stage() == "ready",
        "persistent_storage": os.path.ismount(os.environ.get(
            "PERSIST_ROOT", os.path.join(os.environ.get("APP_HOME", "~"),
                                         "persistent"))),
        "tools": {tool: which(tool) for tool in TOOLS},
        "agent_auth": agent_auth(),
        "federation": bool(FLEET_TOKEN),
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "vm-agent"

    # -- plumbing ------------------------------------------------------
    def _send(self, code, body, ctype="application/json"):
        raw = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _json(self, code, obj):
        self._send(code, json.dumps(obj, indent=2) + "\n")

    def _authorised(self):
        # Fail closed: with no token configured nothing but / is reachable,
        # so a half-provisioned box never exposes its logs to the internet.
        if not FLEET_TOKEN:
            self._json(503, {"error": "federation token not configured"})
            return False
        header = self.headers.get("Authorization", "")
        presented = header[7:] if header.startswith("Bearer ") else ""
        if not presented:
            presented = self.headers.get("X-Fleet-Token", "")
        # Constant-time-ish: compare full strings, not prefixes.
        if presented != FLEET_TOKEN:
            self._json(401, {"error": "unauthorised"})
            return False
        return True

    def _body(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return None
        if length <= 0 or length > MAX_BODY:
            return None
        try:
            return json.loads(self.rfile.read(length).decode())
        except (ValueError, UnicodeDecodeError):
            return None

    # -- routes --------------------------------------------------------
    def do_GET(self):
        url = urlparse(self.path)
        parts = [p for p in url.path.split("/") if p]
        query = parse_qs(url.query)

        # Unauthenticated: the platform's own health probe.
        if not parts:
            return self._json(200, {"ok": True, "vm": VM_NAME,
                                    "ready": read_stage() == "ready"})

        if not self._authorised():
            return

        if parts == ["status"]:
            return self._json(200, status_payload())

        if parts == ["logs"]:
            try:
                with open(BOOT_LOG) as fh:
                    return self._send(200, fh.read(), "text/plain; charset=utf-8")
            except OSError:
                return self._json(404, {"error": "no boot log yet"})

        if parts == ["agents"]:
            return self._json(*herdr("agent", "list"))

        if parts == ["panes"]:
            return self._json(*herdr("pane", "list"))

        if len(parts) == 2 and parts[0] == "agents":
            return self._json(*herdr("agent", "get", parts[1]))

        if len(parts) == 3 and parts[0] == "agents" and parts[2] == "read":
            source = (query.get("source") or ["recent"])[0]
            if source not in ("visible", "recent", "recent-unwrapped", "detection"):
                return self._json(400, {"error": f"bad source: {source}"})
            return self._json(*herdr("agent", "read", parts[1], "--source", source))

        self._json(404, {"error": "not found", "path": url.path})

    def do_POST(self):
        parts = [p for p in urlparse(self.path).path.split("/") if p]
        if not self._authorised():
            return

        body = self._body()
        if body is None or not isinstance(body, dict):
            return self._json(400, {"error": "expected a JSON object body"})

        if len(parts) == 3 and parts[0] == "agents" and parts[2] == "prompt":
            text = body.get("text")
            if not isinstance(text, str) or not text:
                return self._json(400, {"error": "'text' must be a non-empty string"})
            return self._json(*herdr("agent", "prompt", parts[1], text, timeout=60))

        if len(parts) == 3 and parts[0] == "agents" and parts[2] == "keys":
            keys = body.get("keys")
            if not isinstance(keys, list) or not keys or \
                    not all(isinstance(k, str) and k for k in keys):
                return self._json(400, {"error": "'keys' must be a non-empty list of strings"})
            return self._json(*herdr("agent", "send-keys", parts[1], *keys))

        self._json(404, {"error": "not found", "path": self.path})

    def log_message(self, *args):  # keep the platform log readable
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
