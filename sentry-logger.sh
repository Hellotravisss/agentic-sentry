#!/bin/bash
# sentry-logger.sh - Unified structured JSON logging with rotation
# All Sentry components source this for consistent, structured log output.
#
# Usage (from other scripts):
#   source "$SCRIPT_DIR/sentry-logger.sh"
#   sentry_log "DECISION" "reason" "component" ["extra_json"]
#
# Features:
#   - Structured JSON log lines with consistent schema
#   - Automatic log rotation (size-based, configurable max files)
#   - Thread-safe append (uses flock when available)
#   - Rich context: ts, hostname, pid, component, severity

set -euo pipefail

# --- Configuration (override via env or sentry-config.json) ---
# Home resolution (keep in sync with sentry-config.sh)
if [[ -z "${SENTRY_LOG_DIR:-}" ]]; then
    if [[ -n "${SENTRY_HOME:-}" ]]; then
        SENTRY_LOG_DIR="$SENTRY_HOME/logs"
    elif [[ -f "$HOME/.agentsentry/sentry-config.json" ]]; then
        SENTRY_LOG_DIR="$HOME/.agentsentry/logs"
    elif [[ -f "$HOME/.hermes/sentry-config.json" ]]; then
        SENTRY_LOG_DIR="$HOME/.hermes/logs"
    else
        SENTRY_LOG_DIR="$HOME/.agentsentry/logs"
    fi
fi
SENTRY_AUDIT_LOG="${SENTRY_AUDIT_LOG:-$SENTRY_LOG_DIR/sandbox-audit.log}"
SENTRY_ENFORCE_LOG="${SENTRY_ENFORCE_LOG:-$SENTRY_LOG_DIR/enforcement.log}"
SENTRY_SELFLOG="${SENTRY_SELFLOG:-$SENTRY_LOG_DIR/selfguard.log}"

# Rotation settings
SENTRY_LOG_MAX_SIZE="${SENTRY_LOG_MAX_SIZE:-5242880}"  # 5 MB default
SENTRY_LOG_MAX_FILES="${SENTRY_LOG_MAX_FILES:-5}"       # keep 5 rotated files
SENTRY_LOG_COMPRESS="${SENTRY_LOG_COMPRESS:-true}"       # gzip rotated files

# Lock settings (mkdir-based portable lock)
SENTRY_LOCK_TIMEOUT="${SENTRY_LOCK_TIMEOUT:-5}"          # seconds to wait for lock
SENTRY_LOCK_STALE_AGE="${SENTRY_LOCK_STALE_AGE:-30}"     # seconds before lock is considered stale
SENTRY_LOCK_RETRY_US="${SENTRY_LOCK_RETRY_US:-100000}"   # microseconds between retries (100ms)

# Hostname cached once
_LOG_HOSTNAME="${_LOG_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"

# --- Ensure log directory exists ---
ensure_log_dir() {
    mkdir -p "$SENTRY_LOG_DIR" 2>/dev/null || true
}

# --- Rotate a single log file if it exceeds max size ---
rotate_log() {
    local logfile="$1"
    local max_size="${2:-$SENTRY_LOG_MAX_SIZE}"
    local max_files="${3:-$SENTRY_LOG_MAX_FILES}"

    [[ ! -f "$logfile" ]] && return 0

    local size
    size=$(wc -c < "$logfile" 2>/dev/null | tr -d ' ' || echo 0)

    if (( size >= max_size )); then
        local ts
        ts=$(date +%Y%m%d-%H%M%S)
        local rotated="${logfile}.${ts}"

        # List ALL existing rotated files sorted by time (newest first)
        local count=0
        local old_files=()
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            old_files+=("$f")
            ((count++)) || true
        done < <(ls -1t "${logfile}".* 2>/dev/null || true)

        # We're about to create one more rotated file, so ensure count+1 <= max_files
        if (( count >= max_files )); then
            local to_remove=$(( count - max_files + 1 ))
            for (( i=count-1; i>=count-to_remove; i-- )); do
                rm -f "${old_files[$i]}" 2>/dev/null || true
            done
        fi

        # Rotate current file
        mv "$logfile" "$rotated" 2>/dev/null || true

        # Compress if enabled
        if [[ "$SENTRY_LOG_COMPRESS" == "true" ]] && command -v gzip >/dev/null 2>&1; then
            gzip -f "$rotated" 2>/dev/null || true
        fi

        # Create fresh empty log
        touch "$logfile"
    fi
}

# --- Rotate all Sentry log files ---
rotate_all_logs() {
    rotate_log "$SENTRY_AUDIT_LOG"
    rotate_log "$SENTRY_ENFORCE_LOG"
    rotate_log "$SENTRY_SELFLOG"
}

# --- Portable mkdir-based lock with timeout and stale cleanup ---
# Always prints a single integer; 0 means "missing or unreadable".
# The path can vanish between any check and the stat call (lock contention),
# and on Linux `stat -f` is filesystem mode that prints non-numeric text —
# any such output fed into bash arithmetic kills the caller under set -eu.
_get_file_mtime() {
    local path="$1"
    local mtime
    mtime=$(stat -c %Y "$path" 2>/dev/null) \
        || mtime=$(stat -f %m "$path" 2>/dev/null) \
        || mtime=""
    if [[ "$mtime" =~ ^[0-9]+$ ]]; then
        echo "$mtime"
    else
        echo 0
    fi
}

# _acquire_log_lock <lock_dir>
#   Returns 0 on success, 1 on timeout.
#   Writes PID file inside the lock dir for stale detection.
#   Checks if the current lock holder is still alive; if not and the lock
#   is older than SENTRY_LOCK_STALE_AGE, reclaims it.
_acquire_log_lock() {
    local lock_dir="$1"
    local timeout="${SENTRY_LOCK_TIMEOUT:-5}"
    local stale_age="${SENTRY_LOCK_STALE_AGE:-30}"
    local retry_us="${SENTRY_LOCK_RETRY_US:-100000}"

    # Convert retry microseconds to seconds for sleep (float)
    local retry_sec
    retry_sec=$(awk "BEGIN {printf \"%.1f\", $retry_us / 1000000}")

    mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || true

    local deadline=$(( SECONDS + timeout ))

    while (( SECONDS < deadline )); do
        # Atomic mkdir — only succeeds if dir doesn't exist
        if mkdir "$lock_dir" 2>/dev/null; then
            # Lock acquired — write our PID for stale detection
            { echo "$$" > "$lock_dir/pid"; } 2>/dev/null || true
            return 0
        fi

        # Lock exists — check if the holder is still alive
        if [[ -f "$lock_dir/pid" ]]; then
            local holder_pid
            holder_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
            if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
                # Holder process is dead — check lock age before reclaiming
                local lock_mtime now lock_age
                lock_mtime=$(_get_file_mtime "$lock_dir")
                if (( lock_mtime == 0 )); then
                    # Lock dir vanished between checks — it was released
                    # normally. NEVER rm -rf here: another writer may have
                    # already re-acquired it, and deleting a live lock breaks
                    # mutual exclusion. Just retry mkdir.
                    continue
                fi
                now=$(date +%s)
                lock_age=$(( now - lock_mtime ))
                if (( lock_age >= stale_age )); then
                    rm -rf "$lock_dir" 2>/dev/null || true
                    continue  # retry acquire on next iteration
                fi
            fi
        else
            # Lock dir exists but no PID file — holder is mid-acquire,
            # mid-release, or crashed before writing its PID
            local lock_mtime now lock_age
            lock_mtime=$(_get_file_mtime "$lock_dir")
            if (( lock_mtime == 0 )); then
                # Same as above: the lock disappeared on its own — a fresh
                # lock created by a competitor right now must not be deleted
                continue
            fi
            now=$(date +%s)
            lock_age=$(( now - lock_mtime ))
            if (( lock_age >= stale_age )); then
                rm -rf "$lock_dir" 2>/dev/null || true
                continue
            fi
        fi

        # Wait before retrying
        sleep "$retry_sec" 2>/dev/null || sleep 1 2>/dev/null || true
    done

    # Timeout — could not acquire lock
    return 1
}

# _release_log_lock <lock_dir>
#   Removes the lock directory and its PID file.
_release_log_lock() {
    local lock_dir="$1"
    # Remove PID file first, then the dir (handles both empty and non-empty cases)
    rm -f "$lock_dir/pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null || true
}

# --- Core structured log function ---
# sentry_log <decision> <reason> <component> [extra_json_fields]
#
# Examples:
#   sentry_log "SOFT_BLOCKED" "sudo outside allowed" "hooks"
#   sentry_log "TAMPER" "sentry script modified" "selfguard" '{"file":"sentryctl"}'
#   sentry_log "ENFORCED" "network cut" "enforcement" '{"iface":"en0"}'
#
# Output JSON schema:
#   {
#     "ts": ISO8601,
#     "host": hostname,
#     "pid": number,
#     "ppid": number,
#     "user": string,
#     "component": string,
#     "decision": string,
#     "severity": "info"|"warning"|"critical",
#     "reason": string,
#     ...extra fields...
#   }
sentry_log() {
    local decision="${1:-UNKNOWN}"
    local reason="${2:-no reason}"
    local component="${3:-unknown}"
    local extra_json="${4:-}"

    ensure_log_dir

    local ts
    ts=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)

    # Determine severity from decision
    local severity="info"
    case "$decision" in
        *BLOCKED*|*ENFORCED*|*HARD*|TAMPER) severity="critical" ;;
        DETECTED|WARNING) severity="warning" ;;
    esac

    # Escape reason and extra for JSON (handle quotes, backslashes)
    local safe_reason
    safe_reason=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g')

    # Build the base JSON
    local json
    json=$(printf '{"ts":"%s","host":"%s","pid":%d,"ppid":%d,"user":"%s","component":"%s","decision":"%s","severity":"%s","reason":"%s"' \
        "$ts" \
        "$_LOG_HOSTNAME" \
        "$$" \
        "${PPID:-0}" \
        "${USER:-$(whoami)}" \
        "$component" \
        "$decision" \
        "$severity" \
        "$safe_reason")

    # Append extra JSON fields if provided
    if [[ -n "$extra_json" ]]; then
        # Strip leading { and merge
        local stripped
        stripped=$(echo "$extra_json" | sed 's/^{//' | sed 's/}$//')
        if [[ -n "$stripped" ]]; then
            json="${json},${stripped}"
        fi
    fi

    json="${json}}"

    # Choose target log file based on component
    local target_log="$SENTRY_AUDIT_LOG"
    case "$component" in
        enforcement|enforce) target_log="$SENTRY_ENFORCE_LOG" ;;
        selfguard|tamper)    target_log="$SENTRY_SELFLOG" ;;
    esac

    # Thread-safe append using portable mkdir lock with timeout and stale cleanup
    local lock_dir="${target_log}.lockdir"

    if _acquire_log_lock "$lock_dir"; then
        # Lock acquired — write under lock, then release
        echo "$json" >> "$target_log"
        _release_log_lock "$lock_dir"
    else
        # Timeout: lock could not be acquired. Force-cleanup stale lock and write.
        rm -rf "$lock_dir" 2>/dev/null || true
        echo "$json" >> "$target_log"
    fi

    # Opportunistic rotation check (every ~20 writes, not every call)
    local counter_file="$SENTRY_LOG_DIR/.rotate_counter"
    local count=0
    if [[ -f "$counter_file" ]]; then
        count=$(cat "$counter_file" 2>/dev/null || echo 0)
    fi
    count=$(( (count + 1) % 20 ))
    echo "$count" > "$counter_file" 2>/dev/null || true
    if (( count == 0 )); then
        rotate_all_logs 2>/dev/null || true
    fi
}

# --- Convenience: log from hooks (compatible with existing log_sentry_event API) ---
# log_sentry_event <decision> <reason> <cmd> <cwd>
log_sentry_event() {
    local decision="$1"
    local reason="$2"
    local cmd="${3:-}"
    local cwd="${4:-}"

    local mode="${SENTRY_MODE:-unknown}"
    local extra
    extra=$(printf '{"cmd":"%s","cwd":"%s","mode":"%s","shell":"%s"}' \
        "$(echo "$cmd" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
        "$(echo "$cwd" | sed 's/\\/\\\\/g; s/"/\\"/g')" \
        "$mode" \
        "${SHELL:-zsh}")

    sentry_log "$decision" "$reason" "hooks" "$extra"
}

# --- Convenience: log enforcement events ---
# log_enforcement <action> <reason> [extra_json]
log_enforcement() {
    local action="$1"
    local reason="$2"
    local extra="${3:-}"
    sentry_log "$action" "$reason" "enforcement" "$extra"
}

# --- Convenience: log self-protection events ---
# log_selfguard <event_type> <reason> [extra_json]
log_selfguard() {
    local event_type="$1"
    local reason="$2"
    local extra="${3:-}"
    sentry_log "$event_type" "$reason" "selfguard" "$extra"
}

# --- Log statistics helper ---
get_log_stats() {
    local log_file="${1:-$SENTRY_AUDIT_LOG}"
    [[ ! -f "$log_file" ]] && echo '{"total":0,"size_bytes":0}' && return

    local total size_bytes rotated_count
    total=$(wc -l < "$log_file" 2>/dev/null | xargs 2>/dev/null || echo 0)
    size_bytes=$(wc -c < "$log_file" 2>/dev/null | xargs 2>/dev/null || echo 0)
    rotated_count=0
    local rot_files
    rot_files=$(ls -1 "${log_file}".* 2>/dev/null || true)
    if [[ -n "$rot_files" ]]; then
        rotated_count=$(echo "$rot_files" | wc -l | xargs 2>/dev/null || echo 0)
    fi

    printf '{"total":%d,"size_bytes":%d,"rotated_files":%d,"max_size":%d,"log_file":"%s"}' \
        "$total" "$size_bytes" "$rotated_count" "$SENTRY_LOG_MAX_SIZE" "$log_file"
}

# --- Run rotation manually ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-rotate}" in
        rotate)
            echo "Rotating all Sentry logs..."
            rotate_all_logs
            echo "Done."
            ;;
        stats)
            echo "=== Audit Log Stats ==="
            get_log_stats "$SENTRY_AUDIT_LOG" | jq . 2>/dev/null || get_log_stats "$SENTRY_AUDIT_LOG"
            echo ""
            echo "=== Enforcement Log Stats ==="
            get_log_stats "$SENTRY_ENFORCE_LOG" | jq . 2>/dev/null || get_log_stats "$SENTRY_ENFORCE_LOG"
            echo ""
            echo "=== Selfguard Log Stats ==="
            get_log_stats "$SENTRY_SELFLOG" | jq . 2>/dev/null || get_log_stats "$SENTRY_SELFLOG"
            ;;
        test)
            echo "Writing test log entry..."
            sentry_log "TEST" "test log entry from sentry-logger.sh" "test" '{"test":true}'
            echo "Written to $SENTRY_AUDIT_LOG"
            ;;
        *)
            echo "Usage: $0 {rotate|stats|test}"
            ;;
    esac
fi
