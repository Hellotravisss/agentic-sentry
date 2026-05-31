#!/bin/bash
# test-logger.sh - Tests for sentry-logger.sh structured logging and lock robustness
# Validates: sentry_log(), _acquire_log_lock(), _release_log_lock(), rotation, lock timeout/stale

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"

# --- Isolation ---
TEST_LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sentry-logger-test.XXXXXX")
export SENTRY_LOG_DIR="$TEST_LOG_DIR"
export SENTRY_AUDIT_LOG="$TEST_LOG_DIR/sandbox-audit.log"
export SENTRY_ENFORCE_LOG="$TEST_LOG_DIR/enforcement.log"
export SENTRY_SELFLOG="$TEST_LOG_DIR/selfguard.log"
export SENTRY_LOG_MAX_SIZE=1024       # 1KB for rotation tests
export SENTRY_LOG_MAX_FILES=3
export SENTRY_LOG_COMPRESS=false      # no gzip in tests
export SENTRY_LOCK_TIMEOUT=3
export SENTRY_LOCK_STALE_AGE=2        # 2s stale age for fast tests
export SENTRY_LOCK_RETRY_US=50000     # 50ms retry interval

# Source the logger (but don't execute the main block)
source "$PROJECT_DIR/sentry-logger.sh" 2>/dev/null || true

# Override ensure_log_dir to use our test dir
ensure_log_dir() {
    mkdir -p "$SENTRY_LOG_DIR" 2>/dev/null || true
}

cleanup_test() {
    rm -rf "$TEST_LOG_DIR" 2>/dev/null || true
    test_cleanup
}
trap cleanup_test EXIT

# ==============================================================================
# Suite 1: Basic sentry_log functionality
# ==============================================================================
test_suite_begin "sentry_log basic functionality"

# Test 1: sentry_log writes JSON to audit log
test_sentry_log_basic() {
    sentry_log "TEST" "basic write test" "hooks"
    [[ -f "$SENTRY_AUDIT_LOG" ]] && grep -q '"decision":"TEST"' "$SENTRY_AUDIT_LOG"
}
run_test "sentry_log writes JSON to audit log" test_sentry_log_basic

# Test 2: sentry_log includes required JSON fields
test_sentry_log_fields() {
    sentry_log "DETECTED" "field test" "hooks"
    local last_line
    last_line=$(tail -1 "$SENTRY_AUDIT_LOG")
    echo "$last_line" | grep -q '"ts":' && \
    echo "$last_line" | grep -q '"host":' && \
    echo "$last_line" | grep -q '"pid":' && \
    echo "$last_line" | grep -q '"component":"hooks"' && \
    echo "$last_line" | grep -q '"severity":"warning"'
}
run_test "sentry_log includes required JSON fields" test_sentry_log_fields

# Test 3: severity mapping - critical for BLOCKED
test_severity_critical() {
    sentry_log "SOFT_BLOCKED" "should be critical" "hooks"
    tail -1 "$SENTRY_AUDIT_LOG" | grep -q '"severity":"critical"'
}
run_test "severity=critical for BLOCKED decisions" test_severity_critical

# Test 4: severity mapping - info for normal
test_severity_info() {
    sentry_log "ALLOWED" "should be info" "hooks"
    tail -1 "$SENTRY_AUDIT_LOG" | grep -q '"severity":"info"'
}
run_test "severity=info for normal decisions" test_severity_info

# Test 5: component routing - enforcement goes to enforcement log
test_component_enforcement() {
    sentry_log "ENFORCED" "network cut" "enforcement"
    [[ -f "$SENTRY_ENFORCE_LOG" ]] && grep -q '"decision":"ENFORCED"' "$SENTRY_ENFORCE_LOG"
}
run_test "enforcement component routes to enforcement log" test_component_enforcement

# Test 6: component routing - selfguard goes to selfguard log
test_component_selfguard() {
    sentry_log "TAMPER" "script modified" "selfguard"
    [[ -f "$SENTRY_SELFLOG" ]] && grep -q '"decision":"TAMPER"' "$SENTRY_SELFLOG"
}
run_test "selfguard component routes to selfguard log" test_component_selfguard

# Test 7: extra JSON fields are merged
test_extra_json() {
    sentry_log "TEST" "extra fields" "hooks" '{"custom_field":"hello"}'
    tail -1 "$SENTRY_AUDIT_LOG" | grep -q '"custom_field":"hello"'
}
run_test "extra JSON fields are merged into output" test_extra_json

test_suite_end

# ==============================================================================
# Suite 2: Lock acquire/release
# ==============================================================================
test_suite_begin "Lock acquire/release"

# Test 8: acquire succeeds on fresh lock dir
test_lock_acquire_fresh() {
    local test_lock="$TEST_LOG_DIR/test-fresh.lockdir"
    rm -rf "$test_lock" 2>/dev/null || true
    _acquire_log_lock "$test_lock"
    local rc=$?
    _release_log_lock "$test_lock"
    [[ $rc -eq 0 ]]
}
run_test "acquire succeeds on fresh lock dir" test_lock_acquire_fresh

# Test 9: acquire writes PID file
test_lock_pid_written() {
    local test_lock="$TEST_LOG_DIR/test-pid.lockdir"
    rm -rf "$test_lock" 2>/dev/null || true
    _acquire_log_lock "$test_lock"
    [[ -f "$test_lock/pid" ]]
    local written_pid
    written_pid=$(cat "$test_lock/pid")
    _release_log_lock "$test_lock"
    [[ "$written_pid" == "$$" ]]
}
run_test "acquire writes PID file with current PID" test_lock_pid_written

# Test 10: release removes lock dir
test_lock_release() {
    local test_lock="$TEST_LOG_DIR/test-release.lockdir"
    rm -rf "$test_lock" 2>/dev/null || true
    _acquire_log_lock "$test_lock"
    _release_log_lock "$test_lock"
    [[ ! -d "$test_lock" ]]
}
run_test "release removes lock dir" test_lock_release

# Test 11: release is idempotent (doesn't error on missing dir)
test_lock_release_idempotent() {
    local test_lock="$TEST_LOG_DIR/test-nodir.lockdir"
    rm -rf "$test_lock" 2>/dev/null || true
    _release_log_lock "$test_lock"
    [[ $? -eq 0 ]]
}
run_test "release is idempotent on missing dir" test_lock_release_idempotent

# Test 12: acquire fails when lock held by live process (with short timeout)
test_lock_contention() {
    local test_lock="$TEST_LOG_DIR/test-contention.lockdir"
    rm -rf "$test_lock" 2>/dev/null || true

    # Create a lock held by a background process that stays alive
    mkdir -p "$test_lock"
    # Write a PID of a long-lived process (init/launchd PID 1)
    echo "1" > "$test_lock/pid"

    # Try to acquire with 1s timeout (should fail because PID 1 is alive)
    SENTRY_LOCK_TIMEOUT=1 _acquire_log_lock "$test_lock"
    local rc=$?
    rm -rf "$test_lock"
    [[ $rc -ne 0 ]]
}
run_test "acquire times out when lock held by live process" test_lock_contention

# Test 13: acquire reclaims stale lock from dead process
test_lock_stale_reclaim() {
    local test_lock="$TEST_LOG_DIR/test-stale.lockdir"
    rm -rf "$test_lock" 2>/dev/null || true

    # Create a lock with a dead PID and old mtime
    mkdir -p "$test_lock"
    echo "99999" > "$test_lock/pid"  # very unlikely to exist
    # Backdate the lock dir mtime to 60 seconds ago (well past stale_age=2)
    touch -t "$(date -v-60S +%Y%m%d%H%M.%S 2>/dev/null || date -d '60 seconds ago' +%Y%m%d%H%M.%S 2>/dev/null)" "$test_lock" 2>/dev/null || \
        touch -d "60 seconds ago" "$test_lock" 2>/dev/null || true

    SENTRY_LOCK_STALE_AGE=2 SENTRY_LOCK_TIMEOUT=3 _acquire_log_lock "$test_lock"
    local rc=$?
    _release_log_lock "$test_lock"
    [[ $rc -eq 0 ]]
}
run_test "acquire reclaims stale lock from dead process" test_lock_stale_reclaim

# Test 14: acquire reclaims lock dir with no PID file (old-format lock)
test_lock_no_pid_reclaim() {
    local test_lock="$TEST_LOG_DIR/test-nopid.lockdir"
    rm -rf "$test_lock" 2>/dev/null || true

    # Create lock dir without PID file, backdate it
    mkdir -p "$test_lock"
    touch -t "$(date -v-60S +%Y%m%d%H%M.%S 2>/dev/null || date -d '60 seconds ago' +%Y%m%d%H%M.%S 2>/dev/null)" "$test_lock" 2>/dev/null || \
        touch -d "60 seconds ago" "$test_lock" 2>/dev/null || true

    SENTRY_LOCK_STALE_AGE=2 SENTRY_LOCK_TIMEOUT=3 _acquire_log_lock "$test_lock"
    local rc=$?
    _release_log_lock "$test_lock"
    [[ $rc -eq 0 ]]
}
run_test "acquire reclaims old-format lock dir (no PID file)" test_lock_no_pid_reclaim

# Test 15: sequential acquire-release-acquire works
test_lock_reentrant() {
    local test_lock="$TEST_LOG_DIR/test-reentrant.lockdir"
    rm -rf "$test_lock" 2>/dev/null || true

    _acquire_log_lock "$test_lock"
    _release_log_lock "$test_lock"
    _acquire_log_lock "$test_lock"
    local rc=$?
    _release_log_lock "$test_lock"
    [[ $rc -eq 0 ]]
}
run_test "sequential acquire-release-acquire works" test_lock_reentrant

test_suite_end

# ==============================================================================
# Suite 3: Concurrent writes (high-concurrency scenario)
# ==============================================================================
test_suite_begin "Concurrent write safety"

# Test 16: Multiple parallel sentry_log calls don't corrupt output
test_concurrent_writes() {
    local concurrent_log="$TEST_LOG_DIR/concurrent-test.log"
    local concurrent_lock="${concurrent_log}.lockdir"
    rm -f "$concurrent_log" 2>/dev/null || true
    rm -rf "$concurrent_lock" 2>/dev/null || true

    # Override target log for this test
    local num_writers=10
    local pids=()

    for i in $(seq 1 $num_writers); do
        (
            # Each subshell sources the logger and writes
            source "$PROJECT_DIR/sentry-logger.sh" 2>/dev/null || true
            SENTRY_LOG_DIR="$TEST_LOG_DIR"
            SENTRY_AUDIT_LOG="$concurrent_log"
            SENTRY_LOCK_TIMEOUT=5
            SENTRY_LOCK_STALE_AGE=2
            SENTRY_LOCK_RETRY_US=50000
            sentry_log "CONCURRENT_$i" "writer $i" "test"
        ) &
        pids+=($!)
    done

    # Wait for all writers
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Check: should have exactly num_writers lines, each valid JSON
    local line_count
    line_count=$(wc -l < "$concurrent_log" | tr -d ' ')
    [[ "$line_count" -eq "$num_writers" ]]
}
run_test "10 concurrent writers produce exactly 10 log lines" test_concurrent_writes

# Test 17: No interleaved/corrupt JSON lines after concurrent writes
test_concurrent_json_valid() {
    local concurrent_log="$TEST_LOG_DIR/concurrent-test.log"
    [[ ! -f "$concurrent_log" ]] && skip_test "concurrent json" "no log file" && return 0

    local invalid=0
    while IFS= read -r line; do
        # Each line should be valid JSON (basic check: starts with { and ends with })
        if ! echo "$line" | grep -qE '^\{.*\}$'; then
            ((invalid++)) || true
        fi
    done < "$concurrent_log"

    [[ "$invalid" -eq 0 ]]
}
run_test "all concurrent log lines are valid JSON (no interleaving)" test_concurrent_json_valid

# Test 18: Lock dir is cleaned up after concurrent writes
test_concurrent_lock_cleanup() {
    local concurrent_lock="$TEST_LOG_DIR/concurrent-test.log.lockdir"
    [[ ! -d "$concurrent_lock" ]]
}
run_test "lock dir is cleaned up after concurrent writes" test_concurrent_lock_cleanup

test_suite_end

# ==============================================================================
# Suite 4: Log rotation
# ==============================================================================
test_suite_begin "Log rotation"

# Test 19: rotate_log rotates when file exceeds max size
test_rotation_on_size() {
    local rot_log="$TEST_LOG_DIR/rotation-test.log"
    rm -f "$rot_log" "${rot_log}".* 2>/dev/null || true

    # Write data exceeding 1KB
    dd if=/dev/urandom bs=1 count=1100 2>/dev/null | base64 > "$rot_log"

    rotate_log "$rot_log" 1024 3

    # Original should be empty (fresh), rotated file should exist
    local original_size
    original_size=$(wc -c < "$rot_log" 2>/dev/null | tr -d ' ' || echo 0)
    local rotated_count
    rotated_count=$(ls -1 "${rot_log}".* 2>/dev/null | wc -l | tr -d ' ' || echo 0)

    [[ "$original_size" -eq 0 ]] && [[ "$rotated_count" -ge 1 ]]
}
run_test "rotate_log rotates when file exceeds max size" test_rotation_on_size

# Test 20: rotate_log respects max_files limit
test_rotation_max_files() {
    local rot_log="$TEST_LOG_DIR/rotation-maxfiles.log"
    rm -f "$rot_log" "${rot_log}".* 2>/dev/null || true

    # Create 4 pre-existing rotated files (exceeds max of 3)
    for i in 1 2 3 4; do
        echo "old rotated file $i" > "${rot_log}.2026010${i}-120000"
    done

    # Write data exceeding threshold
    dd if=/dev/urandom bs=1 count=1100 2>/dev/null | base64 > "$rot_log"

    rotate_log "$rot_log" 1024 3

    local rotated_count
    rotated_count=$(ls -1 "${rot_log}".* 2>/dev/null | wc -l | tr -d ' ') || rotated_count=0

    # Should have at most 3 rotated files after rotation
    [[ "$rotated_count" -le 3 ]]
}
run_test "rotate_log respects max_files limit" test_rotation_max_files

# Test 21: rotate_log is no-op when file is under max size
test_rotation_noop_small() {
    local rot_log="$TEST_LOG_DIR/rotation-noop.log"
    rm -f "$rot_log" "${rot_log}".* 2>/dev/null || true
    echo "small file" > "$rot_log"

    rotate_log "$rot_log" 1024 3

    local rotated_count
    rotated_count=$(ls -1 "${rot_log}".* 2>/dev/null | wc -l | tr -d ' ') || rotated_count=0
    [[ "$rotated_count" -eq 0 ]]
}
run_test "rotate_log is no-op when file is under max size" test_rotation_noop_small

# Test 22: rotate_all_logs rotates all three log files
test_rotate_all() {
    # Fill all logs past threshold
    dd if=/dev/urandom bs=1 count=1100 2>/dev/null | base64 > "$SENTRY_AUDIT_LOG"
    dd if=/dev/urandom bs=1 count=1100 2>/dev/null | base64 > "$SENTRY_ENFORCE_LOG"
    dd if=/dev/urandom bs=1 count=1100 2>/dev/null | base64 > "$SENTRY_SELFLOG"

    rotate_all_logs

    local a_size e_size s_size
    a_size=$(wc -c < "$SENTRY_AUDIT_LOG" 2>/dev/null | tr -d ' ' || echo 0)
    e_size=$(wc -c < "$SENTRY_ENFORCE_LOG" 2>/dev/null | tr -d ' ' || echo 0)
    s_size=$(wc -c < "$SENTRY_SELFLOG" 2>/dev/null | tr -d ' ' || echo 0)

    [[ "$a_size" -eq 0 ]] && [[ "$e_size" -eq 0 ]] && [[ "$s_size" -eq 0 ]]
}
run_test "rotate_all_logs rotates all three log files" test_rotate_all

test_suite_end

# ==============================================================================
# Suite 5: get_log_stats and edge cases
# ==============================================================================
test_suite_begin "Log stats and edge cases"

# Test 23: get_log_stats returns valid JSON
test_stats_json() {
    sentry_log "STATS_TEST" "stats check" "hooks"
    local stats
    stats=$(get_log_stats "$SENTRY_AUDIT_LOG")
    echo "$stats" | grep -qE '^\{.*"total":[0-9]+.*\}$'
}
run_test "get_log_stats returns valid JSON" test_stats_json

# Test 24: get_log_stats handles missing file
test_stats_missing() {
    local stats
    stats=$(get_log_stats "$TEST_LOG_DIR/nonexistent.log")
    echo "$stats" | grep -q '"total":0'
}
run_test "get_log_stats handles missing file" test_stats_missing

# Test 25: sentry_log with special characters in reason
test_special_chars() {
    sentry_log "TEST" 'reason with "quotes" and \\backslash' "hooks"
    local last_line
    last_line=$(tail -1 "$SENTRY_AUDIT_LOG")
    # Should still be valid JSON (escaped properly)
    echo "$last_line" | grep -qE '^\{.*\}$'
}
run_test "sentry_log handles special characters in reason" test_special_chars

# Test 26: sentry_log with empty extra_json
test_empty_extra() {
    sentry_log "TEST" "empty extra" "hooks" ""
    local last_line
    last_line=$(tail -1 "$SENTRY_AUDIT_LOG")
    echo "$last_line" | grep -qE '^\{.*\}$'
}
run_test "sentry_log handles empty extra_json" test_empty_extra

# Test 27: lock timeout fallback still writes the log entry
test_timeout_fallback_writes() {
    local fallback_log="$TEST_LOG_DIR/fallback-test.log"
    local fallback_lock="${fallback_log}.lockdir"
    rm -f "$fallback_log" 2>/dev/null || true
    rm -rf "$fallback_lock" 2>/dev/null || true

    # Pre-create a lock held by PID 1 (always alive)
    mkdir -p "$fallback_lock"
    echo "1" > "$fallback_lock/pid"

    # Override target to our test log
    SENTRY_AUDIT_LOG="$fallback_log"
    SENTRY_LOCK_TIMEOUT=1

    sentry_log "FALLBACK" "timeout fallback write" "hooks"

    # The log entry should still be written (via fallback path)
    [[ -f "$fallback_log" ]] && grep -q '"decision":"FALLBACK"' "$fallback_log"
}
run_test "lock timeout fallback still writes the log entry" test_timeout_fallback_writes

test_suite_end

# --- Report ---
test_report
