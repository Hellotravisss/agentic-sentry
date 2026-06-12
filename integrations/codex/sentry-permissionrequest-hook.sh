#!/bin/bash
# sentry-permissionrequest-hook.sh - OpenAI Codex CLI PermissionRequest hook
#
# Codex invokes this when it is about to ask the user for approval (shell
# escalation, command outside the trusted set, etc.). We evaluate the
# command with Sentry's engine and map the configured Sentry mode:
#
#   safe command       -> exit 0, no output  (normal approval flow)
#   audit              -> log only, defer
#   warn / dry-run     -> log, defer         (Codex's own prompt IS the ask)
#   soft-block / hard  -> deny with message
#
# Coverage note: Codex only fires PermissionRequest for commands that need
# approval. Commands auto-approved inside the sandbox/workdir never reach
# this hook — Codex's own sandbox is the guard there.
#
# Fail-safe: any internal error defers to Codex's normal approval prompt.
# Install: integrations/codex/install-codex-hook.sh
# Docs:    docs/integrations.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

command -v jq >/dev/null 2>&1 || exit 0
command -v zsh >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[[ -z "$INPUT" ]] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[[ -z "$CMD" ]] && exit 0
# Only shell-like requests carry a command we can evaluate
case "$TOOL_NAME" in
    Bash|shell|local_shell|exec) ;;
    *) [[ -n "$CMD" ]] || exit 0 ;;
esac
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "/"' 2>/dev/null) || CWD="/"

[[ -f "$PROJECT_DIR/sentry-check.sh" ]] || exit 0
# shellcheck source=/dev/null
source "$PROJECT_DIR/sentry-check.sh"

if ! sentry_check_command "$CMD" "$CWD"; then
    exit 0
fi
REASON="$SENTRY_CHECK_REASON"

MODE="soft-block"
if [[ -f "$PROJECT_DIR/sentry-config.sh" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/sentry-config.sh" >/dev/null 2>&1 || true
    MODE=$(get_sentry_mode 2>/dev/null || echo "soft-block")
fi
if [[ -f "$PROJECT_DIR/sentry-logger.sh" ]]; then
    # shellcheck source=/dev/null
    source "$PROJECT_DIR/sentry-logger.sh" >/dev/null 2>&1 || true
fi

hook_log() {
    local decision="$1"
    if command -v sentry_log >/dev/null 2>&1; then
        local safe_cmd
        safe_cmd=$(printf '%s' "$CMD" | head -c 300 | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n\t')
        sentry_log "$decision" "$REASON" "codex-hook" "{\"cmd\":\"$safe_cmd\",\"cwd\":\"$CWD\",\"mode\":\"$MODE\"}" 2>/dev/null || true
    fi
}

deny() {
    jq -n --arg msg "$1" '{
        hookSpecificOutput: {
            hookEventName: "PermissionRequest",
            decision: { behavior: "deny", message: $msg }
        }
    }'
}

case "$MODE" in
    soft-block|hard)
        hook_log "CODEX_HOOK_DENY"
        deny "Sentry ($MODE mode): $REASON. Adjust with 'sentryctl mode' or 'sentryctl allow-dir'."
        ;;
    audit|warn|dry-run|*)
        # Codex is already about to prompt the user — that prompt is the
        # "ask". We add an audit trail and step aside.
        hook_log "CODEX_HOOK_DEFER"
        exit 0
        ;;
esac

exit 0
