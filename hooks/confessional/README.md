# Confessional — session-end self-critique

A Claude Code **Stop hook** that, when a session ends, spawns a fresh
`claude` invocation with the just-finished transcript and asks for a
brutally honest one-line verdict. The verdict ships to Loki as a
structured log event (`event_name=self_critique`). The "Confessional"
row of the *Claude Code — Feedback loops* dashboard surfaces it.

## Install

```bash
~/monitor-claude/hooks/confessional/install.sh
```

Then restart your interactive `claude` session.

## What gets logged

```json
{
  "event.name": "self_critique",
  "session_id": "<uuid>",
  "verdict": "clean | wobbly | looped | wrong",
  "summary": "<one sentence root cause>",
  "suggested_fix": "<one sentence — what should be different next time>"
}
```

## Tunables (env)

- `CC_CONFESS_DISABLE=1` — skip the hook entirely
- `CC_CONFESS_MODEL` — model used to critique (default `claude-haiku-4-5-20251001` — cheap, fast)
- `CC_CONFESS_TIMEOUT_S` — wall-clock budget for the critique (default `60`)
- `CC_CONFESS_OTLP` — OTLP HTTP logs endpoint (default `http://localhost:4318`)

## Cost

The critique runs on Haiku 4.5 by default and is capped at ~200KB of
transcript tail. Expect ~$0.001 per session. Override `CC_CONFESS_MODEL`
if you'd like a sterner reviewer (Sonnet/Opus).

## Privacy

The critique itself runs `claude` with `OTEL_SDK_DISABLED=true`, so the
review pass does not double-count in the cost dashboard. Only the
verdict + summary + fix strings hit Loki — never the raw transcript.
