#!/usr/bin/env bash
# Stop hook — removes per-session state files when a session ends.

set -euo pipefail
STATE_DIR=${CC_STUCK_STATE_DIR:-/tmp/claude-stuck}

input="$(cat)"
session_id="$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null || echo "")"
[ -z "$session_id" ] && exit 0

rm -f "$STATE_DIR/$session_id.count"
exit 0
