#!/usr/bin/env zsh
# Agentic Sentry - zsh preexec hook (Audit-First / Route C)
# Behavior is controlled by SENTRY_MODE in $SENTRY_HOME/sentry-config.json
# (default ~/.agentsentry; legacy installs use ~/.hermes)
# Modes: audit | warn | dry-run | soft-block (default) | hard

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
    # Minimal fallback (home resolution kept in sync with sentry-config.sh)
    if [[ -z "${SENTRY_HOME:-}" ]]; then
        if [[ -f "$HOME/.agentsentry/sentry-config.json" ]]; then
            SENTRY_HOME="$HOME/.agentsentry"
        elif [[ -f "$HOME/.hermes/sentry-config.json" ]]; then
            SENTRY_HOME="$HOME/.hermes"
        else
            SENTRY_HOME="$HOME/.agentsentry"
        fi
    fi
    export SENTRY_MODE="${SENTRY_MODE:-soft-block}"
    export AUDIT_LOG="${AUDIT_LOG:-/tmp/sandbox-audit.log}"
    export SAFETY_RULES="${SAFETY_RULES:-$SENTRY_HOME/safety-rules.json}"
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
SAFETY_RULES="${SAFETY_RULES:-${SENTRY_HOME:-$HOME/.agentsentry}/safety-rules.json}"
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

    # NOTE: declared OUTSIDE the loop — re-running 'local x' on a set
    # variable inside a zsh loop PRINTS "x=value" to stdout, polluting
    # the reason string this function's callers capture.
    local real_allowed
    while IFS= read -r allowed || [[ -n "$allowed" ]]; do
        [[ -z "$allowed" ]] && continue
        real_allowed=$(realpath "$allowed" 2>/dev/null || echo "$allowed")
        # Require a path-boundary match, NOT a raw string prefix: the allowed
        # dir itself, or something strictly beneath it (followed by '/').
        # A bare prefix would treat '/…/Projects-evil' as inside '/…/Projects'.
        if [[ "$real_target" == "$real_allowed" || "$real_target" == "$real_allowed"/* ]]; then
            return 0   # safe
        fi
    done < <(get_allowed_dirs)

    return 1   # outside all allowed projects → treat as dangerous
}

# Extract the most likely path operand from a command (last non-option token).
_sentry_extract_target() {
    echo "$1" | awk '{for(i=NF;i>1;i--) if ($i !~ /^-/) {print $i; break}}' | sed "s/['\"];*$//; s/;$//"
}

# Normalize a single command segment down to its real command word, so the
# anchored rules see `rm`/`sudo`/etc. regardless of how it was dressed up:
#   - leading whitespace, grouping/escape chars ( { \
#   - env-var assignments (FOO=1) and env|command|builtin
#   - a directory path on the command itself (/bin/rm, ./rm, /usr/bin/sudo)
#   - command multiplexers/prefixes that delegate to the next word
#     (time, nice, nohup, ionice, timeout, stdbuf, busybox) and their options
# Iterates to a fixed point so combinations (`/usr/bin/env FOO=1 nice -n5 rm`)
# all collapse to `rm …`.
_sentry_norm() {
    # One sed pass with a branch loop (fast: a single subprocess per segment).
    # Each rule, when it fires, branches back to :top so combinations collapse.
    # The option/number strip only matches a segment that already STARTS with
    # an option or number — which only happens after a wrapper word is removed,
    # so it never eats a real command's first token.
    printf '%s' "$1" | sed -E '
:top
s/^[[:space:]({\\]+//
t top
s/^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+//
t top
s|^[^[:space:]]+/||
t top
s/^(env|command|builtin|time|nice|nohup|ionice|timeout|stdbuf|busybox)[[:space:]]+//
t top
s/^(-[^[:space:]]*|[0-9]+[smhdkMG]?)[[:space:]]+//
t top
'
}

# Detect dangerous command using rules.
#
# Two layers, because a single anchored regex over the whole line is trivially
# defeated by a prefix (`cd x && rm`, `FOO=1 sudo`, leading space) — see the
# security audit. We therefore:
#   1. Run CONTAINS checks over the whole (de-quoted) command — these match
#      anywhere, so a prefix can't hide them (sensitive paths, curl|shell RCE,
#      language one-liners, bash -c payloads, fork bombs, rc-file writes).
#   2. Split the command into segments on ; && || | and newline, strip each
#      segment's leading whitespace / env-assignments / env|command|builtin,
#      then run the ANCHORED single-command checks (rm, sudo, network, disk,
#      wrappers) on each segment.
is_dangerous() {
    local cmd="$1"
    local cwd="$2"
    local depth="${3:-0}"   # recursion guard for nested -c payloads
    local dequoted seg s target fpath inner _r

    # ===== Layer 1: whole-command CONTAINS checks (immune to prefixes) =====

    # Sensitive paths. De-quote first (strip " ' \ `) so split literals like
    # ~/.s""sh or cat ~/.\ssh can't hide the match; also catch key filenames
    # directly, which survive globbing (~/.ss*/id_rsa).
    dequoted=$(printf '%s' "$cmd" | tr -d '\042\047\134\140')
    if [[ "$dequoted" =~ \.(ssh|gnupg|aws|config/gcloud) ]] \
       || [[ "$dequoted" =~ (/etc/|/System/|/Library/Keychains|/private/etc/) ]] \
       || [[ "$cmd" =~ (id_rsa|id_ed25519|id_ecdsa|id_dsa|authorized_keys|known_hosts|\.netrc|secring\.gpg) ]]; then
        echo "BLOCKED: access to sensitive system/key path"
        return 0
    fi

    # Remote code execution: curl/wget/fetch feeding a shell in ANY form —
    # pipe, process substitution <(...), or command substitution $(...)/`...`.
    if [[ "$cmd" =~ (curl|wget|fetch)[[:space:]] ]]; then
        if { [[ "$cmd" == *"|"* ]] && [[ "$cmd" =~ "[|][[:space:]]*([^ ]*/)?(ba|z)?sh" ]]; } \
           || [[ "$cmd" == *'<(curl'* ]] || [[ "$cmd" == *'<(wget'* ]] \
           || [[ "$cmd" == *'$(curl'* ]] || [[ "$cmd" == *'$(wget'* ]] \
           || [[ "$cmd" == *'`curl'* ]] || [[ "$cmd" == *'`wget'* ]]; then
            echo "BLOCKED: curl/wget piped or substituted into a shell"
            return 0
        fi
    fi

    # Fork bomb (`:(){ :|:& };:` and variants) — the `:|:` core is distinctive.
    if [[ "$cmd" == *':|:'* ]]; then
        echo "BLOCKED: fork bomb pattern"
        return 0
    fi

    # Writes to shell startup files (persistence / disabling the guard).
    if [[ "$cmd" =~ (\>|\>\>|tee)[[:space:]]*([^[:space:]]*/)?(\.zshrc|\.zshenv|\.zprofile|\.bashrc|\.bash_profile|\.profile) ]]; then
        echo "BLOCKED: write to shell startup file"
        return 0
    fi

    # Language one-liners (python/perl/ruby -c/-e) with a destructive payload.
    if [[ "$cmd" =~ (python|python3|perl|ruby)[[:space:]]+-[ce][[:space:]] ]]; then
        if [[ "$cmd" =~ (rm[[:space:]]+-?r|sudo|os\.system|subprocess|exec\(|unlink|shutil\.rmtree) ]]; then
            echo "BLOCKED: dangerous operation inside language one-liner"
            return 0
        fi
    fi

    # bash/zsh/sh -c "..." — recurse into the payload so EVERY rule applies to
    # the inner command, not just a hardcoded keyword list (else `bash -c
    # 'find / -delete'` slips through). Depth-guarded against nested -c.
    if [[ "$cmd" =~ (zsh|bash|sh)[[:space:]]+-c[[:space:]] ]] && (( depth < 4 )); then
        inner=$(printf '%s' "$cmd" | sed -E "s/.*-c[[:space:]]+['\"]?([^'\"]*).*/\1/")
        if [[ -n "$inner" && "$inner" != "$cmd" ]]; then
            if _r=$(is_dangerous "$inner" "$cwd" $((depth + 1))); then
                echo "BLOCKED: dangerous command inside subshell (-c) — ${_r#BLOCKED: }"
                return 0
            fi
        fi
    fi

    # ===== Layer 2: per-segment ANCHORED checks (defeats prefix/chaining) =====
    while IFS= read -r seg; do
        [[ -z "$seg" ]] && continue
        # Collapse the segment to its real command word (strips paths,
        # env-assignments, grouping chars, and wrapper words — see _sentry_norm).
        s=$(_sentry_norm "$seg")

        # rm / rmdir outside allowed project dirs
        if [[ "$s" =~ ^(rm|rmdir)[[:space:]]+-?r?f? ]]; then
            target=$(_sentry_extract_target "$s")
            if [[ -z "$target" ]] || ! is_path_in_allowed_project "$target"; then
                echo "BLOCKED: rm/rmdir outside allowed project dirs (or ambiguous target)"
                return 0
            fi
        fi

        # Privilege escalation
        if [[ "$s" =~ ^(sudo|doas)[[:space:]] ]]; then
            echo "BLOCKED: privilege escalation (sudo/doas) detected"
            return 0
        fi

        # Network / system config change
        if [[ "$s" =~ ^(networksetup|ifconfig|scutil|route|pfctl)[[:space:]] ]]; then
            echo "BLOCKED: network/system config change"
            return 0
        fi

        # exec wrapper around a dangerous command
        if [[ "$s" =~ ^exec[[:space:]]+(rm|sudo|doas|curl|wget|python|perl|zsh|bash) ]]; then
            echo "BLOCKED: exec wrapper around dangerous command"
            return 0
        fi

        # TTY/background wrappers around a dangerous command
        if [[ "$s" =~ ^(script|expect|unbuffer|stdbuf|nohup)[[:space:]] ]]; then
            if [[ "$s" =~ (rm[[:space:]]+-r|sudo[[:space:]]|doas[[:space:]]) ]] || [[ "$s" == *curl*"|"* ]]; then
                echo "BLOCKED: TTY/background wrapper around dangerous command"
                return 0
            fi
        fi

        # find-based mass delete/exec outside allowed dirs
        if [[ "$s" =~ ^find[[:space:]] ]] && [[ "$s" =~ (-delete|-exec(dir)?[[:space:]]+(rm|unlink|rmdir|shred)) ]]; then
            fpath=$(printf '%s' "$s" | awk '{for(i=2;i<=NF;i++) if ($i !~ /^-/) {print $i; break}}')
            if [[ -z "$fpath" ]] || ! is_path_in_allowed_project "$fpath"; then
                echo "BLOCKED: find-based mass delete/exec outside allowed dirs"
                return 0
            fi
        fi

        # Recursive permission change outside allowed dirs
        if [[ "$s" =~ ^(chmod|chown)[[:space:]] ]] && [[ "$s" =~ (-R|-r|--recursive)([[:space:]]|$) ]]; then
            target=$(_sentry_extract_target "$s")
            if [[ -z "$target" ]] || ! is_path_in_allowed_project "$target"; then
                echo "BLOCKED: recursive permission change outside allowed dirs"
                return 0
            fi
        fi

        # Raw disk / filesystem destruction
        if [[ "$s" =~ ^dd[[:space:]] ]] && [[ "$s" == *of=/dev/* ]]; then
            echo "BLOCKED: dd writing to a device"
            return 0
        fi
        if [[ "$s" =~ ^(shred|mkfs)([[:space:]]|$) ]] || [[ "$s" =~ ^diskutil[[:space:]]+(erase|reformat|partition|secureErase|eraseDisk|eraseVolume) ]]; then
            echo "BLOCKED: destructive disk operation"
            return 0
        fi

    done < <(printf '%s\n' "$cmd" | awk '{gsub(/\|\||&&|[;|&]|\n/,"\n"); print}')

    return 1
}

# Repetition (retry-loop) detection — signal only, never blocks (T9)
if [[ -f "$SCRIPT_DIR/sentry-rate.sh" ]]; then
    source "$SCRIPT_DIR/sentry-rate.sh" 2>/dev/null || true
fi

# Preexec hook - mode-aware behavior (core of Route C)
preexec() {
    local cmd="$1"
    local cwd="$PWD"

    # Retry-loop signal: log + notify once per window, command always runs
    if command -v sentry_rate_check >/dev/null 2>&1 && sentry_rate_check "$cmd"; then
        log_sentry_event "RATE_REPEAT" "$SENTRY_RATE_REASON" "$cmd" "$cwd"
        send_notification "Sentry (Repeat)" "$SENTRY_RATE_REASON"
    fi

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

        dry-run)
            # Block the command (safe default) and show exactly what each
            # enforcement level would have done — without doing any of it.
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "🧪  [SENTRY DRY-RUN] Command intercepted (nothing enforced)"
            echo "   Reason : $reason"
            echo "   Command: $cmd"
            echo "   CWD    : $cwd"
            echo ""
            echo "   In soft-block mode: this command would be blocked."
            echo "   In hard mode: physical enforcement would also trigger:"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

            log_sentry_event "DRY_RUN" "$reason" "$cmd" "$cwd"

            # Ask the enforcement module for its action plan (read-only)
            if [[ -x "$ENFORCEMENT_SCRIPT" ]]; then
                SENTRY_DRY_RUN=1 "$ENFORCEMENT_SCRIPT" enforce --dry-run "Dry-run: $reason" 2>/dev/null || true
            fi

            # Block execution, same as soft-block (safe for new users testing)
            return 1
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

echo "✅ Agentic Sentry hooks loaded (zsh)"
echo "   Mode: $SENTRY_MODE   |   Rules: $SAFETY_RULES"
echo "   Change mode with: sentryctl mode <audit|warn|dry-run|soft-block|hard>"
echo "   Audit log: $AUDIT_LOG"