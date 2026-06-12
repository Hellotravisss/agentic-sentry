#!/bin/bash
# test-check.sh - Tests for sentryctl check (agent-agnostic verdict command)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"

test_isolate
export SENTRY_LOG_DIR="$_T_ISOLATION_DIR/logs"
export SENTRY_AUDIT_LOG="$SENTRY_LOG_DIR/sandbox-audit.log"
mkdir -p "$SENTRY_LOG_DIR"
bash -c "source '$PROJECT_DIR/sentry-config.sh'; ensure_sentry_config" >/dev/null 2>&1

CTL="$PROJECT_DIR/sentryctl"

test_suite_begin "sentryctl check — verdicts and exit codes"

_T_CURRENT_TEST="dangerous command exits 1"
if bash "$CTL" check -- "sudo rm -rf /etc" >/dev/null 2>&1; then
    _fail "expected exit 1 for dangerous command"
else
    _pass
fi

_T_CURRENT_TEST="safe command exits 0"
if bash "$CTL" check -- "git status" >/dev/null 2>&1; then
    _pass
else
    _fail "expected exit 0 for safe command"
fi

_T_CURRENT_TEST="missing command exits 2"
rc=0; bash "$CTL" check --json >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 ]]; then
    _pass
else
    _fail "expected exit 2, got $rc"
fi

test_suite_begin "sentryctl check — JSON output"

_T_CURRENT_TEST="--json emits valid JSON with verdict/reason/mode"
out=$(bash "$CTL" check --json -- "cat ~/.ssh/id_rsa" 2>/dev/null) || true
if echo "$out" | jq -e '.verdict == "dangerous" and (.reason | length > 0) and (.mode | length > 0)' >/dev/null 2>&1; then
    _pass
else
    _fail "bad JSON: $out"
fi

_T_CURRENT_TEST="--json safe verdict has empty reason"
out=$(bash "$CTL" check --json -- "echo hello" 2>/dev/null)
if echo "$out" | jq -e '.verdict == "safe" and .reason == ""' >/dev/null 2>&1; then
    _pass
else
    _fail "bad JSON: $out"
fi

test_suite_begin "sentryctl check — logging and safety"

_T_CURRENT_TEST="--log writes CHECK_DANGEROUS with component"
bash "$CTL" check --log --component test-adapter -- "sudo whoami" >/dev/null 2>&1 || true
if grep -q '"decision":"CHECK_DANGEROUS"' "$SENTRY_AUDIT_LOG" 2>/dev/null \
    && grep -q '"component":"test-adapter"' "$SENTRY_AUDIT_LOG" 2>/dev/null; then
    _pass
else
    _fail "expected CHECK_DANGEROUS log entry with component test-adapter"
fi

_T_CURRENT_TEST="safe commands are not logged"
before=$(wc -l < "$SENTRY_AUDIT_LOG" 2>/dev/null || echo 0)
bash "$CTL" check --log --component test-adapter -- "ls -la" >/dev/null 2>&1 || true
after=$(wc -l < "$SENTRY_AUDIT_LOG" 2>/dev/null || echo 0)
if [[ "$before" == "$after" ]]; then
    _pass
else
    _fail "safe command should not add log lines"
fi

_T_CURRENT_TEST="command string cannot inject"
marker="$_T_ISOLATION_DIR/check-pwned"
bash "$CTL" check -- "sudo x; '; touch $marker; echo '" >/dev/null 2>&1 || true
if [[ ! -e "$marker" ]]; then
    _pass
else
    _fail "command string was executed by check!"
fi

test_suite_end
test_cleanup
test_report
