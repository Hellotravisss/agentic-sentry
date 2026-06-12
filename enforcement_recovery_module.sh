#!/bin/bash
# enforcement_recovery_module.sh - macOS native physical enforcement for Agentic Sandbox Sentry
# Network cut (Wi-Fi + ifconfig + pf anchor) + real process suspension (kill -STOP)
# Safe restore with mandatory one-time code + auto-resume of frozen processes
# Modes: setup | enforce [reason] [pids_hint] | restore | status

set -euo pipefail

SENTRY_HOME="${SENTRY_HOME:-$HOME/.hermes}"
ENFORCE_LOG="${SENTRY_ENFORCE_LOG:-$SENTRY_HOME/logs/enforcement.log}"
# Legacy fallback for older setups
[[ ! -d "$(dirname "$ENFORCE_LOG")" ]] && ENFORCE_LOG="/tmp/sandbox-enforcement.log"
PF_RULES="/etc/pf.anchors/agentsentry"
BACKUP_IF="/tmp/agentsentry-if.backup"
BACKUP_WIFI="/tmp/agentsentry-wifi.backup"

# Process suspension + safe restore
SUSPENDED_PIDS_FILE="${SUSPENDED_PIDS_FILE:-/tmp/suspended_pids.txt}"
RESTORE_CODE_FILE="${RESTORE_CODE_FILE:-$SENTRY_HOME/agentsentry-restore.code}"

# Dry-run: print every action without changing network or process state.
# Enabled by SENTRY_DRY_RUN=1 or the --dry-run flag.
DRY_RUN="${SENTRY_DRY_RUN:-0}"

# Load unified structured logger
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/sentry-logger.sh" ]]; then
    source "$SCRIPT_DIR/sentry-logger.sh"
fi

get_active_interface() {
    # Prefer en0 or en1, fallback to route
    if ifconfig en0 >/dev/null 2>&1 && ifconfig en0 | grep -q 'inet '; then
        echo "en0"
    elif ifconfig en1 >/dev/null 2>&1 && ifconfig en1 | grep -q 'inet '; then
        echo "en1"
    else
        route get default 2>/dev/null | awk '/interface:/ {print $2}' || echo "en0"
    fi
}

get_wifi_device() {
    networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi|AirPort/{getline; print $2}' | head -1 || echo "en0"
}

# --- New: Process suspension & safe restore support ---

ensure_private_state_dir() {
    local dir
    dir=$(dirname "$RESTORE_CODE_FILE")
    mkdir -p "$dir"
    chmod 700 "$dir" 2>/dev/null || true
}

generate_restore_code() {
    # 8-char uppercase alphanumeric code, memorable but hard to guess
    local code
    code=$(LC_ALL=C tr -dc 'A-HJ-NP-Z2-9' </dev/urandom | head -c 8 || echo "SAFENOW1")
    ensure_private_state_dir
    echo "$code" > "$RESTORE_CODE_FILE"
    chmod 600 "$RESTORE_CODE_FILE" 2>/dev/null || true
    echo "$code"
}

get_process_whitelist() {
    # PIDs or process names we never want to freeze
    # Include ourselves, fswatch, launchd, kernel, current shell, Terminal/iTerm
    echo "fswatch|launchd|kernel_task|sysmond|mds|WindowServer|Terminal|iTerm|login|sshd|sentry|agentsentry|enforcement"
}

find_processes_touching_path() {
    # Best-effort: return PIDs that have the given path (or its parent dir) open
    local target_path="$1"
    [[ -z "$target_path" ]] && return 0

    local pids
    # Try exact path first, then directory
    pids=$(lsof -t "$target_path" 2>/dev/null || true)
    if [[ -z "$pids" && -d "$(dirname "$target_path" 2>/dev/null)" ]]; then
        pids=$(lsof -t +D "$(dirname "$target_path")" 2>/dev/null | head -8 || true)
    fi
    echo "$pids"
}

suspend_pids() {
    local pids_to_stop="$1"
    local reason="${2:-violation}"
    local whitelist
    whitelist=$(get_process_whitelist)

    local stopped=()
    for pid in $pids_to_stop; do
        # Skip empty, non-numeric, or whitelisted
        [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && continue
        if ps -p "$pid" -o comm= 2>/dev/null | grep -qE "$whitelist"; then
            continue
        fi
        if kill -STOP "$pid" 2>/dev/null; then
            stopped+=("$pid")
            echo "  [STOP] PID $pid ($(ps -p "$pid" -o comm= 2>/dev/null))"
        fi
    done

    if (( ${#stopped[@]} > 0 )); then
        printf "%s\n" "${stopped[@]}" >> "$SUSPENDED_PIDS_FILE"
        echo "Suspended ${#stopped[@]} process(es). List: ${stopped[*]}"
    else
        echo "No additional processes frozen (best effort)."
    fi
}

resume_suspended_processes() {
    [[ ! -f "$SUSPENDED_PIDS_FILE" ]] && { echo "No suspended process list found."; return 0; }

    local resumed=0
    while IFS= read -r pid; do
        [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]] && continue
        if kill -CONT "$pid" 2>/dev/null; then
            echo "  [CONT] PID $pid resumed"
            ((resumed++))
        fi
    done < "$SUSPENDED_PIDS_FILE"

    > "$SUSPENDED_PIDS_FILE"   # clear the list
    echo "Resumed $resumed process(es)."
}

# Shared by enforce and dry-run: figure out which PIDs we would freeze.
discover_candidate_pids() {
    local reason="$1"
    local extra_context="${2:-}"
    local pids=""

    # If caller passed explicit PIDs (from fswatch/lsof), use them
    if [[ -n "$extra_context" ]]; then
        # extra_context may be "path:/foo 1234 5678" or just pids
        pids=$(echo "$extra_context" | tr ' ' '\n' | grep -E '^[0-9]+$' || true)
    fi

    # If we have a path hint in the reason or context, try lsof
    if [[ -z "$pids" && "$reason" =~ (on |path |file |dir )([^ ]+) ]]; then
        local hinted_path="${BASH_REMATCH[2]}"
        pids=$(find_processes_touching_path "$hinted_path")
    fi

    # Always try to freeze recent children of current terminal / PPID (shell hook case)
    if [[ -z "$pids" ]]; then
        local parent=${PPID:-$PPID}
        pids=$(pgrep -P "$parent" 2>/dev/null | head -6 || true)
        if [[ -n "$parent" ]]; then
            pids="$pids $parent"
        fi
    fi

    echo "$pids"
}

dry_run_enforce() {
    local reason="$1"
    local extra_context="${2:-}"
    local iface wifi_dev pids
    iface=$(get_active_interface)
    wifi_dev=$(get_wifi_device)
    pids=$(discover_candidate_pids "$reason" "$extra_context" | tr '\n' ' ')

    echo ""
    echo "======================================================================"
    echo "🧪  AGENTIC SANDBOX SENTRY — DRY RUN (no changes will be made)"
    echo "======================================================================"
    echo "Reason : $reason"
    echo ""
    echo "Hard enforcement WOULD perform these actions:"
    echo "  1. Generate a one-time restore code at: $RESTORE_CODE_FILE"
    echo "  2. Run: networksetup -setairportpower $wifi_dev off"
    echo "  3. Run: sudo ifconfig $iface down"
    echo "  4. Run: sudo pfctl -a agentsentry -f $PF_RULES && sudo pfctl -e"
    if [[ -n "${pids// /}" ]]; then
        echo "  5. Freeze candidate processes with kill -STOP:"
        local pid
        for pid in $pids; do
            [[ "$pid" =~ ^[0-9]+$ ]] || continue
            local comm
            comm=$(ps -p "$pid" -o comm= 2>/dev/null || echo "?")
            if echo "$comm" | grep -qE "$(get_process_whitelist)"; then
                echo "       PID $pid ($comm) — SKIPPED (whitelisted)"
            else
                echo "       PID $pid ($comm)"
            fi
        done
    else
        echo "  5. Freeze candidate processes: none found right now"
    fi
    echo ""
    echo "Recovery would require: $0 restore (+ the one-time restore code)"
    echo "✅ DRY RUN complete — network and processes were NOT touched."
    echo "======================================================================"

    if command -v log_enforcement >/dev/null 2>&1; then
        log_enforcement "DRY_RUN" "$reason" "{\"iface\":\"$iface\"}"
    fi
}

# --- End new helpers ---

setup() {
    echo "[SETUP] Creating pf anchor for reversible firewall block..."
    sudo mkdir -p /etc/pf.anchors
    echo 'block drop out proto {tcp,udp} from any to any' | sudo tee "$PF_RULES" >/dev/null
    sudo chmod 600 "$PF_RULES"
    if ! grep -q '^anchor "agentsentry"' /etc/pf.conf 2>/dev/null; then
        echo "anchor \"agentsentry\"" | sudo tee -a /etc/pf.conf >/dev/null || true
    fi
    sudo pfctl -e 2>/dev/null || true
    echo "✅ pf anchor ready. Use 'restore' to revert."
    echo "Also backing up current WiFi state..."
    networksetup -getairportpower "$(get_wifi_device)" > "$BACKUP_WIFI" 2>/dev/null || true
    ifconfig "$(get_active_interface)" > "$BACKUP_IF" 2>/dev/null || true
}

enforce() {
    local reason="${1:-AI agent violation detected}"
    local extra_context="${2:-}"   # optional: path or space-separated PIDs from caller

    if [[ "$DRY_RUN" == "1" ]]; then
        dry_run_enforce "$reason" "$extra_context"
        return 0
    fi

    local iface
    iface=$(get_active_interface)
    local wifi_dev
    wifi_dev=$(get_wifi_device)
    local ts
    ts=$(date -Iseconds)

    echo "[$ts] ENFORCING: $reason" | tee -a "$ENFORCE_LOG"
    logger -t agentsentry "ENFORCED: $reason"

    # Structured log
    if command -v log_enforcement >/dev/null 2>&1; then
        log_enforcement "ENFORCED" "$reason" "{\"iface\":\"$(get_active_interface)\"}"
    fi

    # 1. Generate mandatory restore code (printed very visibly)
    local restore_code
    restore_code=$(generate_restore_code)
    echo ""
    echo "======================================================================"
    echo "🚨  AGENTIC SANDBOX SENTRY — PHYSICAL ENFORCEMENT ACTIVATED"
    echo "======================================================================"
    echo "Reason : $reason"
    echo ""
    echo "   >>>  RESTORE CODE:   $restore_code   <<<"
    echo ""
    echo "This code is required to restore network access."
    echo "Write it down NOW. It is also saved at $RESTORE_CODE_FILE"
    echo "======================================================================"
    echo ""

    # 2. Immediate WiFi off (reversible)
    networksetup -setairportpower "$wifi_dev" off 2>/dev/null || true

    # 3. Bring interface down
    sudo ifconfig "$iface" down 2>/dev/null || true

    # 4. pfctl block (physical cut)
    sudo pfctl -a agentsentry -f "$PF_RULES" 2>/dev/null || true
    sudo pfctl -e 2>/dev/null || true

    echo ">>> Physical network cut + firewall block activated. <<<"

    # 5. Process suspension (NEW - fulfills the original design goal)
    local pids_to_freeze
    pids_to_freeze=$(discover_candidate_pids "$reason" "$extra_context")

    if [[ -n "$pids_to_freeze" ]]; then
        echo "Attempting to freeze suspicious processes..."
        suspend_pids "$pids_to_freeze" "$reason"
    else
        echo "Process freeze: no clear candidate PIDs found (best effort)."
    fi

    # Structured log
    if command -v log_enforcement >/dev/null 2>&1; then
        log_enforcement "ENFORCED" "$reason" "{\"iface\":\"$iface\",\"restore_code\":\"$restore_code\"}"
    else
        echo "{\"ts\":\"$ts\",\"action\":\"enforce\",\"reason\":\"$reason\",\"iface\":\"$iface\",\"restore_code\":\"$restore_code\"}" >> "$ENFORCE_LOG"
    fi
}

restore() {
    local iface
    iface=$(get_active_interface)
    local wifi_dev
    wifi_dev=$(get_wifi_device)

    if [[ "$DRY_RUN" == "1" ]]; then
        echo ""
        echo "🧪 DRY RUN — restore would perform these actions (no changes made):"
        echo "  1. Verify the one-time restore code at: $RESTORE_CODE_FILE"
        echo "  2. Run: networksetup -setairportpower $wifi_dev on"
        echo "  3. Run: sudo ifconfig $iface up"
        echo "  4. Run: sudo pfctl -a agentsentry -F all   (Sentry anchor only)"
        if [[ -s "$SUSPENDED_PIDS_FILE" ]]; then
            echo "  5. Resume suspended PIDs with kill -CONT: $(tr '\n' ' ' < "$SUSPENDED_PIDS_FILE")"
        else
            echo "  5. Resume suspended PIDs: none recorded"
        fi
        echo "  6. Remove the one-time restore code file"
        return 0
    fi

    echo ""
    echo "======================================================================"
    echo "RESTORE NETWORK ACCESS — SAFETY CHECK"
    echo "======================================================================"

    # === Mandatory confirmation code ===
    if [[ -f "$RESTORE_CODE_FILE" ]]; then
        local expected_code
        expected_code=$(cat "$RESTORE_CODE_FILE" | tr -d ' \n\r')
        echo "A restore code was generated during enforcement."
        echo -n "Enter the restore code exactly (or type EMERGENCY for override): "
        read -r user_code
        user_code=$(echo "$user_code" | tr -d ' \n\r')

        if [[ "$user_code" != "$expected_code" ]]; then
            if [[ "$user_code" == "EMERGENCY" ]]; then
                echo ""
                echo "⚠️  EMERGENCY OVERRIDE SELECTED ⚠️"
                echo "Type the following phrase exactly to confirm you understand the risks:"
                echo -n "    I UNDERSTAND THE RISKS AND ACCEPT FULL RESPONSIBILITY    "
                read -r phrase
                if [[ "$phrase" != "I UNDERSTAND THE RISKS AND ACCEPT FULL RESPONSIBILITY" ]]; then
                    echo "❌ Phrase did not match. Aborting restore for safety."
                    return 1
                fi
                echo "Emergency override accepted. Proceeding with extreme caution..."
            else
                echo "❌ Incorrect restore code. Network remains isolated."
                echo "   Code file: $RESTORE_CODE_FILE"
                echo "   (You can cat that file if you wrote the code down correctly)"
                return 1
            fi
        else
            echo "✅ Restore code verified."
        fi
    else
        echo "⚠️  No restore code file found ($RESTORE_CODE_FILE)."
        echo "This is unusual. Proceeding only after extra confirmation..."
        echo -n "Type 'FORCE-RESTORE' to continue anyway: "
        read -r force
        if [[ "$force" != "FORCE-RESTORE" ]]; then
            echo "Aborted."
            return 1
        fi
    fi

    echo ""
    echo ">>> Restoring network in 3 seconds (Ctrl-C to abort)..."
    sleep 1; echo "2..."; sleep 1; echo "1..."; sleep 1

    # Restore WiFi
    if [[ -f "$BACKUP_WIFI" ]]; then
        local state
        state=$(cat "$BACKUP_WIFI" | awk '{print $NF}')
        networksetup -setairportpower "$wifi_dev" "$state" 2>/dev/null || networksetup -setairportpower "$wifi_dev" on
    else
        networksetup -setairportpower "$wifi_dev" on 2>/dev/null || true
    fi

    # Restore interface
    sudo ifconfig "$iface" up 2>/dev/null || true

    # Clear only the Sentry-owned pf anchor. Do not disable global pf because
    # users may rely on pf for unrelated firewall/VPN/security rules.
    sudo pfctl -a agentsentry -F all 2>/dev/null || true

    echo ""
    echo "✅ Network restored. Check connectivity (ping 8.8.8.8 or open a browser)."

    # Resume any processes we froze
    echo ""
    echo "Resuming previously suspended processes..."
    resume_suspended_processes

    logger -t agentsentry "RESTORED network + processes"
    # Clean up the one-time code
    rm -f "$RESTORE_CODE_FILE" 2>/dev/null || true
}

status() {
    echo "=== Agentic Sandbox Sentry Status ==="
    echo "Enforcement log tail:"
    tail -5 "$ENFORCE_LOG" 2>/dev/null || echo "No enforcement yet"
    echo ""
    echo "Active interface: $(get_active_interface)"
    echo "WiFi power: $(networksetup -getairportpower "$(get_wifi_device)" 2>/dev/null || echo 'unknown')"
    echo "pf status: $(sudo pfctl -s info 2>/dev/null | head -1 || echo 'pf not running')"

    echo ""
    if [[ -f "$RESTORE_CODE_FILE" ]]; then
        echo "⚠️  PENDING RESTORE CODE: $(cat "$RESTORE_CODE_FILE")"
        echo "   (run './enforcement_recovery_module.sh restore' and enter the code)"
    else
        echo "No pending restore code (network should be normal or manually restored)."
    fi

    if [[ -s "$SUSPENDED_PIDS_FILE" ]]; then
        echo ""
        echo "Currently suspended PIDs (from last enforcement):"
        cat "$SUSPENDED_PIDS_FILE"
        echo "(They will be resumed automatically on successful restore)"
    fi
}

# Only execute command when run directly (not when sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # Accept --dry-run anywhere in the arguments (same effect as SENTRY_DRY_RUN=1)
    PARSED_ARGS=()
    for arg in "$@"; do
        if [[ "$arg" == "--dry-run" ]]; then
            DRY_RUN=1
        else
            PARSED_ARGS+=("$arg")
        fi
    done
    set -- ${PARSED_ARGS[@]+"${PARSED_ARGS[@]}"}

    case "${1:-status}" in
        setup) setup ;;
        enforce) shift; enforce "$@" ;;
        restore) restore ;;
        status) status ;;
        *) echo "Usage: $0 [--dry-run] {setup|enforce [reason] [pids_or_path]|restore|status}"; exit 1 ;;
    esac
fi
