#!/usr/bin/env python3
"""Turns monero-lws payment webhooks into pushes that say nothing.

monero-lws calls a webhook with the amount, the transaction id and more.
None of that leaves this container: for a registered token the relay posts
only the token itself to ntfy, on the token's own topic (which Kilonova on
a desktop polls) and on any UnifiedPush topic a phone bound to it.

Two listeners:
  8091  POST /hook/<token>   from monero-lws, inside the compose network only
  8090  POST /bind/<token>   from Kilonova, through the onion service; the
                             body is the UnifiedPush topic on this server's
                             ntfy (an empty body removes the bindings)

Tokens are created by `register` (see ../push-register). Nothing here is
logged: request lines would name the tokens.
"""

import json
import os
import re
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DATA = os.environ.get("KN_RELAY_DATA", "/data")
NTFY = os.environ.get("KN_NTFY", "http://ntfy").rstrip("/")
TOKEN = re.compile(r"^kn[0-9a-f]{32}$")
# ntfy's own rule for topic names.
TOPIC = re.compile(r"^[-_A-Za-z0-9]{1,64}$")
MAX_BOUND = 4
LOCK = threading.Lock()


def token_file(token):
    return os.path.join(DATA, "tokens", token + ".json")


def load(token):
    if not TOKEN.match(token):
        return None
    try:
        with open(token_file(token), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def store(token, entry):
    path = token_file(token)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(entry, f)
    os.replace(tmp, path)


def publish(topic, token, unified):
    url = f"{NTFY}/{topic}" + ("?up=1" if unified else "")
    request = urllib.request.Request(url, data=token.encode(), method="POST")
    try:
        urllib.request.urlopen(request, timeout=10).close()
    except OSError:
        pass  # ntfy down: the wallet still finds the payment when it syncs


def handler(routes):
    class Handler(BaseHTTPRequestHandler):
        server_version = "relay"
        sys_version = ""

        def log_message(self, *args):
            pass

        def do_POST(self):
            parts = self.path.split("?")[0].strip("/").split("/")
            length = min(int(self.headers.get("Content-Length") or 0), 65536)
            body = self.rfile.read(length) if length else b""
            route = routes.get(parts[0]) if len(parts) == 2 else None
            status = route(parts[1], body) if route else 404
            self.send_response(status)
            self.send_header("Content-Length", "0")
            self.end_headers()

    return Handler


def hook(token, _body):
    # The body (amount, transaction id) is read and dropped unseen.
    entry = load(token)
    if entry is None:
        return 404
    publish(token, token, unified=False)
    for topic in entry.get("bound", []):
        publish(topic, token, unified=True)
    return 200


def bind(token, body):
    with LOCK:
        entry = load(token)
        if entry is None:
            return 404
        topic = body.decode("ascii", "replace").strip()
        if not topic:
            entry["bound"] = []
        elif not TOPIC.match(topic) or topic == token:
            return 400
        else:
            bound = [t for t in entry.get("bound", []) if t != topic]
            entry["bound"] = (bound + [topic])[-MAX_BOUND:]
        store(token, entry)
    return 204


def serve(port, routes):
    server = ThreadingHTTPServer(("0.0.0.0", port), handler(routes))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


if __name__ == "__main__":
    os.makedirs(os.path.join(DATA, "tokens"), exist_ok=True)
    serve(8091, {"hook": hook})
    serve(8090, {"bind": bind})
    threading.Event().wait()
