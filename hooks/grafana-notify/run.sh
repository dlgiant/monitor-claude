#!/usr/bin/env bash
# Start the Grafana → desktop-notification webhook receiver.
# Backgrounds the process and writes its log to /tmp/grafana-notify.log.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if pgrep -f notify-receiver.py >/dev/null; then
  echo "already running — pid $(pgrep -f notify-receiver.py)"
  exit 0
fi

nohup python3 ./notify-receiver.py >/tmp/grafana-notify.log 2>&1 &
disown $!
sleep 0.5
pid="$(pgrep -f notify-receiver.py | head -1)"
echo "started — pid $pid, log /tmp/grafana-notify.log"
echo "stop with: pkill -f notify-receiver.py"
