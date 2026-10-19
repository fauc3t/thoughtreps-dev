"""Marker store for scripts/sync-device-integ.sh. Run with `python3 -I scripts/sync-coordinator.py <bind-ip> <token>`.

The two device test runners hand steps to each other through it, because real devices don't share the Mac's filesystem.

    PUT    /<token>/<scenario>/<name>   stores a marker with an optional body (up to 64 KiB), answers 204
    GET    /<token>/<scenario>/<name>   200 with the body, or 404
    DELETE /<token>                     clears every marker, answers 204

Any other token, path or method is a 404 (405 for other methods). In memory only. Binds <bind-ip> on a free port, prints
`URL http://<bind-ip>:<port>/<token>` as its first line, and exits when the process that started it does, so it ends with the script.
"""

import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 64 * 1024
SEGMENT = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")


def make_handler(token, markers):
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, body=b""):
            self.send_response(status)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def marker_key(self):
            parts = self.path.split("?")[0].split("/")
            if len(parts) != 4 or parts[0] != "" or parts[1] != token:
                return None
            if not SEGMENT.match(parts[2]) or not SEGMENT.match(parts[3]):
                return None
            return (parts[2], parts[3])

        def do_PUT(self):
            key = self.marker_key()
            if key is None:
                return self.reply(404)
            try:
                length = int(self.headers.get("Content-Length") or "")
            except ValueError:
                return self.reply(400)
            if length < 0:
                return self.reply(400)
            if length > MAX_BODY:
                return self.reply(413)
            body = self.rfile.read(length) if length else b""
            with lock:
                markers[key] = body
            self.reply(204)

        def do_GET(self):
            key = self.marker_key()
            if key is None:
                return self.reply(404)
            with lock:
                body = markers.get(key)
            self.reply(404) if body is None else self.reply(200, body)

        def do_DELETE(self):
            if self.path.split("?")[0] != "/" + token:
                return self.reply(404)
            with lock:
                markers.clear()
            self.reply(204)

        def do_POST(self):
            self.reply(405)

        do_PATCH = do_POST
        do_HEAD = do_POST

    return Handler


def main():
    if len(sys.argv) != 3 or not SEGMENT.match(sys.argv[2]):
        sys.exit("usage: sync-coordinator.py <bind-ip> <token>")
    ip, token = sys.argv[1], sys.argv[2]
    server = ThreadingHTTPServer((ip, 0), make_handler(token, {}))
    server.daemon_threads = True
    print(f"URL http://{ip}:{server.server_address[1]}/{token}", flush=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    parent = os.getppid()
    while os.getppid() == parent:
        time.sleep(1)


if __name__ == "__main__":
    main()
