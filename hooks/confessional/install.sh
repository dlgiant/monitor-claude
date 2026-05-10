#!/usr/bin/env bash
# Installer — registers the Confessional Stop hook in ~/.claude/settings.json.
# Idempotent. Backs up the existing settings.json.
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

cmd = f"{hook_dir}/critique.sh"
hooks = s.setdefault("hooks", {})
arr = hooks.setdefault("Stop", [])
already = any(any(h.get("command") == cmd for h in e.get("hooks", [])) for e in arr)
if already:
    print(f"  [skip] Stop: {cmd} (already present)")
else:
    arr.append({"hooks": [{"type": "command", "command": cmd}]})
    print(f"  [add]  Stop: {cmd}")

with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)
print(f"\nupdated {settings_path}")
PY

echo ""
echo "Next steps:"
echo "  - Restart your interactive 'claude' session for the hook to load."
echo "  - End a session normally; ~30s later the dashboard's Confessional panel"
echo "    should show one new entry."
echo "  - Tunables (env): CC_CONFESS_MODEL, CC_CONFESS_TIMEOUT_S, CC_CONFESS_DISABLE."
echo "  - To uninstall, restore from $backup"
