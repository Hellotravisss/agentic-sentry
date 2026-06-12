#!/bin/bash
# install-claude-hook.sh - Register Sentry as a Claude Code PreToolUse hook
#
# Usage:
#   ./install-claude-hook.sh                 # install into ~/.claude/settings.json
#   ./install-claude-hook.sh --project       # install into ./.claude/settings.json
#   ./install-claude-hook.sh --uninstall     # remove from ~/.claude/settings.json
#   ./install-claude-hook.sh --settings PATH # explicit settings file
#
# Idempotent: running install twice adds the hook once. A timestamped
# backup of the settings file is written before any change.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_CMD="$SCRIPT_DIR/sentry-pretooluse-hook.sh"

SETTINGS="$HOME/.claude/settings.json"
ACTION="install"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project)   SETTINGS="$PWD/.claude/settings.json"; shift ;;
        --settings)  SETTINGS="$2"; shift 2 ;;
        --uninstall) ACTION="uninstall"; shift ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -12; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required (brew install jq)"; exit 1; }
[[ -x "$HOOK_CMD" ]] || chmod +x "$HOOK_CMD" 2>/dev/null || true

mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

# Refuse to edit a file that is not valid JSON
if ! jq . "$SETTINGS" >/dev/null 2>&1; then
    echo "Error: $SETTINGS is not valid JSON — fix it manually first."
    exit 1
fi

backup="${SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$backup"

tmp=$(mktemp)

if [[ "$ACTION" == "install" ]]; then
    jq --arg cmd "$HOOK_CMD" '
        if ([.hooks.PreToolUse // [] | .[] | .hooks // [] | .[] | .command] | index($cmd)) != null
        then .
        else .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{
            matcher: "Bash",
            hooks: [{type: "command", command: $cmd, timeout: 15}]
        }])
        end
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

    echo "✅ Sentry PreToolUse hook installed in: $SETTINGS"
    echo "   Hook script: $HOOK_CMD"
    echo "   Backup:      $backup"
    echo ""
    echo "Claude Code picks up hook changes at session start — restart any"
    echo "running session. Current Sentry mode: $("$SCRIPT_DIR/../../sentryctl" mode 2>/dev/null | grep -o 'Current:.*' || echo 'run sentryctl mode')"
    echo "Uninstall any time with: $0 --uninstall"
else
    jq --arg cmd "$HOOK_CMD" '
        if .hooks.PreToolUse then
            .hooks.PreToolUse = (
                .hooks.PreToolUse
                | map(.hooks = ((.hooks // []) | map(select(.command != $cmd))))
                | map(select((.hooks | length) > 0))
            )
        else . end
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

    echo "✅ Sentry hook removed from: $SETTINGS"
    echo "   Backup: $backup"
fi
