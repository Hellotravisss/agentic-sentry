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
SENTRY_LOG_DIR="${SENTRY_LOG_DIR:-$HOME/.hermes/logs}"
SENTRY_AUDIT_LOG="${SENTRY_AUDIT_LOG:-$SENTRY_LOG_DIR/sandbox-audit.log}"
SENTRY_ENFORCE_LOG="${SENTRY_ENFORCE_LOG:-$SENTRY_LOG_DIR/enforcement.log}"
SENTRY_SELFLOG="${SENTRY_SELFLOG:-$SENTRY_LOG_DIR/selfguard.log}"

# Rotation settings
SENTRY_LOG_MAX_SIZE="${SENTRY_LOG_MAX_SIZE:-5242880}"  # 5 MB default
SENTRY_LOG_MAX_FILES="${SENTRY_LOG_MAX_FILES:-5}"       # keep 5 rotated files
SENTRY_LOG_COMPRESS="${SENTRY_LOG_COMPRESS:-true}"       # gzip rotated files

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

        # Shift existing rotated files (remove oldest if over limit)
        local count=0
        local old_files=()
        while IFS= read -r f; do
            old_files+=("$f")
            ((count++))
        done < <(ls -1t "${logfile}".* 2>/dev/null | head -"$max_files")

        # Remove oldest if we'd exceed max_files
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

    # Thread-safe append (flock on Linux, direct on macOS where flock is rare)
    if command -v flock >/dev/null 2>&1; then
        flock -x "$target_log.lock" -c "echo '$json' >> '$target_log'" 2>/dev/null || \
            echo "$json" >> "$target_log"
    else
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
