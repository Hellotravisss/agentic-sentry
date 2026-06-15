#!/bin/bash
# fswatch aggressive event-driven monitor for Agentic Sentry
# Triggers physical enforcement immediately on dangerous file operations
# Now also passes PID hints to enforcement for targeted process freezing (kill -STOP)
# Robust path handling for spaces, macOS event flags, error handling
# Requires: brew install fswatch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Home resolution (keep in sync with sentry-config.sh)
if [[ -z "${SENTRY_HOME:-}" ]]; then
    if [[ -f "$HOME/.agentsentry/sentry-config.json" ]]; then
        SENTRY_HOME="$HOME/.agentsentry"
    elif [[ -f "$HOME/.hermes/sentry-config.json" ]]; then
        SENTRY_HOME="$HOME/.hermes"
    else
        SENTRY_HOME="$HOME/.agentsentry"
    fi
fi
SAFETY_RULES="${SAFETY_RULES:-$SENTRY_HOME/safety-rules.json}"
ENFORCEMENT_SCRIPT="${ENFORCEMENT_SCRIPT:-$SCRIPT_DIR/enforcement_recovery_module.sh}"
AUDIT_LOG="${AUDIT_LOG:-/tmp/sandbox-audit.log}"
SENTRY_DIR="$SCRIPT_DIR"

# Load unified structured logger
if [[ -f "$SCRIPT_DIR/sentry-logger.sh" ]]; then
    source "$SCRIPT_DIR/sentry-logger.sh"
fi

if ! command -v fswatch >/dev/null 2>&1; then
    echo "ERROR: fswatch not installed."
    echo "Please run: brew install fswatch"
    exit 1
fi

# Load sensitive paths (expand ~ and $HOME)
if [[ -f "$SAFETY_RULES" ]] && command -v jq >/dev/null 2>&1; then
    mapfile -t SENSITIVE_PATHS < <(jq -r '.sensitive_paths[]' "$SAFETY_RULES" | sed "s|\$HOME|$HOME|g; s|~|$HOME|g")
else
    SENSITIVE_PATHS=("$HOME/.ssh" "$HOME/.gnupg" "$HOME/Library/Keychains" "/etc" "/System" "/private/etc" "/private/var/db")
fi

echo "=== Agentic Sentry (Aggressive fswatch Mode) ==="
echo "Monitoring sensitive paths for dangerous file operations..."
echo "Paths: ${SENSITIVE_PATHS[*]}"
echo "Any rm/chmod/chown on these paths will trigger immediate network cut + process sleep."
echo ""

# Robust event parser: handles paths with spaces by stripping trailing event flags (macOS + Linux)
parse_fswatch_line() {
    local line="$1"
    # macOS fswatch events: PlatformSpecific, Removed, Renamed, Updated, Attribute Modified, Created, Moved, etc.
    local event_regex=' (Removed|Renamed|Updated|Attribute Modified|PlatformSpecific|Created|Moved|IsDir|IsFile)'
    if [[ "$line" =~ $event_regex ]]; then
        path="${line%%$event_regex*}"  # everything before first event
        events="${line#*${path} }"
    else
        path="$line"
        events="Unknown"
    fi
    echo "$path|$events"
}

# Self-protection: also watch the sentry scripts themselves (P3)
ALL_PATHS=("${SENSITIVE_PATHS[@]}" "$SENTRY_DIR" "$SENTRY_HOME")

# Use fswatch with null-delim where possible, but -x for events; robust parse
fswatch -r -x --event-flags "${ALL_PATHS[@]}" 2>/dev/null | while IFS= read -r line; do
    parsed=$(parse_fswatch_line "$line")
    path="${parsed%%|*}"
    events="${parsed#*|}"

    if echo "$events" | grep -qE 'Removed|Renamed|Updated|Attribute Modified|PlatformSpecific|Created'; then
        reason="fswatch: dangerous file operation ($events) on $path"

        echo "[AGGRESSIVE] $reason"
        if command -v sentry_log >/dev/null 2>&1; then
            sentry_log "ENFORCED" "$reason" "fswatch" "{\"path\":\"$path\",\"events\":\"$events\"}"
        else
            echo "{\"ts\":\"$(date -Iseconds)\",\"event\":\"fswatch\",\"path\":\"$path\",\"events\":\"$events\",\"decision\":\"ENFORCED\"}" >> "$AUDIT_LOG"
        fi
        logger -t sandbox-sentry "$reason"

        # Try to capture PIDs that currently have the path (or its dir) open — helps targeted freezing
        local pids_hint
        pids_hint=$(lsof -t "$path" 2>/dev/null | head -4 || true)
        if [[ -z "$pids_hint" && -d "$path" ]]; then
            pids_hint=$(lsof -t +D "$path" 2>/dev/null | head -5 || true)
        elif [[ -z "$pids_hint" ]]; then
            pids_hint=$(lsof -t +D "$(dirname "$path")" 2>/dev/null | head -5 || true)
        fi

        # Immediately trigger physical enforcement (pass pids_hint as 2nd arg for process freeze)
        if [[ -x "$ENFORCEMENT_SCRIPT" ]]; then
            "$ENFORCEMENT_SCRIPT" enforce "$reason" "$pids_hint" || echo "Enforcement failed (non-fatal)"
        else
            echo "ERROR: Enforcement script not found or not executable at $ENFORCEMENT_SCRIPT!"
            # Fallback inline
            sudo networksetup -setairportpower "$(networksetup -listallhardwareports | awk '/Wi-Fi/{getline;print $2}')" off 2>/dev/null || true
        fi
    fi
done
