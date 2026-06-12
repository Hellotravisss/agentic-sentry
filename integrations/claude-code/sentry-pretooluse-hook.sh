#!/bin/bash
# sentry-pretooluse-hook.sh - Claude Code PreToolUse hook adapter
#
# Bridges Agentic Sandbox Sentry's detection engine into Claude Code's
# official hook system. Claude Code invokes this before every Bash tool
# call; we evaluate the command with the same is_dangerous() rules the
# zsh hook uses, then map Sentry's mode to a permission decision:
#
#   safe command  -> exit 0, no output   (defer to normal permission flow)
#   audit         -> log only, defer
#   warn          -> "ask"  (user sees the reason and decides)
#   dry-run       -> "ask"  (same, labeled as dry run)
#   soft-block    -> "deny"
#   hard          -> "deny" (no physical enforcement from inside a hook)
#
# Fail-safe behavior: on any internal error (missing jq/zsh, malformed
# input) we exit 0 with no output, which defers to Claude Code's own
# permission prompts rather than silently approving anything.
#
# Install: integrations/claude-code/install-claude-hook.sh
# Docs:    docs/claude-code-integration.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Without jq or zsh we cannot evaluate — defer to normal permission flow
command -v jq >/dev/null 2>&1 || exit 0
command -v zsh >/dev/null 2>&1 || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[[ -z "$INPUT" ]] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
# Defensive: the settings matcher should already filter to Bash
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[[ -z "$CMD" ]] && exit 0
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // "/"' 2>/dev/null) || CWD="/"

# Evaluate with the real detection engine. The command is passed via the
# environment, never interpolated into the zsh script — command strings
# come from the agent and must not be able to inject into this hook.
REASON=$(SENTRY_HOOK_CMD="$CMD" SENTRY_HOOK_CWD="$CWD" SENTRY_NOTIFICATIONS="false" \
    zsh -c '
        SCRIPT_DIR="'"$PROJECT_DIR"'"
        source "$SCRIPT_DIR/sentry-config.sh" >/dev/null 2>&1 || true
        load_sentry_config >/dev/null 2>&1 || true
        source "$SCRIPT_DIR/sandbox-hooks.zsh" >/dev/null 2>&1 || true
        is_dangerous "$SENTRY_HOOK_CMD" "$SENTRY_HOOK_CWD"
    ' 2>/dev/null) || REASON=""

# Safe command: stay invisible
[[ -z "$REASON" ]] && exit 0

# Load Sentry mode and the structured logger (best effort)
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
        sentry_log "$decision" "$REASON" "claude-hook" "{\"cmd\":\"$safe_cmd\",\"cwd\":\"$CWD\",\"mode\":\"$MODE\"}" 2>/dev/null || true
    fi
}

emit_decision() {
    local decision="$1"
    local reason="$2"
    jq -n --arg d "$decision" --arg r "$reason" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: $d,
            permissionDecisionReason: $r
        }
    }'
}

case "$MODE" in
    audit)
        hook_log "CLAUDE_HOOK_AUDIT"
        exit 0
        ;;
    warn)
        hook_log "CLAUDE_HOOK_ASK"
        emit_decision "ask" "Sentry (warn mode): $REASON"
        ;;
    dry-run)
        hook_log "CLAUDE_HOOK_ASK"
        emit_decision "ask" "Sentry (dry-run): would block — $REASON"
        ;;
    soft-block|hard)
        hook_log "CLAUDE_HOOK_DENY"
        emit_decision "deny" "Sentry ($MODE mode): $REASON. Adjust with 'sentryctl mode' or allow the directory with 'sentryctl allow-dir'."
        ;;
    *)
        hook_log "CLAUDE_HOOK_ASK"
        emit_decision "ask" "Sentry (unknown mode '$MODE'): $REASON"
        ;;
esac

exit 0
