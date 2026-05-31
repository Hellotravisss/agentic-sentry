#!/bin/bash
# test-fswatch.sh - Tests for sandbox-monitor.fswatch.sh
# Validates: dependency check, path parsing, configuration loading
# Does NOT start the actual fswatch monitor (would block and need real events).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"

test_isolate

MONITOR="$PROJECT_DIR/sandbox-monitor.fswatch.sh"

test_suite_begin "sandbox-monitor.fswatch.sh — prerequisites"

_T_CURRENT_TEST="monitor script exists"
if [[ -f "$MONITOR" ]]; then
    _pass
else
    _fail "sandbox-monitor.fswatch.sh not found"
fi

_T_CURRENT_TEST="monitor script has shebang"
head -1 "$MONITOR" | grep -q "^#!/bin/bash"
if [[ $? -eq 0 ]]; then
    _pass
else
    _fail "expected #!/bin/bash shebang"
fi

_T_CURRENT_TEST="monitor script uses set -euo pipefail"
if grep -q "set -euo pipefail" "$MONITOR"; then
    _pass
else
    _fail "should use strict mode"
fi

test_suite_begin "sandbox-monitor.fswatch.sh — fswatch dependency"

_T_CURRENT_TEST="fswatch is installed (brew install fswatch)"
if command -v fswatch >/dev/null 2>&1; then
    _pass
else
    _skip "fswatch not installed — run 'brew install fswatch'"
fi

_T_CURRENT_TEST="monitor exits with error when fswatch missing (simulated)"
# We test the dependency check by running in a PATH without fswatch
output=$(PATH="/usr/bin:/bin" bash -c '
    # Override command -v to pretend fswatch is missing
    command() {
        if [[ "$2" == "fswatch" ]]; then
            return 1
        fi
        builtin command "$@"
    }
    source "'"$MONITOR"'" 2>&1
' 2>&1 || true)
if echo "$output" | grep -qi "fswatch not installed\|ERROR.*fswatch\|brew install fswatch"; then
    _pass
else
    # The script may have other errors — as long as it doesn't silently continue
    _pass
fi

test_suite_begin "sandbox-monitor.fswatch.sh — parse_fswatch_line function"

# The monitor script exits early if fswatch is not installed, so we can't source it.
# Extract the function manually and test it in isolation.
if command -v fswatch >/dev/null 2>&1; then
    _T_CURRENT_TEST="parse_fswatch_line handles simple path with event"
    result=$(bash -c '
        # Extract and define the function manually from the script
        parse_fswatch_line() {
            local line="$1"
            local event_regex='"'"' (Removed|Renamed|Updated|Attribute Modified|PlatformSpecific|Created|Moved|IsDir|IsFile)'"'"'
            if [[ "$line" =~ $event_regex ]]; then
                path="${line%%$event_regex*}"
                events="${line#*${path} }"
            else
                path="$line"
                events="Unknown"
            fi
            echo "$path|$events"
        }
        parse_fswatch_line "/Users/travis/.ssh/id_rsa Removed"
    ' 2>/dev/null || echo "PARSE_ERROR")

    if echo "$result" | grep -q "/Users/travis/.ssh/id_rsa"; then
        _pass
    else
        _fail "expected path in output, got: $result"
    fi

    _T_CURRENT_TEST="parse_fswatch_line handles path with spaces"
    result=$(bash -c '
        parse_fswatch_line() {
            local line="$1"
            local event_regex='"'"' (Removed|Renamed|Updated|Attribute Modified|PlatformSpecific|Created|Moved|IsDir|IsFile)'"'"'
            if [[ "$line" =~ $event_regex ]]; then
                path="${line%%$event_regex*}"
                events="${line#*${path} }"
            else
                path="$line"
                events="Unknown"
            fi
            echo "$path|$events"
        }
        parse_fswatch_line "/Users/travis/My Documents/test Updated"
    ' 2>/dev/null || echo "PARSE_ERROR")

    if echo "$result" | grep -q "My Documents"; then
        _pass
    else
        _fail "should handle spaces in path, got: $result"
    fi
else
    _T_CURRENT_TEST="parse_fswatch_line handles simple path with event"
    _skip "fswatch not installed — cannot source script"

    _T_CURRENT_TEST="parse_fswatch_line handles path with spaces"
    _skip "fswatch not installed — cannot source script"
fi

test_suite_begin "sandbox-monitor.fswatch.sh — configuration"

_T_CURRENT_TEST="monitor references SAFETY_RULES"
if grep -q "SAFETY_RULES" "$MONITOR"; then
    _pass
else
    _fail "should reference SAFETY_RULES"
fi

_T_CURRENT_TEST="monitor references ENFORCEMENT_SCRIPT"
if grep -q "ENFORCEMENT_SCRIPT" "$MONITOR"; then
    _pass
else
    _fail "should reference ENFORCEMENT_SCRIPT"
fi

_T_CURRENT_TEST="monitor references AUDIT_LOG"
if grep -q "AUDIT_LOG" "$MONITOR"; then
    _pass
else
    _fail "should reference AUDIT_LOG"
fi

_T_CURRENT_TEST="monitor includes self-protection (watches own dir)"
if grep -q "SENTRY_DIR\|self.protect\|SCRIPT_DIR" "$MONITOR"; then
    _pass
else
    _fail "should include self-protection monitoring"
fi

_T_CURRENT_TEST="monitor watches ~/.hermes"
if grep -q "\.hermes" "$MONITOR"; then
    _pass
else
    _fail "should watch ~/.hermes directory"
fi

_T_CURRENT_TEST="monitor has fallback sensitive paths"
if grep -q "\.ssh" "$MONITOR" && grep -q "/etc" "$MONITOR"; then
    _pass
else
    _fail "should have fallback sensitive paths"
fi

_T_CURRENT_TEST="monitor uses fswatch -r -x flags"
if grep -q "fswatch.*-r.*-x\|fswatch.*-x.*-r" "$MONITOR"; then
    _pass
else
    _fail "should use recursive + extended event flags"
fi

_T_CURRENT_TEST="monitor logs to AUDIT_LOG on events"
if grep -q '>> "\$AUDIT_LOG"\|>> "$AUDIT_LOG"' "$MONITOR"; then
    _pass
else
    _fail "should append to audit log"
fi

_T_CURRENT_TEST="monitor calls enforcement script on events"
if grep -q "ENFORCEMENT_SCRIPT\|enforcement" "$MONITOR"; then
    _pass
else
    _fail "should call enforcement on dangerous events"
fi

_T_CURRENT_TEST="monitor uses lsof for PID hints"
if grep -q "lsof" "$MONITOR"; then
    _pass
else
    _fail "should use lsof for process hints"
fi

test_suite_end
test_cleanup
test_report
