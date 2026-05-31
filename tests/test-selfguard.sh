#!/bin/bash
# test-selfguard.sh - Tests for sentry-selfguard.sh meta-hash chain protection
# Validates: baseline creation, meta-hash chain, tamper detection, re-baseline

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"

test_isolate

# Override log dir for selfguard
export SENTRY_LOG_DIR="$_T_ISOLATION_DIR/logs"
export SENTRY_SELFLOG="$SENTRY_LOG_DIR/selfguard.log"
mkdir -p "$SENTRY_LOG_DIR"

# Helper: run selfguard with isolated env
selfguard() {
    bash "$PROJECT_DIR/sentry-selfguard.sh" "$@" 2>&1
}

# Helper: get the hash of a file using the same logic as selfguard
_file_hash() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

BASELINE_FILE="$SENTRY_HOME/sentry-baseline.sha256"
META_FILE="$SENTRY_HOME/sentry-baseline.sha256.meta"
META_META_FILE="$SENTRY_HOME/sentry-baseline.sha256.metahash"

# =============================================================================
test_suite_begin "selfguard — baseline creation"
# =============================================================================

test_compute_baseline() {
    selfguard baseline >/dev/null
    [[ -f "$BASELINE_FILE" ]]
}
run_test "compute_baseline creates baseline file" test_compute_baseline

test_meta_file_created() {
    [[ -f "$META_FILE" ]]
}
run_test "compute_baseline creates meta file" test_meta_file_created

test_metahash_file_created() {
    [[ -f "$META_META_FILE" ]]
}
run_test "compute_baseline creates metahash file" test_metahash_file_created

test_baseline_has_entries() {
    local count
    count=$(grep -v '^#' "$BASELINE_FILE" | grep -v '^$' | wc -l | tr -d ' ')
    (( count > 0 ))
}
run_test "baseline file contains file hashes" test_baseline_has_entries

test_meta_file_has_baseline_hash() {
    grep -q "sentry-baseline.sha256" "$META_FILE"
}
run_test "meta file references baseline filename" test_meta_file_has_baseline_hash

test_metahash_file_has_meta_hash() {
    grep -q "sentry-baseline.sha256.meta" "$META_META_FILE"
}
run_test "metahash file references meta filename" test_metahash_file_has_meta_hash

test_baseline_permissions() {
    local perms
    if stat -c "%a" "$BASELINE_FILE" >/dev/null 2>&1; then
        perms=$(stat -c "%a" "$BASELINE_FILE")
    else
        perms=$(stat -f "%Lp" "$BASELINE_FILE" 2>/dev/null)
    fi
    [[ "$perms" == "600" || "$perms" == "400" ]]
}
run_test "baseline file has restrictive permissions" test_baseline_permissions

# =============================================================================
test_suite_begin "selfguard — meta-hash chain verification"
# =============================================================================

test_verify_intact_chain() {
    local output
    output=$(selfguard verify)
    echo "$output" | grep -q "Meta-hash chain verified"
}
run_test "verify passes with intact chain" test_verify_intact_chain

test_verify_all_files_ok() {
    local output
    output=$(selfguard verify)
    echo "$output" | grep -q "Tampered/Missing: 0"
}
run_test "verify reports 0 tampered files" test_verify_all_files_ok

test_meta_chain_hash_correct() {
    # Verify the meta file actually contains the correct hash of the baseline
    local expected_hash
    expected_hash=$(_file_hash "$BASELINE_FILE")
    grep -q "$expected_hash" "$META_FILE"
}
run_test "meta file contains correct baseline hash" test_meta_chain_hash_correct

test_metahash_chain_hash_correct() {
    # Verify the metahash file actually contains the correct hash of the meta file
    local expected_hash
    expected_hash=$(_file_hash "$META_FILE")
    grep -q "$expected_hash" "$META_META_FILE"
}
run_test "metahash file contains correct meta hash" test_metahash_chain_hash_correct

# =============================================================================
test_suite_begin "selfguard — baseline tamper detection"
# =============================================================================

test_detect_baseline_tamper() {
    # Tamper with the baseline file (change a hash)
    chmod 600 "$BASELINE_FILE" 2>/dev/null || true
    if [[ "$(uname -s)" == "Darwin" ]]; then
        chflags noschg "$BASELINE_FILE" 2>/dev/null || true
    fi
    sed -i '' 's/^[a-f0-9]/X/' "$BASELINE_FILE" 2>/dev/null || \
        sed -i 's/^[a-f0-9]/X/' "$BASELINE_FILE" 2>/dev/null || true

    local output
    output=$(selfguard verify)
    echo "$output" | grep -qi "TAMPER\|BROKEN\|fail"
}
run_test "detects baseline file tampering" test_detect_baseline_tamper

# Restore clean state
selfguard baseline >/dev/null 2>&1 || true

test_detect_meta_tamper() {
    # Tamper with the meta file
    chmod 600 "$META_FILE" 2>/dev/null || true
    if [[ "$(uname -s)" == "Darwin" ]]; then
        chflags noschg "$META_FILE" 2>/dev/null || true
    fi
    echo "TAMPERED" >> "$META_FILE"

    local output
    output=$(selfguard verify)
    echo "$output" | grep -qi "TAMPER\|BROKEN\|fail"
}
run_test "detects meta file tampering" test_detect_meta_tamper

# Restore clean state
selfguard baseline >/dev/null 2>&1 || true

test_detect_metahash_tamper() {
    # Tamper with the metahash file
    chmod 600 "$META_META_FILE" 2>/dev/null || true
    if [[ "$(uname -s)" == "Darwin" ]]; then
        chflags noschg "$META_META_FILE" 2>/dev/null || true
    fi
    echo "TAMPERED" >> "$META_META_FILE"

    local output
    output=$(selfguard verify)
    echo "$output" | grep -qi "TAMPER\|CORRUPT\|fail"
}
run_test "detects metahash file tampering" test_detect_metahash_tamper

# Restore clean state
selfguard baseline >/dev/null 2>&1 || true

test_detect_baseline_deletion() {
    # Remove the baseline file
    chmod 600 "$BASELINE_FILE" 2>/dev/null || true
    if [[ "$(uname -s)" == "Darwin" ]]; then
        chflags noschg "$BASELINE_FILE" 2>/dev/null || true
    fi
    rm -f "$BASELINE_FILE"

    local output
    output=$(selfguard verify)
    echo "$output" | grep -qi "MISSING\|No baseline\|fail"
}
run_test "detects baseline file deletion" test_detect_baseline_deletion

# Restore clean state
selfguard baseline >/dev/null 2>&1 || true

test_detect_meta_deletion() {
    # Remove the meta file
    chmod 600 "$META_FILE" 2>/dev/null || true
    if [[ "$(uname -s)" == "Darwin" ]]; then
        chflags noschg "$META_FILE" 2>/dev/null || true
    fi
    rm -f "$META_FILE"

    local output exit_code=0
    output=$(selfguard verify) || exit_code=$?
    # Should fail or warn about missing meta
    (( exit_code != 0 )) || echo "$output" | grep -qi "MISSING\|unprotected"
}
run_test "detects meta file deletion" test_detect_meta_deletion

# Restore clean state
selfguard baseline >/dev/null 2>&1 || true

# =============================================================================
test_suite_begin "selfguard — re-baseline and idempotency"
# =============================================================================

test_rebaseline_works() {
    # Ensure clean state first
    selfguard baseline >/dev/null 2>&1 || true
    # Running baseline twice should work (immutable flags are cleared)
    selfguard baseline >/dev/null 2>&1 || true
    selfguard baseline >/dev/null 2>&1 || true
    [[ -f "$BASELINE_FILE" && -f "$META_FILE" && -f "$META_META_FILE" ]]
}
run_test "re-baseline works (clears immutable flags)" test_rebaseline_works

test_verify_after_rebaseline() {
    # Fresh baseline + verify
    selfguard baseline >/dev/null 2>&1 || true
    local output exit_code=0
    output=$(selfguard verify) || exit_code=$?
    if (( exit_code != 0 )); then
        echo "$output" >&2
    fi
    (( exit_code == 0 ))
}
run_test "verify passes after re-baseline" test_verify_after_rebaseline

# =============================================================================
test_suite_begin "selfguard — status reporting"
# =============================================================================

test_status_shows_meta_chain() {
    local output
    output=$(selfguard status)
    echo "$output" | grep -q "Meta-hash chain"
}
run_test "status shows meta-hash chain info" test_status_shows_meta_chain

test_status_shows_chain_intact() {
    # Ensure clean state
    selfguard baseline >/dev/null 2>&1 || true
    local output
    output=$(selfguard status)
    echo "$output" | grep -q "INTACT"
}
run_test "status reports chain INTACT when healthy" test_status_shows_chain_intact

# =============================================================================
test_suite_begin "selfguard — lockfile mechanism"
# =============================================================================

test_lockfile_created_during_baseline() {
    # Ensure clean state
    selfguard baseline >/dev/null 2>&1 || true
    # The lockfile should NOT exist after baseline completes
    local lock="$SENTRY_LOG_DIR/selfguard-baseline.lock"
    rm -f "$lock" 2>/dev/null || true
    selfguard baseline >/dev/null 2>&1 || true
    [[ ! -f "$lock" ]]
}
run_test "lockfile is cleaned up after baseline" test_lockfile_created_during_baseline

# =============================================================================

test_cleanup
test_report
