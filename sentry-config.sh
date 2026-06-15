#!/bin/bash
# sentry-config.sh - Central configuration loader for Agentic Sentry (Route C)
# Provides unified access to operational settings (mode, notifications, paths, etc.)

set -euo pipefail

# Default locations.
# Home resolution (keep in sync with sentry-logger.sh / enforcement /
# selfguard): env override > existing ~/.agentsentry > legacy ~/.hermes
# (pre-0.1.5 default, which collides with Hermes Agent's config dir) >
# fresh ~/.agentsentry. 'sentryctl migrate-home' moves legacy data over.
if [[ -z "${SENTRY_HOME:-}" ]]; then
    if [[ -f "$HOME/.agentsentry/sentry-config.json" ]]; then
        SENTRY_HOME="$HOME/.agentsentry"
    elif [[ -f "$HOME/.hermes/sentry-config.json" ]]; then
        SENTRY_HOME="$HOME/.hermes"
    else
        SENTRY_HOME="$HOME/.agentsentry"
    fi
fi
SENTRY_CONFIG="${SENTRY_CONFIG:-$SENTRY_HOME/sentry-config.json}"
SAFETY_RULES="${SAFETY_RULES:-$SENTRY_HOME/safety-rules.json}"

# Default values (used if config file is missing or incomplete)
DEFAULT_MODE="soft-block"           # audit | warn | dry-run | soft-block | hard
DEFAULT_NOTIFICATIONS="true"
# Persistent location under the Sentry home for durability
DEFAULT_AUDIT_LOG="$SENTRY_HOME/logs/sandbox-audit.log"

# Load configuration (with sensible defaults)
load_sentry_config() {
    local mode notifications audit_log

    if [[ -f "$SENTRY_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
        mode=$(jq -r '.mode // "'$DEFAULT_MODE'"' "$SENTRY_CONFIG" 2>/dev/null)
        notifications=$(jq -r '.notifications // "'$DEFAULT_NOTIFICATIONS'"' "$SENTRY_CONFIG" 2>/dev/null)
        audit_log=$(jq -r '.audit_log // "'$DEFAULT_AUDIT_LOG'"' "$SENTRY_CONFIG" 2>/dev/null)
    else
        # No config file or no jq — use defaults
        mode="$DEFAULT_MODE"
        notifications="$DEFAULT_NOTIFICATIONS"
        audit_log="$DEFAULT_AUDIT_LOG"
    fi

    # Export for use by other scripts
    export SENTRY_MODE="$mode"
    export SENTRY_NOTIFICATIONS="$notifications"
    export AUDIT_LOG="$audit_log"
    export SAFETY_RULES="$SAFETY_RULES"
    export SENTRY_CONFIG="$SENTRY_CONFIG"
}

# Get current mode (guaranteed to return a valid value)
get_sentry_mode() {
    load_sentry_config
    echo "$SENTRY_MODE"
}

# Check if notifications should be sent
should_send_notifications() {
    load_sentry_config
    [[ "$SENTRY_NOTIFICATIONS" == "true" ]]
}

# Check if we should attempt to block commands (dry-run, soft-block or hard)
should_attempt_block() {
    local mode
    mode=$(get_sentry_mode)
    case "$mode" in
        dry-run|soft-block|hard) return 0 ;;
        *) return 1 ;;
    esac
}

# Check if we are in full hard enforcement mode
is_hard_mode() {
    [[ "$(get_sentry_mode)" == "hard" ]]
}

# Print current effective configuration (for debugging / sentryctl)
print_sentry_config() {
    load_sentry_config
    echo "=== Agentic Sentry Configuration ==="
    echo "Mode:              $SENTRY_MODE"
    echo "Notifications:     $SENTRY_NOTIFICATIONS"
    echo "Audit log:         $AUDIT_LOG"
    echo "Safety rules:      $SAFETY_RULES"
    echo "Config file:       $SENTRY_CONFIG"
    echo ""
    echo "Available modes: audit | warn | dry-run | soft-block | hard"
}

# Ensure the config file exists with good defaults (idempotent)
ensure_sentry_config() {
    mkdir -p "$(dirname "$SENTRY_CONFIG")"
    mkdir -p "$(dirname "$DEFAULT_AUDIT_LOG")"

    if [[ ! -f "$SENTRY_CONFIG" ]]; then
        cat > "$SENTRY_CONFIG" << EOF
{
  "version": "2.0",
  "mode": "soft-block",
  "notifications": true,
  "audit_log": "$DEFAULT_AUDIT_LOG",
  "description": "Operational settings for Agentic Sentry. Use 'sentryctl mode <name>' to change."
}
EOF
        echo "Created default config at $SENTRY_CONFIG"
        echo "Audit logs will be stored in: $(dirname "$DEFAULT_AUDIT_LOG")"
    fi
}

# Change mode (used by sentryctl)
set_sentry_mode() {
    local new_mode="$1"
    case "$new_mode" in
        audit|warn|dry-run|soft-block|hard)
            ensure_sentry_config
            # Use jq if available for clean edit, otherwise fall back
            if command -v jq >/dev/null 2>&1; then
                local tmp
                tmp=$(mktemp)
                jq --arg m "$new_mode" '.mode = $m' "$SENTRY_CONFIG" > "$tmp" && mv "$tmp" "$SENTRY_CONFIG"
            else
                # Very basic fallback (not perfect but works)
                sed -i '' 's/"mode": *"[^"]*"/"mode": "'"$new_mode"'"/' "$SENTRY_CONFIG" 2>/dev/null || true
            fi
            echo "Mode changed to: $new_mode"
            ;;
        *)
            echo "Invalid mode: $new_mode"
            echo "Valid modes: audit | warn | dry-run | soft-block | hard"
            return 1
            ;;
    esac
}

# If this script is executed directly, ensure config exists then show it
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    ensure_sentry_config 2>/dev/null || true
    print_sentry_config
fi
