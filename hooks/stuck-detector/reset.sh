#!/usr/bin/env bash
# UserPromptSubmit hook — resets the per-session tool-call counter when the
# user submits a new prompt.

set -euo pipefail
STATE_DIR=${CC_STUCK_STATE_DIR:-/tmp/claude-stuck}
mkdir -p "$STATE_DIR"

input="$(cat)"
session_id="$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null || echo "")"
[ -z "$session_id" ] && exit 0

echo "0" > "$STATE_DIR/$session_id.count"
exit 0
