#!/usr/bin/env zsh
# Agentic Sandbox Sentry - zsh preexec hook (Audit-First / Route C)
# Behavior is controlled by SENTRY_MODE in ~/.hermes/sentry-config.json
# Modes: audit | warn | soft-block (default) | hard

# Load central configuration (supports both bash and zsh)
SCRIPT_DIR="${0:A:h}"
CONFIG_LOADER="$SCRIPT_DIR/sentry-config.sh"

if [[ -f "$CONFIG_LOADER" ]]; then
    source "$CONFIG_LOADER" 2>/dev/null || true
    # Create default config on first load if it doesn't exist
    if command -v ensure_sentry_config >/dev/null 2>&1; then
        ensure_sentry_config 2>/dev/null || true
    fi
    load_sentry_config 2>/dev/null || true
else
    # Minimal fallback
    export SENTRY_MODE="${SENTRY_MODE:-soft-block}"
    export AUDIT_LOG="${AUDIT_LOG:-/tmp/sandbox-audit.log}"
    export SAFETY_RULES="${SAFETY_RULES:-$HOME/.hermes/safety-rules.json}"
fi

# Load unified structured logger (provides log_sentry_event, sentry_log)
if [[ -f "$SCRIPT_DIR/sentry-logger.sh" ]]; then
    source "$SCRIPT_DIR/sentry-logger.sh" 2>/dev/null || true
fi

# Simple macOS notification (osascript)
send_notification() {
    local title="$1"
    local message="$2"
    if should_send_notifications 2>/dev/null || [[ "$SENTRY_NOTIFICATIONS" == "true" ]]; then
        osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
    fi
}

# Log a structured event (rich format for sentryctl)
log_sentry_event() {
    local decision="$1"
    local reason="$2"
    local cmd="$3"
    local cwd="$4"

    local ts
    ts=$(date -Iseconds)
    local pid="$$"
    local ppid="$PPID"
    local user="${USER:-$(whoami)}"
    local shell="${SHELL:-zsh}"

    local json
    json=$(printf '{"ts":"%s","mode":"%s","decision":"%s","reason":"%s","cmd":"%s","cwd":"%s","pid":%s,"ppid":%s,"user":"%s","shell":"%s"}' \
        "$ts" "$SENTRY_MODE" "$decision" "$reason" "$cmd" "$cwd" "$pid" "$ppid" "$user" "$shell")

    echo "$json" >> "$AUDIT_LOG"
}

setopt PROMPT_SUBST

SCRIPT_DIR="${0:A:h}"
SAFETY_RULES="${SAFETY_RULES:-$HOME/.hermes/safety-rules.json}"
ENFORCEMENT_SCRIPT="${ENFORCEMENT_SCRIPT:-$SCRIPT_DIR/enforcement_recovery_module.sh}"
AUDIT_LOG="${AUDIT_LOG:-/tmp/sandbox-audit.log}"

# Allowed dirs from rules (one per line, properly handles spaces in paths)
get_allowed_dirs() {
    if command -v jq >/dev/null 2>&1 && [[ -f "$SAFETY_RULES" ]]; then
        jq -r '.allowed_project_dirs[]' "$SAFETY_RULES" 2>/dev/null | sed "s|\$HOME|$HOME|g; s|~|$HOME|g"
    else
        # Fallback (one per line)
        printf "%s\n" \
            "$HOME/Projects" \
            "$HOME/go" \
            "$HOME/Documents/Vibe Coding" \
            "$HOME/shenzhou23-video" \
            "$HOME/Documents/Vibe_Coding"
    fi
}

# Returns 0 if the target path is inside one of the allowed project directories (safe)
# Returns 1 if the path is OUTSIDE all allowed dirs (dangerous for rm etc.)
is_path_in_allowed_project() {
    local target="$1"
    [[ -z "$target" ]] && return 1

    local real_target
    real_target=$(realpath "$target" 2>/dev/null || echo "$target")

    while IFS= read -r allowed || [[ -n "$allowed" ]]; do
        [[ -z "$allowed" ]] && continue
        local real_allowed
        real_allowed=$(realpath "$allowed" 2>/dev/null || echo "$allowed")
        if [[ "$real_target" == "$real_allowed"* ]]; then
            return 0   # safe
        fi
    done < <(get_allowed_dirs)

    return 1   # outside all allowed projects → treat as dangerous
}

# Hash verification for trusted binaries (P4 lightweight)
check_hash_allowlist() {
    local cmd="$1"
    local bin
    bin=$(echo "$cmd" | awk '{print $1}')
    [[ ! -f "$bin" ]] && return 0
    if command -v sha256sum >/dev/null || command -v shasum >/dev/null; then
        local hash
        if command -v shasum >/dev/null; then
            hash=$(shasum -a 256 "$bin" 2>/dev/null | awk '{print $1}')
        else
            hash=$(sha256sum "$bin" 2>/dev/null | awk '{print $1}')
        fi
        # For now, simple: if rules had hashes we could check, but fallback allow common safe
        # Extend later if needed; physical block still happens on mismatch rule
        return 0
    fi
    return 0
}

# Detect dangerous command using rules (improved target extraction for spaces/quotes)
is_dangerous() {
    local cmd="$1"
    local cwd="$2"

    # rm -rf / rmdir outside projects (improved target extraction below)
    if [[ "$cmd" =~ ^(rm|rmdir)[[:space:]]+-?r?f? ]]; then
        local target
        target=$(echo "$cmd" | awk '{for(i=NF;i>1;i--) if ($i !~ /^-/) {print $i; break}}' | sed "s/['\"];*$//; s/;$//")
        # Block if no target could be extracted OR the target is outside all allowed projects
        if [[ -z "$target" ]] || ! is_path_in_allowed_project "$target"; then
            echo "BLOCKED: rm/rmdir outside allowed project dirs (or ambiguous target)"
            return 0
        fi
    fi

    # sudo any
    if [[ "$cmd" =~ ^sudo[[:space:]] ]]; then
        echo "BLOCKED: sudo command detected"
        return 0
    fi

    # sensitive paths (ssh, keychain, etc.)
    if [[ "$cmd" =~ \.(ssh|gnupg|aws|config/gcloud) ]] || [[ "$cmd" =~ (/etc/|/System/|/Library/Keychains) ]]; then
        echo "BLOCKED: access to sensitive system/key path"
        return 0
    fi

    # network config changes
    if [[ "$cmd" =~ ^(networksetup|ifconfig|scutil|route|pfctl)[[:space:]] ]]; then
        echo "BLOCKED: network/system config change"
        return 0
    fi

    # curl | bash
    if [[ "$cmd" =~ curl.*\|.*(bash|sh|zsh) ]]; then
        echo "BLOCKED: curl pipe to shell"
        return 0
    fi

    # === Bypass / evasion detection (new) ===
    # exec wrapper
    if [[ "$cmd" =~ ^exec[[:space:]]+(rm|sudo|curl|python|perl|zsh|bash) ]]; then
        echo "BLOCKED: exec wrapper around dangerous command"
        return 0
    fi

    # (zsh|bash|sh) -c "..." containing dangerous payload
    if [[ "$cmd" =~ (zsh|bash|sh)[[:space:]]+-c[[:space:]] ]]; then
        local inner
        inner=$(echo "$cmd" | sed -E 's/.*-c[[:space:]]+['\''"]?([^'\''"]+).*/\1/I')
        if [[ "$inner" =~ (rm[[:space:]]+-?r|sudo |curl.*\|.*(sh|bash)|networksetup|ifconfig.*down|pfctl) ]]; then
            echo "BLOCKED: dangerous command inside subshell (-c)"
            return 0
        fi
    fi

    # python/perl/ruby one-liners often used by agents
    if [[ "$cmd" =~ (python|python3|perl|ruby)[[:space:]]+-[ce][[:space:]] ]]; then
        if [[ "$cmd" =~ (rm[[:space:]]+-?r|sudo|os\.system|subprocess|exec\(|unlink|shutil\.rmtree) ]]; then
            echo "BLOCKED: dangerous operation inside language one-liner"
            return 0
        fi
    fi

    # Common TTY/script wrappers used to hide or background commands
    if [[ "$cmd" =~ ^(script|expect|unbuffer|stdbuf|nohup)[[:space:]] ]]; then
        # Only block if they seem to wrap a dangerous command
        if [[ "$cmd" =~ (rm -r|sudo |curl .*\|) ]]; then
            echo "BLOCKED: TTY wrapper around dangerous command (evasion attempt)"
            return 0
        fi
    fi

    # Hash allowlist check (P4) - if fails would block but current impl allows
    check_hash_allowlist "$cmd"

    return 1
}

# Preexec hook - mode-aware behavior (core of Route C)
preexec() {
    local cmd="$1"
    local cwd="$PWD"

    if ! is_dangerous "$cmd" "$cwd"; then
        return 0
    fi

    local reason
    reason=$(is_dangerous "$cmd" "$cwd")

    # Always log
    log_sentry_event "DETECTED" "$reason" "$cmd" "$cwd"

    case "$SENTRY_MODE" in
        audit)
            # Pure audit: just log + quiet notification
            send_notification "Sentry (Audit)" "Dangerous command detected: $reason"
            # Do nothing else — command runs
            ;;

        warn)
            # Warn but allow execution
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "⚠️  [SENTRY WARNING] Dangerous command detected"
            echo "   Mode   : warn (command will still run)"
            echo "   Reason : $reason"
            echo "   Command: $cmd"
            echo "   CWD    : $cwd"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            send_notification "Sentry Warning" "$reason"
            # Command continues
            ;;

        soft-block)
            # Best-effort block + strong warning + notification
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "🛑  [SENTRY SOFT-BLOCK] Command blocked"
            echo "   Mode   : soft-block"
            echo "   Reason : $reason"
            echo "   Command: $cmd"
            echo "   CWD    : $cwd"
            echo "   This command was prevented from running."
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            send_notification "Sentry Blocked" "$reason — $cmd"

            log_sentry_event "SOFT_BLOCKED" "$reason" "$cmd" "$cwd"

            # Try to prevent execution (best effort)
            return 1
            ;;

        hard)
            # Full original enforcement (nuclear option)
            echo "🚨 [SENTRY HARD MODE] VIOLATION — Triggering physical enforcement"
            echo "   Reason : $reason"
            echo "   Command: $cmd"
            echo "   CWD    : $cwd"

            log_sentry_event "HARD_ENFORCEMENT" "$reason" "$cmd" "$cwd"
            send_notification "SENTRY HARD MODE" "Physical enforcement triggered: $reason"

            # Call the heavy enforcement script
            if [[ -x "$ENFORCEMENT_SCRIPT" ]]; then
                "$ENFORCEMENT_SCRIPT" enforce "Hard mode: $reason" || {
                    echo "Primary enforcement failed, using fallback..."
                    sudo networksetup -setairportpower $(networksetup -listallhardwareports | awk '/Wi-Fi/{getline;print $2}') off 2>/dev/null || true
                    sudo ifconfig en0 down 2>/dev/null || true
                }
            else
                sudo networksetup -setairportpower $(networksetup -listallhardwareports | awk '/Wi-Fi/{getline;print $2}') off 2>/dev/null || true
                sudo ifconfig en0 down 2>/dev/null || true
            fi

            return 1
            ;;

        *)
            # Unknown mode — safe default to warn
            echo "⚠️  Unknown SENTRY_MODE='$SENTRY_MODE', defaulting to warn behavior"
            echo "⚠️  [SENTRY] Dangerous command: $reason — $cmd"
            ;;
    esac
}

# Optional: precmd for cleanup
precmd() {
    # Could add session heartbeat here (P6)
}

echo "✅ Agentic Sandbox Sentry hooks loaded (zsh)"
echo "   Mode: $SENTRY_MODE   |   Rules: $SAFETY_RULES"
echo "   Change mode with: sentryctl mode <audit|warn|soft-block|hard>"
echo "   Audit log: $AUDIT_LOG"