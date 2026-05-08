#!/usr/bin/env bash
# PreToolUse hook — counts tool calls per prompt and intervenes at thresholds.
#
# Reads JSON from stdin (Claude Code hook contract). Writes a JSON
# permissionDecision to stdout when blocking; warns via stderr otherwise.
#
# Tunables via env vars:
#   CC_STUCK_WARN     — soft warning threshold (default 20)
#   CC_STUCK_DENY     — hard-deny threshold (default 40)
#   CC_STUCK_STATE_DIR— where per-session counters live (default /tmp/claude-stuck)

set -euo pipefail

WARN=${CC_STUCK_WARN:-20}
DENY=${CC_STUCK_DENY:-40}
STATE_DIR=${CC_STUCK_STATE_DIR:-/tmp/claude-stuck}
mkdir -p "$STATE_DIR"

input="$(cat)"
session_id="$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("session_id",""))' 2>/dev/null || echo "")"
[ -z "$session_id" ] && exit 0

state_file="$STATE_DIR/$session_id.count"
count="$(cat "$state_file" 2>/dev/null || echo 0)"
count=$((count + 1))
echo "$count" > "$state_file"

if [ "$count" -ge "$DENY" ]; then
  python3 - "$count" "$DENY" <<'PY'
import json, sys
count, deny = sys.argv[1], sys.argv[2]
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason":
            f"Stuck-turn detector: {count} tool calls in this prompt "
            f"(hard-stop threshold {deny}). Press Esc, then /clear and try "
            "a tighter prompt. Override by raising CC_STUCK_DENY."
    }
}))
PY
  exit 0
fi

if [ "$count" -ge "$WARN" ]; then
  echo "[stuck-detector] $count tool calls in this prompt — getting stuck? (warn=$WARN, hard-stop=$DENY)" >&2
fi

exit 0
