# Stuck-prompt detector hook

Three Claude Code hooks that count tool calls per user prompt and intervene
when an agent thrashes:

- **`reset.sh`** — `UserPromptSubmit` event. Zeros the per-session counter
  whenever you submit a new prompt.
- **`check.sh`** — `PreToolUse` event. Increments the counter and decides:
  - count < `CC_STUCK_WARN` (default 20) → silent, allow
  - count ≥ `CC_STUCK_WARN`               → stderr warning, allow
  - count ≥ `CC_STUCK_DENY` (default 40)  → JSON `permissionDecision: deny`
- **`cleanup.sh`** — `Stop` event. Removes the per-session state file.

State lives at `${CC_STUCK_STATE_DIR:-/tmp/claude-stuck}/<session_id>.count`.

## Install

```bash
./install.sh
```

Backs up `~/.claude/settings.json` and merges the three hooks into it.
Idempotent — re-running it won't duplicate entries. Restart your interactive
`claude` session afterwards.

## Tune

```bash
export CC_STUCK_WARN=15   # warn earlier
export CC_STUCK_DENY=30   # hard-stop earlier
```

Set these in your shell rc *before* `source claude-otel.env && claude`.

## Uninstall

```bash
cp ~/.claude/settings.json.bak-<timestamp> ~/.claude/settings.json
```

Backups are written by `install.sh` on every run.

## What "deny" looks like

When the deny threshold trips, Claude sees:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "Stuck-turn detector: 41 tool calls in this prompt..."
  }
}
```

The current tool call is blocked. Claude will either ask you for guidance or
stop. You can then `Esc → /clear → re-prompt` with a tighter scope.
