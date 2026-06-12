#!/bin/bash
# install-codex-hook.sh - Register Sentry as a Codex CLI PermissionRequest hook
#
# Usage:
#   ./install-codex-hook.sh                  # install into ~/.codex/hooks.json
#   ./install-codex-hook.sh --uninstall      # remove
#   ./install-codex-hook.sh --settings PATH  # custom hooks.json path
#
# Idempotent, with a timestamped backup before any change.
#
# NOTE: Codex requires you to review and trust new hooks before they run —
# after installing, run /hooks inside Codex to trust the Sentry hook.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_CMD="$SCRIPT_DIR/sentry-permissionrequest-hook.sh"

SETTINGS="$HOME/.codex/hooks.json"
ACTION="install"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --settings)  SETTINGS="$2"; shift 2 ;;
        --uninstall) ACTION="uninstall"; shift ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -11; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
done

command -v jq >/dev/null 2>&1 || { echo "Error: jq is required (brew install jq)"; exit 1; }
[[ -x "$HOOK_CMD" ]] || chmod +x "$HOOK_CMD" 2>/dev/null || true

mkdir -p "$(dirname "$SETTINGS")"
[[ -f "$SETTINGS" ]] || echo '{}' > "$SETTINGS"

if ! jq . "$SETTINGS" >/dev/null 2>&1; then
    echo "Error: $SETTINGS is not valid JSON — fix it manually first."
    exit 1
fi

backup="${SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$backup"
tmp=$(mktemp)

if [[ "$ACTION" == "install" ]]; then
    jq --arg cmd "$HOOK_CMD" '
        if ([.hooks.PermissionRequest // [] | .[] | .hooks // [] | .[] | .command] | index($cmd)) != null
        then .
        else .hooks.PermissionRequest = ((.hooks.PermissionRequest // []) + [{
            hooks: [{type: "command", command: $cmd, timeout: 15}]
        }])
        end
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

    echo "✅ Sentry PermissionRequest hook installed in: $SETTINGS"
    echo "   Backup: $backup"
    echo ""
    echo "⚠️  Codex requires hook trust: open Codex and run /hooks to review"
    echo "   and trust the Sentry hook before it takes effect."
else
    jq --arg cmd "$HOOK_CMD" '
        if .hooks.PermissionRequest then
            .hooks.PermissionRequest = (
                .hooks.PermissionRequest
                | map(.hooks = ((.hooks // []) | map(select(.command != $cmd))))
                | map(select((.hooks | length) > 0))
            )
        else . end
    ' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

    echo "✅ Sentry hook removed from: $SETTINGS"
    echo "   Backup: $backup"
fi
