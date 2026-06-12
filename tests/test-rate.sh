#!/bin/bash
# test-rate.sh - Tests for the repetition (retry-loop) detector (T9)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"

test_isolate
export SENTRY_RATE_FILE="$_T_ISOLATION_DIR/recent-commands"
export SENTRY_RATE_THRESHOLD=3
export SENTRY_RATE_WINDOW=600

source "$PROJECT_DIR/sentry-rate.sh"

test_suite_begin "rate rule — threshold crossing"

_T_CURRENT_TEST="below threshold stays silent"
ok=true
sentry_rate_check "npm test" && ok=false
sentry_rate_check "npm test" && ok=false
if $ok; then
    _pass
else
    _fail "should not fire before threshold"
fi

_T_CURRENT_TEST="fires exactly at the threshold crossing"
if sentry_rate_check "npm test" && [[ -n "$SENTRY_RATE_REASON" ]]; then
    _pass
else
    _fail "3rd repeat should fire (reason: ${SENTRY_RATE_REASON:-empty})"
fi

_T_CURRENT_TEST="does not fire again after the crossing"
if sentry_rate_check "npm test"; then
    _fail "4th repeat must not fire again (no log spam)"
else
    _pass
fi

_T_CURRENT_TEST="different commands do not share counts"
if sentry_rate_check "go test ./..."; then
    _fail "first run of a different command must not fire"
else
    _pass
fi

test_suite_begin "rate rule — window expiry"

_T_CURRENT_TEST="entries outside the window are ignored"
rm -f "$SENTRY_RATE_FILE"
old=$(( $(date +%s) - 9999 ))
sig=$(printf '%s' "make build" | cksum | awk '{print $1"-"$2}')
printf '%s %s\n%s %s\n' "$old" "$sig" "$old" "$sig" > "$SENTRY_RATE_FILE"
# Two stale entries + two fresh ones = 3 in-window only after the 3rd fresh
ok=true
sentry_rate_check "make build" && ok=false   # 1 fresh
sentry_rate_check "make build" && ok=false   # 2 fresh
if $ok && sentry_rate_check "make build"; then  # 3 fresh -> fires
    _pass
else
    _fail "stale entries must not count toward the threshold"
fi

_T_CURRENT_TEST="state file gets pruned when oversized"
rm -f "$SENTRY_RATE_FILE"
for i in $(seq 1 1100); do echo "$old stale-$i" >> "$SENTRY_RATE_FILE"; done
sentry_rate_check "prune trigger" || true
lines=$(wc -l < "$SENTRY_RATE_FILE" | tr -d ' ')
if [[ "$lines" -lt 100 ]]; then
    _pass
else
    _fail "expected pruned file, still has $lines lines"
fi

test_suite_begin "rate rule — hook integration (signal only)"

export SENTRY_LOG_DIR="$_T_ISOLATION_DIR/logs"
export SENTRY_AUDIT_LOG="$SENTRY_LOG_DIR/sandbox-audit.log"
mkdir -p "$SENTRY_LOG_DIR"
bash -c "source '$PROJECT_DIR/sentry-config.sh'; ensure_sentry_config" >/dev/null 2>&1

if command -v jq >/dev/null 2>&1 && command -v zsh >/dev/null 2>&1; then
    HOOK="$PROJECT_DIR/integrations/claude-code/sentry-pretooluse-hook.sh"
    rm -f "$SENTRY_RATE_FILE"
    input=$(jq -n '{tool_name:"Bash",tool_input:{command:"git status"},cwd:"/tmp"}')

    _T_CURRENT_TEST="repeated safe command stays allowed (no decision output)"
    ok=true
    for i in 1 2 3 4; do
        out=$(echo "$input" | bash "$HOOK" 2>/dev/null) || ok=false
        [[ -n "$out" ]] && ok=false
    done
    if $ok; then
        _pass
    else
        _fail "rate signal must never block or emit a decision"
    fi

    _T_CURRENT_TEST="crossing logged as RATE_REPEAT with component claude-hook"
    if grep -q '"decision":"RATE_REPEAT"' "$SENTRY_AUDIT_LOG" 2>/dev/null \
        && grep -q '"component":"claude-hook"' "$SENTRY_AUDIT_LOG" 2>/dev/null; then
        _pass
    else
        _fail "expected one RATE_REPEAT audit entry"
    fi

    _T_CURRENT_TEST="exactly one RATE_REPEAT entry (no spam)"
    n=$(grep -c '"decision":"RATE_REPEAT"' "$SENTRY_AUDIT_LOG" 2>/dev/null || echo 0)
    if [[ "$n" == "1" ]]; then
        _pass
    else
        _fail "expected 1 entry, got $n"
    fi
else
    _T_CURRENT_TEST="jq and zsh available"
    _skip "jq or zsh not installed"
fi

test_suite_end
test_cleanup
test_report
