#!/bin/bash
# run-tests.sh — Top-level CI-friendly test runner for Agentic Sandbox Sentry
#
# Wraps tests/run-tests.sh with CI-aware output, timing, and exit codes.
#
# Usage:
#   ./run-tests.sh              # Run all tests
#   ./run-tests.sh config       # Run only test-config.sh
#   ./run-tests.sh hooks        # Run only test-hooks.sh
#   ./run-tests.sh --ci         # Force CI mode (no colors, stricter output)
#
# Exit codes:
#   0  All tests passed
#   1  One or more tests failed
#   2  Runner error (missing files, bad environment)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="$SCRIPT_DIR/tests"
TEST_RUNNER="$TESTS_DIR/run-tests.sh"

# ── CI detection ──────────────────────────────────────────────────────────
CI_MODE=false
if [[ "${CI:-}" == "true" ]] || [[ -n "${GITHUB_ACTIONS:-}" ]] || [[ "${1:-}" == "--ci" ]]; then
    CI_MODE=true
fi

# Strip --ci from args before passing through
ARGS=()
for arg in "$@"; do
    [[ "$arg" != "--ci" ]] && ARGS+=("$arg")
done

# ── Colors (disabled in CI) ──────────────────────────────────────────────
if [[ "$CI_MODE" == "true" ]] || [[ ! -t 1 ]]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    BOLD=''
    NC=''
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
fi

# ── Preflight checks ─────────────────────────────────────────────────────
if [[ ! -f "$TEST_RUNNER" ]]; then
    echo -e "${RED}Error: test runner not found at $TEST_RUNNER${NC}" >&2
    exit 2
fi

if [[ ! -x "$TEST_RUNNER" ]]; then
    chmod +x "$TEST_RUNNER"
fi

# Check bash version (need 3.2+ — tests use arrays but not associative arrays)
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
BASH_MINOR="${BASH_VERSINFO[1]:-0}"
if (( BASH_MAJOR < 3 )) || { (( BASH_MAJOR == 3 )) && (( BASH_MINOR < 2 )); }; then
    echo -e "${RED}Error: bash 3.2+ required (found ${BASH_VERSION:-unknown})${NC}" >&2
    exit 2
fi

# ── Header ────────────────────────────────────────────────────────────────
echo ""
if [[ "$CI_MODE" == "true" ]]; then
    echo "::group::Agentic Sandbox Sentry — Test Suite (CI mode)"
else
    echo -e "${BOLD}Agentic Sandbox Sentry — Test Suite${NC}"
fi
echo "  Date:  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "  Bash:  ${BASH_VERSION:-unknown}"
echo "  CI:    $CI_MODE"
echo ""

# ── Run tests with timing ────────────────────────────────────────────────
START_TIME=$(date +%s)

bash "$TEST_RUNNER" ${ARGS[@]+"${ARGS[@]}"}
TEST_EXIT=$?

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# ── Footer ────────────────────────────────────────────────────────────────
echo ""
if [[ "$CI_MODE" == "true" ]]; then
    echo "::endgroup::"
fi

if (( TEST_EXIT == 0 )); then
    echo -e "${GREEN}Completed in ${ELAPSED}s — all tests passed.${NC}"
else
    echo -e "${RED}Completed in ${ELAPSED}s — some tests failed.${NC}"
fi

# ── GitHub Actions annotations ───────────────────────────────────────────
if [[ -n "${GITHUB_ACTIONS:-}" ]] && (( TEST_EXIT != 0 )); then
    echo "::error::Test suite failed ($ELAPSED elapsed)"
fi

exit "$TEST_EXIT"
