#!/bin/bash
# run-tests.sh - Main test runner for Agentic Sandbox Sentry
# Runs all test-*.sh files in the tests/ directory and reports aggregate results.
#
# Usage:
#   ./tests/run-tests.sh          # run all tests
#   ./tests/run-tests.sh config   # run only test-config.sh
#   ./tests/run-tests.sh hooks    # run only test-hooks.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     Agentic Sandbox Sentry — Test Suite                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Project: ${BLUE}$PROJECT_DIR${NC}"
echo -e "  Date:    $(date)"
echo -e "  Shell:   ${BASH_VERSION:-unknown}"
echo ""

# Determine which tests to run
FILTER="${1:-}"

# Find test files
if [[ -n "$FILTER" ]]; then
    TEST_FILES=("$SCRIPT_DIR/test-${FILTER}.sh")
    if [[ ! -f "${TEST_FILES[0]}" ]]; then
        echo -e "${RED}Error: test-${FILTER}.sh not found${NC}"
        echo "Available tests:"
        for f in "$SCRIPT_DIR"/test-*.sh; do
            name=$(basename "$f" .sh | sed 's/^test-//')
            echo "  $name"
        done
        exit 1
    fi
else
    TEST_FILES=()
    for f in "$SCRIPT_DIR"/test-*.sh; do
        [[ -f "$f" ]] && TEST_FILES+=("$f")
    done
fi

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    echo -e "${RED}No test files found in $SCRIPT_DIR${NC}"
    exit 1
fi

echo -e "Running ${#TEST_FILES[@]} test file(s)..."
echo ""

# Run each test file and collect results
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
SUITES_RUN=0
SUITES_FAILED=()

for test_file in "${TEST_FILES[@]}"; do
    name=$(basename "$test_file" .sh | sed 's/^test-//')
    echo -e "${BOLD}━━━ test-${name}.sh ━━━${NC}"

    chmod +x "$test_file"

    # Run the test file and capture output + exit code
    output=$(bash "$test_file" 2>&1) || true
    exit_code=$?

    echo "$output"

    # Parse results from the output (look for the Results line)
    pass=$(echo "$output" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo 0)
    fail=$(echo "$output" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo 0)
    skip=$(echo "$output" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+' || echo 0)

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))
    TOTAL_SKIP=$((TOTAL_SKIP + skip))
    ((SUITES_RUN++)) || true

    if (( fail > 0 )); then
        SUITES_FAILED+=("test-${name}.sh ($fail failures)")
    fi

    echo ""
done

# Aggregate report
TOTAL=$((TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP))

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    AGGREGATE RESULTS                     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Suites:   $SUITES_RUN run"
echo -e "  Tests:    $TOTAL total"
echo -e "  ${GREEN}Passed:   $TOTAL_PASS${NC}"
if (( TOTAL_FAIL > 0 )); then
    echo -e "  ${RED}Failed:   $TOTAL_FAIL${NC}"
else
    echo -e "  Failed:   0"
fi
if (( TOTAL_SKIP > 0 )); then
    echo -e "  ${YELLOW}Skipped:  $TOTAL_SKIP${NC}"
else
    echo -e "  Skipped:  0"
fi
echo ""

if (( ${#SUITES_FAILED[@]} > 0 )); then
    echo -e "${RED}Failed suites:${NC}"
    for s in "${SUITES_FAILED[@]}"; do
        echo -e "  ${RED}• $s${NC}"
    done
    echo ""
    echo -e "${RED}TEST SUITE FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"
    exit 0
fi
