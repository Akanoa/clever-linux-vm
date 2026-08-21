#!/usr/bin/env python3
"""Minimal status endpoint on 0.0.0.0:8080.

The Clever Cloud linux runtime only considers an instance healthy once
something answers on port 8080, so this doubles as the liveness probe and
as a way to see how far provisioning got without opening an SSH session.
"""
import json
import os
import shutil
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_FILE = os.environ.get("STATE_FILE", "/tmp/vm-agent-state")
BOOT_LOG = os.environ.get("BOOT_LOG", "/tmp/vm-agent-boot.log")
TOOLS = ["herdr", "claude", "opencode", "codex", "gh", "glab", "git", "s3cmd"]


def read_stage():
    try:
        with open(STATE_FILE) as fh:
            return fh.read().strip()
    except OSError:
        return "starting"


def tool_versions():
    home = os.path.expanduser("~")
    search = os.pathsep.join([
        os.path.join(home, ".local/bin"),
        os.path.join(home, ".opencode/bin"),
        os.environ.get("PATH", ""),
    ])
    return {tool: shutil.which(tool, path=search) for tool in TOOLS}


def payload():
    return {
        "app": os.environ.get("CC_APP_NAME", "vm-agent"),
        "instance": os.environ.get("CC_PRETTY_INSTANCE_NAME"),
        "deployment": os.environ.get("CC_DEPLOYMENT_ID"),
        "stage": read_stage(),
        "ready": read_stage() == "ready",
        "persistent_storage": os.path.ismount(os.environ.get(
            "PERSIST_ROOT",
            os.path.join(os.environ.get("APP_HOME", "~"), "persistent"))),
        "tools": tool_versions(),
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _send(self, code, body, ctype="application/json"):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path.rstrip("/") in ("", "/status"):
            self._send(200, json.dumps(payload(), indent=2) + "\n")
        elif self.path.rstrip("/") == "/logs":
            try:
                with open(BOOT_LOG) as fh:
                    self._send(200, fh.read(), "text/plain; charset=utf-8")
            except OSError:
                self._send(404, "no boot log yet\n", "text/plain")
        else:
            self._send(404, json.dumps({"error": "not found"}) + "\n")

    def log_message(self, *args):  # keep platform logs readable
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
