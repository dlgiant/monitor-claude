#!/usr/bin/env bash
# Background loop. Stop: pkill -f [s]ync.py
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if pgrep -f '[s]ync.py' >/dev/null; then
  echo "already running — pid $(pgrep -f '[s]ync.py')"
  exit 0
fi

nohup python3 ./sync.py >/tmp/agent-flame.log 2>&1 &
disown $!
sleep 0.5
echo "started — pid $(pgrep -f '[s]ync.py' | head -1), log /tmp/agent-flame.log"
