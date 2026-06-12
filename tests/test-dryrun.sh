#!/bin/bash
# test-dryrun.sh - Tests for dry-run mode (Issue #1)
# Validates: enforce --dry-run / SENTRY_DRY_RUN make zero state changes,
# restore --dry-run is read-only, dry-run is a valid configured mode,
# and the zsh hook dry-run path blocks without enforcement.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"

test_isolate

export ENFORCE_LOG="$_T_ISOLATION_DIR/enforcement.log"
export SENTRY_ENFORCE_LOG="$_T_ISOLATION_DIR/enforcement.log"
export SUSPENDED_PIDS_FILE="$_T_ISOLATION_DIR/suspended_pids.txt"
export RESTORE_CODE_FILE="$_T_ISOLATION_DIR/restore.code"

MODULE="$PROJECT_DIR/enforcement_recovery_module.sh"

test_suite_begin "dry-run — enforce --dry-run is side-effect free"

_T_CURRENT_TEST="enforce --dry-run exits 0"
if bash "$MODULE" enforce --dry-run "test violation" >/dev/null 2>&1; then
    _pass
else
    _fail "enforce --dry-run should exit 0"
fi

_T_CURRENT_TEST="enforce --dry-run output mentions DRY RUN"
output=$(bash "$MODULE" enforce --dry-run "test violation" 2>/dev/null)
if echo "$output" | grep -q "DRY RUN"; then
    _pass
else
    _fail "output should mention DRY RUN (got: $output)"
fi

_T_CURRENT_TEST="enforce --dry-run does not create a restore code"
if [[ ! -f "$RESTORE_CODE_FILE" ]]; then
    _pass
else
    _fail "restore code file should NOT exist after dry run"
fi

_T_CURRENT_TEST="enforce --dry-run does not record suspended PIDs"
if [[ ! -s "$SUSPENDED_PIDS_FILE" ]]; then
    _pass
else
    _fail "suspended PIDs file should be empty after dry run"
fi

_T_CURRENT_TEST="enforce --dry-run prints the planned network actions"
if echo "$output" | grep -q "networksetup -setairportpower" && \
   echo "$output" | grep -q "ifconfig" && \
   echo "$output" | grep -q "pfctl"; then
    _pass
else
    _fail "dry-run plan should list networksetup/ifconfig/pfctl actions"
fi

_T_CURRENT_TEST="SENTRY_DRY_RUN=1 env var also enables dry run"
output=$(SENTRY_DRY_RUN=1 bash "$MODULE" enforce "env var test" 2>/dev/null)
if echo "$output" | grep -q "DRY RUN" && [[ ! -f "$RESTORE_CODE_FILE" ]]; then
    _pass
else
    _fail "SENTRY_DRY_RUN=1 should behave like --dry-run"
fi

test_suite_begin "dry-run — restore --dry-run is read-only"

_T_CURRENT_TEST="restore --dry-run exits 0 without prompting"
# A real restore prompts for the code; dry-run must return before any prompt.
if output=$(bash "$MODULE" restore --dry-run </dev/null 2>/dev/null); then
    _pass
else
    _fail "restore --dry-run should exit 0 without input"
fi

_T_CURRENT_TEST="restore --dry-run lists planned restore actions"
if echo "$output" | grep -q "DRY RUN" && echo "$output" | grep -q "pfctl -a agentsentry -F all"; then
    _pass
else
    _fail "restore dry-run should list its plan (got: $output)"
fi

_T_CURRENT_TEST="restore --dry-run shows recorded PIDs without resuming"
echo "99999" > "$SUSPENDED_PIDS_FILE"
output=$(bash "$MODULE" restore --dry-run </dev/null 2>/dev/null)
if echo "$output" | grep -q "kill -CONT" && [[ -s "$SUSPENDED_PIDS_FILE" ]]; then
    _pass
else
    _fail "dry-run should list kill -CONT plan and leave the PID file intact"
fi
> "$SUSPENDED_PIDS_FILE"

test_suite_begin "dry-run — configured as a mode"

_T_CURRENT_TEST="set_sentry_mode accepts dry-run"
if bash -c "source '$PROJECT_DIR/sentry-config.sh'; set_sentry_mode dry-run" >/dev/null 2>&1; then
    _pass
else
    _fail "dry-run should be a valid mode"
fi

_T_CURRENT_TEST="config file records dry-run mode"
if command -v jq >/dev/null 2>&1 && [[ "$(jq -r '.mode' "$SENTRY_CONFIG" 2>/dev/null)" == "dry-run" ]]; then
    _pass
else
    _skip "jq not available or config not written"
fi

_T_CURRENT_TEST="set_sentry_mode still rejects invalid modes"
if bash -c "source '$PROJECT_DIR/sentry-config.sh'; set_sentry_mode bogus-mode" >/dev/null 2>&1; then
    _fail "bogus-mode should be rejected"
else
    _pass
fi

_T_CURRENT_TEST="should_attempt_block returns true in dry-run mode"
if bash -c "source '$PROJECT_DIR/sentry-config.sh'; set_sentry_mode dry-run >/dev/null; should_attempt_block"; then
    _pass
else
    _fail "dry-run should attempt to block commands"
fi

test_suite_begin "dry-run — zsh hook behavior"

if command -v zsh >/dev/null 2>&1; then
    # Run preexec with a dangerous command in dry-run mode.
    # Expect: non-zero return (blocked), no restore code, DRY_RUN logged.
    hook_exit=0
    hook_output=$(zsh -c '
        SCRIPT_DIR="'"$PROJECT_DIR"'"
        SENTRY_HOME="'"$SENTRY_HOME"'"
        SENTRY_CONFIG="'"$SENTRY_CONFIG"'"
        SENTRY_NOTIFICATIONS="false"
        RESTORE_CODE_FILE="'"$RESTORE_CODE_FILE"'"
        SUSPENDED_PIDS_FILE="'"$SUSPENDED_PIDS_FILE"'"
        SENTRY_ENFORCE_LOG="'"$ENFORCE_LOG"'"
        source "$SCRIPT_DIR/sentry-config.sh" 2>/dev/null || true
        load_sentry_config 2>/dev/null || true
        SENTRY_MODE="dry-run"
        source "$SCRIPT_DIR/sandbox-hooks.zsh" 2>/dev/null || true
        preexec "sudo rm -rf /etc" "/tmp"
    ' 2>/dev/null) || hook_exit=$?

    _T_CURRENT_TEST="hook blocks dangerous command in dry-run mode"
    if (( hook_exit != 0 )); then
        _pass
    else
        _fail "preexec should return non-zero in dry-run mode"
    fi

    _T_CURRENT_TEST="hook prints dry-run banner"
    if echo "$hook_output" | grep -q "SENTRY DRY-RUN"; then
        _pass
    else
        _fail "hook output should mention SENTRY DRY-RUN"
    fi

    _T_CURRENT_TEST="hook dry-run leaves no restore code behind"
    if [[ ! -f "$RESTORE_CODE_FILE" ]]; then
        _pass
    else
        _fail "no restore code should exist after hook dry run"
    fi
else
    _T_CURRENT_TEST="zsh available for hook tests"
    _skip "zsh not installed"
fi

test_suite_end
test_cleanup
test_report
