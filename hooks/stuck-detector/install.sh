#!/usr/bin/env bash
# Installer — merges the stuck-detector hooks into ~/.claude/settings.json.
# Idempotent: safe to re-run. Backs up the existing settings.json.
set -euo pipefail

SETTINGS="${HOME}/.claude/settings.json"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -f "$SETTINGS" ] || { echo "{}" > "$SETTINGS"; }

backup="${SETTINGS}.bak-$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$backup"
echo "backup: $backup"

python3 - "$SETTINGS" "$HOOK_DIR" <<'PY'
import json, sys
settings_path, hook_dir = sys.argv[1], sys.argv[2]

with open(settings_path) as f:
    s = json.load(f)

new_hooks = {
    "PreToolUse": [
        {"matcher": "", "hooks": [{"type": "command", "command": f"{hook_dir}/check.sh"}]}
    ],
    "UserPromptSubmit": [
        {"hooks": [{"type": "command", "command": f"{hook_dir}/reset.sh"}]}
    ],
    "Stop": [
        {"hooks": [{"type": "command", "command": f"{hook_dir}/cleanup.sh"}]}
    ]
}

hooks = s.setdefault("hooks", {})
for event, entries in new_hooks.items():
    arr = hooks.setdefault(event, [])
    for entry in entries:
        cmd = entry["hooks"][0]["command"]
        already = any(
            any(h.get("command") == cmd for h in e.get("hooks", []))
            for e in arr
        )
        if already:
            print(f"  [skip] {event}: {cmd} (already present)")
        else:
            arr.append(entry)
            print(f"  [add]  {event}: {cmd}")

with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)
print(f"\nupdated {settings_path}")
PY

echo ""
echo "Next steps:"
echo "  - Restart your interactive 'claude' session for hooks to take effect."
echo "  - Tune thresholds via env vars (default warn=20, deny=40):"
echo "      export CC_STUCK_WARN=15"
echo "      export CC_STUCK_DENY=30"
echo "  - To uninstall, restore from $backup"
