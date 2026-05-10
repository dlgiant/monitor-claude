#!/usr/bin/env bash
# Stop hook — at session end, spawn a fresh `claude` with the just-finished
# transcript and a self-critique prompt. Log the verdict to Loki via OTLP so
# the "Confessional" dashboard panel can surface it.
#
# Hook contract: receives JSON on stdin with at least:
#   { "session_id": "...", "transcript_path": "/path/to/.jsonl", ... }
# (See https://docs.claude.com/en/docs/claude-code/hooks for details.)
#
# Tunables (env):
#   CC_CONFESS_DISABLE   — "1" to skip
#   CC_CONFESS_MODEL     — default claude-haiku-4-5-20251001
#   CC_CONFESS_TIMEOUT_S — wall-clock budget (default 60)
#   CC_CONFESS_OTLP      — OTLP HTTP logs endpoint (default http://localhost:4318)

set -euo pipefail

[ "${CC_CONFESS_DISABLE:-0}" = "1" ] && exit 0

MODEL="${CC_CONFESS_MODEL:-claude-haiku-4-5-20251001}"
TIMEOUT_S="${CC_CONFESS_TIMEOUT_S:-60}"
OTLP="${CC_CONFESS_OTLP:-http://localhost:4318}"

input="$(cat)"

read -r session_id transcript_path <<< "$(printf '%s' "$input" | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(d.get("session_id",""), d.get("transcript_path",""))
' 2>/dev/null || echo "")"

[ -z "${session_id:-}" ] && exit 0
[ -z "${transcript_path:-}" ] || [ ! -r "$transcript_path" ] && exit 0

# Run critique in background — Stop hooks should not block CLI shutdown.
(
  prompt='You are reviewing the transcript of a Claude Code session that just ended. Be brutally honest. Output ONE valid JSON object and NOTHING else, with these keys:
  {"verdict": "clean|wobbly|looped|wrong",
   "summary": "<one sentence root cause>",
   "suggested_fix": "<one sentence — what should be different next time>"}
verdict scale:
  clean   = task completed, reasonable steps, accepted edits stuck
  wobbly  = completed but with detours / wasted tools
  looped  = the agent re-read or re-tried the same thing > 3x without progress
  wrong   = produced incorrect output or stopped before finishing
Be terse. No prose, no markdown, no code fences.'

  # Pipe the transcript and prompt to a fresh, ephemeral claude run via stdin.
  # argv would blow past ARG_MAX (~128KB) for any nontrivial transcript.
  # --print: non-interactive single-shot.
  # Disable telemetry + cascade-prevent on the child.
  critique_json="$(
    {
      printf '%s\n\n--- TRANSCRIPT ---\n' "$prompt"
      tail -c 60000 "$transcript_path"
    } | OTEL_SDK_DISABLED=true CC_CONFESS_DISABLE=1 \
        timeout "${TIMEOUT_S}" \
        claude --print --model "$MODEL" 2>/dev/null \
    || echo '{"verdict":"unknown","summary":"critique failed or timed out","suggested_fix":""}'
  )"

  # Parse + sanitize the verdict, then ship as an OTLP log event.
  python3 - "$session_id" "$critique_json" "$OTLP" <<'PY'
import json, os, sys, time, urllib.request

session_id, raw, otlp = sys.argv[1], sys.argv[2], sys.argv[3]

# Try to extract a JSON object from the model's output even if it wrapped it.
def extract(s):
    s = s.strip()
    try:
        return json.loads(s)
    except Exception:
        pass
    a, b = s.find("{"), s.rfind("}")
    if a >= 0 and b > a:
        try:
            return json.loads(s[a:b+1])
        except Exception:
            pass
    return {"verdict": "unknown", "summary": s[:200], "suggested_fix": ""}

c = extract(raw)
verdict = str(c.get("verdict", "unknown"))[:32]
summary = str(c.get("summary", ""))[:500]
fix     = str(c.get("suggested_fix", ""))[:500]

now_ns = int(time.time() * 1e9)
payload = {
  "resourceLogs": [{
    "resource": {"attributes": [
      {"key": "service.name", "value": {"stringValue": "claude-code"}}
    ]},
    "scopeLogs": [{
      "logRecords": [{
        "timeUnixNano": str(now_ns),
        "severityText": "INFO",
        "body": {"stringValue": "claude_code.self_critique"},
        "attributes": [
          {"key": "event.name",   "value": {"stringValue": "self_critique"}},
          {"key": "session_id",   "value": {"stringValue": session_id}},
          {"key": "verdict",      "value": {"stringValue": verdict}},
          {"key": "summary",      "value": {"stringValue": summary}},
          {"key": "suggested_fix","value": {"stringValue": fix}}
        ]
      }]
    }]
  }]
}

req = urllib.request.Request(
    f"{otlp}/v1/logs",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    urllib.request.urlopen(req, timeout=5).read()
except Exception as e:
    sys.stderr.write(f"[confessional] OTLP post failed: {e}\n")
PY
) >/tmp/claude-confessional.log 2>&1 &
disown $!

exit 0
