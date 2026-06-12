#!/bin/bash
# test-process-matching.sh - Tests for process matching/suspension logic (Issue #2)
# Validates: get_process_whitelist, discover_candidate_pids, suspend_pids,
# resume_suspended_processes. Uses only short-lived sleep processes owned by
# the test itself — never touches system or user processes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"

test_isolate

export ENFORCE_LOG="$_T_ISOLATION_DIR/enforcement.log"
export SUSPENDED_PIDS_FILE="$_T_ISOLATION_DIR/suspended_pids.txt"
export RESTORE_CODE_FILE="$_T_ISOLATION_DIR/restore.code"

# Source the module functions without executing main (BASH_SOURCE guard)
source "$PROJECT_DIR/enforcement_recovery_module.sh" 2>/dev/null || true

test_suite_begin "process matching — whitelist"

_T_CURRENT_TEST="whitelist covers critical system and Sentry processes"
wl=$(get_process_whitelist)
ok=true
for name in fswatch launchd Terminal sentry sshd; do
    echo "$name" | grep -qE "$wl" || { ok=false; break; }
done
if $ok; then
    _pass
else
    _fail "whitelist missing expected entry: $name (whitelist: $wl)"
fi

_T_CURRENT_TEST="whitelist does not match ordinary processes"
wl=$(get_process_whitelist)
if echo "node" | grep -qE "$wl" || echo "python3" | grep -qE "$wl"; then
    _fail "whitelist should not match node/python3"
else
    _pass
fi

test_suite_begin "process matching — discover_candidate_pids"

_T_CURRENT_TEST="explicit PID hints are used verbatim"
pids=$(discover_candidate_pids "some reason" "12345 67890")
if echo "$pids" | grep -q "12345" && echo "$pids" | grep -q "67890"; then
    _pass
else
    _fail "expected hinted PIDs back, got: $pids"
fi

_T_CURRENT_TEST="non-numeric hint tokens are filtered out"
pids=$(discover_candidate_pids "some reason" "path:/foo 4242 not-a-pid")
if echo "$pids" | grep -q "4242" && ! echo "$pids" | grep -q "not-a-pid" && ! echo "$pids" | grep -q "path:"; then
    _pass
else
    _fail "expected only 4242, got: $pids"
fi

_T_CURRENT_TEST="falls back to parent-process heuristic with no hints"
pids=$(discover_candidate_pids "generic reason" "")
if [[ -n "${pids// /}" ]]; then
    _pass
else
    _fail "fallback should find at least the parent shell"
fi

test_suite_begin "process matching — suspend and resume (own sleep processes)"

# Start a disposable sleep process we own; freezing it is safe and reversible.
sleep 30 &
VICTIM_PID=$!

_T_CURRENT_TEST="suspend_pids freezes a target process"
suspend_pids "$VICTIM_PID" "test" >/dev/null 2>&1 || true
state=$(ps -o state= -p "$VICTIM_PID" 2>/dev/null | tr -d ' ')
if [[ "$state" == T* ]]; then
    _pass
else
    _fail "expected stopped state (T), got: '$state'"
fi

_T_CURRENT_TEST="suspended PID is recorded for recovery"
if grep -q "^$VICTIM_PID$" "$SUSPENDED_PIDS_FILE" 2>/dev/null; then
    _pass
else
    _fail "PID $VICTIM_PID not recorded in $SUSPENDED_PIDS_FILE"
fi

_T_CURRENT_TEST="resume_suspended_processes resumes it"
resume_suspended_processes >/dev/null 2>&1 || true
state=$(ps -o state= -p "$VICTIM_PID" 2>/dev/null | tr -d ' ')
if [[ -n "$state" && "$state" != T* ]]; then
    _pass
else
    _fail "expected running state after resume, got: '$state'"
fi

_T_CURRENT_TEST="suspended PID list is cleared after resume"
if [[ ! -s "$SUSPENDED_PIDS_FILE" ]]; then
    _pass
else
    _fail "PID file should be empty after resume"
fi

# Clean up the sleep process
kill "$VICTIM_PID" 2>/dev/null || true
wait "$VICTIM_PID" 2>/dev/null || true

test_suite_begin "process matching — unfreeze subcommand"

MODULE="$PROJECT_DIR/enforcement_recovery_module.sh"

_T_CURRENT_TEST="unfreeze with empty PID file exits cleanly"
if bash "$MODULE" unfreeze --yes >/dev/null 2>&1; then
    _pass
else
    _fail "unfreeze should exit 0 when nothing is suspended"
fi

_T_CURRENT_TEST="unfreeze --yes resumes a frozen process"
sleep 30 &
VICTIM2=$!
kill -STOP "$VICTIM2" 2>/dev/null
echo "$VICTIM2" > "$SUSPENDED_PIDS_FILE"
bash "$MODULE" unfreeze --yes >/dev/null 2>&1 || true
state=$(ps -o state= -p "$VICTIM2" 2>/dev/null | tr -d ' ')
if [[ -n "$state" && "$state" != T* ]]; then
    _pass
else
    _fail "process should be running after unfreeze (state: '$state')"
fi
kill "$VICTIM2" 2>/dev/null || true
wait "$VICTIM2" 2>/dev/null || true

_T_CURRENT_TEST="unfreeze --dry-run lists PIDs but resumes nothing"
sleep 30 &
VICTIM3=$!
kill -STOP "$VICTIM3" 2>/dev/null
echo "$VICTIM3" > "$SUSPENDED_PIDS_FILE"
output=$(bash "$MODULE" unfreeze --dry-run </dev/null 2>/dev/null)
state=$(ps -o state= -p "$VICTIM3" 2>/dev/null | tr -d ' ')
if echo "$output" | grep -q "DRY RUN" && [[ "$state" == T* ]]; then
    _pass
else
    _fail "dry-run must not resume (state: '$state', output: $output)"
fi
kill -CONT "$VICTIM3" 2>/dev/null || true
kill "$VICTIM3" 2>/dev/null || true
wait "$VICTIM3" 2>/dev/null || true
> "$SUSPENDED_PIDS_FILE"

_T_CURRENT_TEST="unfreeze without --yes aborts on no input"
echo "99999" > "$SUSPENDED_PIDS_FILE"
if bash "$MODULE" unfreeze </dev/null >/dev/null 2>&1; then
    _fail "unfreeze should abort without confirmation"
else
    _pass
fi
> "$SUSPENDED_PIDS_FILE"

test_suite_begin "process matching — bad input safety"

_T_CURRENT_TEST="suspend_pids ignores non-numeric input"
> "$SUSPENDED_PIDS_FILE"
suspend_pids "abc ../../etc \$(reboot)" "test" >/dev/null 2>&1 || true
if [[ ! -s "$SUSPENDED_PIDS_FILE" ]]; then
    _pass
else
    _fail "non-numeric input must never be recorded: $(cat "$SUSPENDED_PIDS_FILE")"
fi

_T_CURRENT_TEST="suspend_pids ignores empty input"
suspend_pids "" "test" >/dev/null 2>&1 || true
if [[ ! -s "$SUSPENDED_PIDS_FILE" ]]; then
    _pass
else
    _fail "empty input must not record PIDs"
fi

test_suite_end
test_cleanup
test_report
