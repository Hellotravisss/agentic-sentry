#!/bin/bash
# sentry-check.sh - Agent-agnostic command evaluation
#
# One function, one contract, shared by every integration (sentryctl check,
# Claude Code hook, Codex hook, OpenClaw plugin): evaluate a command string
# with the real is_dangerous() engine from sandbox-hooks.zsh.
#
#   sentry_check_command <command> [cwd]
#     Return 0 and set SENTRY_CHECK_REASON when the command is dangerous.
#     Return 1 (reason empty) when it is safe.
#     Return 2 when evaluation is impossible (zsh missing).
#
# The command string is attacker-influenced (it comes from an agent). It is
# passed via the environment and NEVER interpolated into shell source.

SENTRY_CHECK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sentry_check_command() {
    local cmd="${1:-}"
    local cwd="${2:-/}"
    SENTRY_CHECK_REASON=""

    [[ -z "$cmd" ]] && return 1
    command -v zsh >/dev/null 2>&1 || return 2

    local reason
    reason=$(SENTRY_HOOK_CMD="$cmd" SENTRY_HOOK_CWD="$cwd" SENTRY_NOTIFICATIONS="false" \
        zsh -c '
            SCRIPT_DIR="'"$SENTRY_CHECK_LIB_DIR"'"
            source "$SCRIPT_DIR/sentry-config.sh" >/dev/null 2>&1 || true
            load_sentry_config >/dev/null 2>&1 || true
            source "$SCRIPT_DIR/sandbox-hooks.zsh" >/dev/null 2>&1 || true
            is_dangerous "$SENTRY_HOOK_CMD" "$SENTRY_HOOK_CWD"
        ' 2>/dev/null) || reason=""

    if [[ -n "$reason" ]]; then
        SENTRY_CHECK_REASON="$reason"
        return 0
    fi
    return 1
}
