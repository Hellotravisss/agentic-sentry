#!/bin/bash
# test-helpers.sh - Minimal test framework for Agentic Sentry
# Provides: assert_eq, assert_ok, assert_fail, assert_contains, assert_not_contains
# Plus: test isolation (temp dirs, env backup/restore), colored output, TAP-like reporting

set -euo pipefail

# Colors
_T_RED='\033[0;31m'
_T_GREEN='\033[0;32m'
_T_YELLOW='\033[1;33m'
_T_BLUE='\033[0;34m'
_T_NC='\033[0m'

# Counters
_T_TOTAL=0
_T_PASSED=0
_T_FAILED=0
_T_SKIPPED=0
_T_ERRORS=()

# Current test context
_T_CURRENT_SUITE=""
_T_CURRENT_TEST=""

# Isolation: temp dir for each test file
_T_ISOLATION_DIR=""
_T_ENV_BACKUP=""

# --- Setup / Teardown ---

test_suite_begin() {
    local name="$1"
    _T_CURRENT_SUITE="$name"
    echo ""
    echo -e "${_T_BLUE}=== $name ===${_T_NC}"
}

test_suite_end() {
    echo ""
}

# Create an isolated temp directory for the current test file.
# Sets SENTRY_HOME, SENTRY_CONFIG, SAFETY_RULES, AUDIT_LOG to temp locations
# so tests never touch the user's real config or logs.
test_isolate() {
    _T_ISOLATION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sentry-test.XXXXXX")

    # Point all sentry paths to the temp dir
    export SENTRY_HOME="$_T_ISOLATION_DIR/hermes"
    export SENTRY_CONFIG="$_T_ISOLATION_DIR/hermes/sentry-config.json"
    export SAFETY_RULES="$_T_ISOLATION_DIR/hermes/safety-rules.json"
    export AUDIT_LOG="$_T_ISOLATION_DIR/sandbox-audit.log"
    export SENTRY_MODE="soft-block"
    export SENTRY_NOTIFICATIONS="false"

    # Isolate the logger too: sentry-logger.sh has its own defaults and
    # would otherwise write to the user's real Sentry home.
    export SENTRY_LOG_DIR="$SENTRY_HOME/logs"
    export SENTRY_AUDIT_LOG="$SENTRY_LOG_DIR/sandbox-audit.log"
    export SENTRY_ENFORCE_LOG="$SENTRY_LOG_DIR/enforcement.log"
    export SENTRY_SELFLOG="$SENTRY_LOG_DIR/selfguard.log"

    mkdir -p "$SENTRY_HOME/logs"

    # Create a default safety-rules.json for tests
    cat > "$SAFETY_RULES" << 'RULES'
{
  "allowed_project_dirs": [
    "/tmp/sentry-test-projects",
    "$HOME/Documents/Vibe_Coding"
  ],
  "sensitive_paths": [
    "$HOME/.ssh",
    "$HOME/.gnupg",
    "/etc",
    "/System"
  ]
}
RULES

    # Expand $HOME in the rules
    sed -i '' "s|\\\$HOME|$HOME|g" "$SAFETY_RULES" 2>/dev/null || true

    # Create a safe allowed dir for path tests
    mkdir -p /tmp/sentry-test-projects/myproject
}

test_cleanup() {
    if [[ -n "$_T_ISOLATION_DIR" && -d "$_T_ISOLATION_DIR" ]]; then
        rm -rf "$_T_ISOLATION_DIR"
    fi
    rm -rf /tmp/sentry-test-projects 2>/dev/null || true
}

# --- Assertions ---

_pass() {
    ((_T_PASSED++)) || true
    ((_T_TOTAL++)) || true
    echo -e "  ${_T_GREEN}✓${_T_NC} $_T_CURRENT_TEST"
}

_fail() {
    local detail="${1:-}"
    ((_T_FAILED++)) || true
    ((_T_TOTAL++)) || true
    echo -e "  ${_T_RED}✗${_T_NC} $_T_CURRENT_TEST"
    if [[ -n "$detail" ]]; then
        echo -e "    ${_T_RED}$detail${_T_NC}"
    fi
    _T_ERRORS+=("$_T_CURRENT_SUITE > $_T_CURRENT_TEST: $detail")
}

_skip() {
    local reason="${1:-}"
    ((_T_SKIPPED++)) || true
    ((_T_TOTAL++)) || true
    echo -e "  ${_T_YELLOW}○${_T_NC} $_T_CURRENT_TEST ${_T_YELLOW}(skipped: $reason)${_T_NC}"
}

# Run a named test. Usage: run_test "description" command [args...]
run_test() {
    _T_CURRENT_TEST="$1"
    shift
    if "$@"; then
        _pass
    else
        _fail "command failed: $*"
    fi
}

# Assert two values are equal
assert_eq() {
    local expected="$1"
    local actual="$2"
    local label="${3:-}"
    _T_CURRENT_TEST="${label:-assert_eq}"
    if [[ "$expected" == "$actual" ]]; then
        _pass
    else
        _fail "expected '$expected', got '$actual'"
    fi
}

# Assert a command exits 0
assert_ok() {
    local label="$1"
    shift
    _T_CURRENT_TEST="$label"
    if "$@" >/dev/null 2>&1; then
        _pass
    else
        _fail "expected exit 0 from: $*"
    fi
}

# Assert a command exits non-zero
assert_fail() {
    local label="$1"
    shift
    _T_CURRENT_TEST="$label"
    if "$@" >/dev/null 2>&1; then
        _fail "expected non-zero exit from: $*"
    else
        _pass
    fi
}

# Assert output of a command contains a string
assert_contains() {
    local label="$1"
    local needle="$2"
    shift 2
    _T_CURRENT_TEST="$label"
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -qF "$needle"; then
        _pass
    else
        _fail "output missing '$needle' (got: $(echo "$output" | head -3))"
    fi
}

# Assert output of a command does NOT contain a string
assert_not_contains() {
    local label="$1"
    local needle="$2"
    shift 2
    _T_CURRENT_TEST="$label"
    local output
    output=$("$@" 2>&1) || true
    if echo "$output" | grep -qF "$needle"; then
        _fail "output unexpectedly contains '$needle'"
    else
        _pass
    fi
}

# Assert a file exists
assert_file_exists() {
    local label="$1"
    local path="$2"
    _T_CURRENT_TEST="$label"
    if [[ -f "$path" ]]; then
        _pass
    else
        _fail "file not found: $path"
    fi
}

# Assert a file contains a string
assert_file_contains() {
    local label="$1"
    local path="$2"
    local needle="$3"
    _T_CURRENT_TEST="$label"
    if [[ -f "$path" ]] && grep -qF "$needle" "$path"; then
        _pass
    else
        _fail "file '$path' does not contain '$needle'"
    fi
}

# Skip a test with a reason
skip_test() {
    local label="$1"
    local reason="${2:-not applicable}"
    _T_CURRENT_TEST="$label"
    _skip "$reason"
}

# --- Reporting ---

test_report() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "Results: ${_T_GREEN}${_T_PASSED} passed${_T_NC}, ${_T_RED}${_T_FAILED} failed${_T_NC}, ${_T_YELLOW}${_T_SKIPPED} skipped${_T_NC} (${_T_TOTAL} total)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if (( _T_FAILED > 0 )); then
        echo ""
        echo -e "${_T_RED}Failures:${_T_NC}"
        for err in "${_T_ERRORS[@]}"; do
            echo -e "  ${_T_RED}• $err${_T_NC}"
        done
        echo ""
        return 1
    fi
    return 0
}
