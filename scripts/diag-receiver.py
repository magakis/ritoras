#!/usr/bin/env python3
"""
Diagnostic log receiver for the Ritoras iOS keyboard.

Receives HTTP POST log lines from the keyboard extension and appends them
to /tmp/keyboard-diag.log. Used when iOS privacy filters block print()
output from being captured via libimobiledevice / pymobiledevice3 syslog.

Usage:
    python3 scripts/diag-receiver.py
    # (then exercise the keyboard on your iPhone — log lines stream in)
    # (in another terminal)
    tail -f /tmp/keyboard-diag.log
    # or
    cat /tmp/keyboard-diag.log

The keyboard POSTs to http://<your-lan-ip>:8766/log. This script listens
on 0.0.0.0:8766 to receive those POSTs. Adjust the port below if needed.

No external dependencies — uses only Python 3 standard library.
"""
import sys
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler

LOG_FILE = "/tmp/keyboard-diag.log"
LISTEN_HOST = "0.0.0.0"
LISTEN_PORT = 8766


class DiagHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            length = int(self.headers.get("content-length", 0))
            body = self.rfile.read(length).decode("utf-8", errors="replace")
        except Exception as e:
            body = f"<failed to read body: {e}>"

        # Write to log file
        try:
            with open(LOG_FILE, "a", encoding="utf-8") as f:
                f.write(body + "\n")
        except Exception as e:
            print(f"[receiver] failed to write to {LOG_FILE}: {e}", file=sys.stderr)

        # Echo to stdout for live monitoring
        print(body, flush=True)

        # Respond 200 OK (keyboard ignores response anyway)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(b"ok\n")

    def do_OPTIONS(self):
        # CORS preflight — keyboard's URLSession may send this
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def log_message(self, format, *args):
        # Suppress default request logging — keep stdout clean
        pass


def main():
    # Truncate log on startup so we don't accumulate stale entries across runs
    try:
        with open(LOG_FILE, "w", encoding="utf-8") as f:
            f.write(f"# diag-receiver started {datetime.now().isoformat()}\n")
    except Exception as e:
        print(f"[receiver] failed to initialize {LOG_FILE}: {e}", file=sys.stderr)
        sys.exit(1)

    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), DiagHandler)
    print(f"Listening on http://{LISTEN_HOST}:{LISTEN_PORT}")
    print(f"Logging to {LOG_FILE}")
    print(f"(truncate-on-startup: any prior contents wiped)")
    print(f"Press Ctrl+C to stop.")
    print()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping.", file=sys.stderr)
        server.server_close()


if __name__ == "__main__":
    main()
