#!/usr/bin/env python3
"""
Tiny webhook receiver for Grafana alert notifications.

Listens on 127.0.0.1:5678 and converts each Grafana webhook POST into a
desktop notification via `notify-send`. Designed for personal use — no auth,
no TLS, no persistence.

Run with:
    python3 notify-receiver.py

Or in background:
    nohup python3 notify-receiver.py > /tmp/grafana-notify.log 2>&1 &
"""
import http.server
import json
import shutil
import subprocess
import sys

PORT = 5678
# Bind to 0.0.0.0 so the Grafana container can reach us via host.docker.internal
# (which resolves to the docker0 bridge gateway, not 127.0.0.1). Without this,
# the container gets "connection refused".
BIND = "0.0.0.0"
# Peer IPs allowed to POST. Localhost + the default docker bridge gateway and
# the broader 172.16.0.0/12 docker-managed range. Anything else gets a 403.
ALLOWED_PREFIXES = ("127.", "172.")
HAS_NOTIFY_SEND = shutil.which("notify-send") is not None


def notify(title: str, body: str, urgency: str = "critical") -> None:
    line = f"[{urgency}] {title} :: {body}"
    print(line, flush=True)
    if HAS_NOTIFY_SEND:
        subprocess.run(
            ["notify-send", "-u", urgency, "-a", "Claude Code", title, body],
            check=False,
        )


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Quiet the default per-request log line.
        return

    def do_POST(self):
        peer = self.client_address[0]
        if not any(peer.startswith(p) for p in ALLOWED_PREFIXES):
            self.send_response(403)
            self.end_headers()
            return
        length = int(self.headers.get("content-length", 0))
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        # Grafana sends an "alerts" array per delivery. Each alert has
        # status (firing/resolved), labels, annotations, valueString, etc.
        for alert in body.get("alerts", []) or [body]:
            status = alert.get("status", "firing")
            labels = alert.get("labels", {}) or {}
            anns = alert.get("annotations", {}) or {}
            title = anns.get("summary") or labels.get("alertname") or "Grafana alert"
            desc = anns.get("description") or alert.get("valueString") or ""
            urgency = "critical" if status == "firing" else "low"
            notify(f"{status.upper()}: {title}", desc, urgency=urgency)

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"ok":true}')


def main() -> int:
    server = http.server.HTTPServer((BIND, PORT), Handler)
    print(f"grafana-notify listening on http://{BIND}:{PORT}/  "
          f"(notify-send: {'yes' if HAS_NOTIFY_SEND else 'NO — install libnotify-bin'}; "
          f"peer allowlist: {ALLOWED_PREFIXES})",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("shutting down")
    return 0


if __name__ == "__main__":
    sys.exit(main())
