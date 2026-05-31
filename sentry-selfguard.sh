#!/bin/bash
# sentry-selfguard.sh - Dedicated self-protection monitor for Sentry scripts
# Watches the Sentry codebase itself for tampering.
# Any modification to Sentry scripts triggers:
#   1. Immediate structured log + alert
#   2. Integrity check (SHA-256 baseline comparison)
#   3. Optional enforcement (configurable severity)
#
# Design: runs alongside sandbox-monitor.fswatch.sh but with higher sensitivity
# and dedicated tamper-specific logging (selfguard.log).
#
# Usage:
#   sentry-selfguard.sh start        # Launch fswatch self-protection
#   sentry-selfguard.sh baseline     # Compute + store SHA-256 checksums
#   sentry-selfguard.sh verify       # One-shot integrity check
#   sentry-selfguard.sh status       # Show selfguard health

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENTRY_HOME="${SENTRY_HOME:-$HOME/.hermes}"

# Load logger
if [[ -f "$SCRIPT_DIR/sentry-logger.sh" ]]; then
    source "$SCRIPT_DIR/sentry-logger.sh"
else
    echo "ERROR: sentry-logger.sh not found at $SCRIPT_DIR"
    exit 1
fi

# Load config
if [[ -f "$SCRIPT_DIR/sentry-config.sh" ]]; then
    source "$SCRIPT_DIR/sentry-config.sh"
    load_sentry_config 2>/dev/null || true
fi

# Self-guard specific paths
BASELINE_FILE="$SENTRY_HOME/sentry-baseline.sha256"
META_FILE="$SENTRY_HOME/sentry-baseline.sha256.meta"
SELFGUARD_PID_FILE="$SENTRY_LOG_DIR/selfguard.pid"
ENFORCEMENT_SCRIPT="${ENFORCEMENT_SCRIPT:-$SCRIPT_DIR/enforcement_recovery_module.sh}"

mkdir -p "$SENTRY_HOME" "$SENTRY_LOG_DIR" 2>/dev/null || true

# Meta-hash file (hash of the meta file itself — tamper chain protection)
META_META_FILE="$SENTRY_HOME/sentry-baseline.sha256.metahash"

# Lock timeout for meta operations (seconds)
META_LOCK_TIMEOUT="${META_LOCK_TIMEOUT:-10}"

# --- Portable SHA-256 helper ---
_hash_file() {
    local file="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        sha256sum "$file" | awk '{print $1}'
    fi
}

# --- Meta-hash chain: protect the baseline file itself ---

# Compute and store a SHA-256 hash of the baseline file into META_FILE,
# then hash META_FILE into META_META_FILE. This creates a two-level
# integrity chain: if an attacker modifies the baseline to hide tampered
# files, the meta-hash won't match. If they modify the meta file,
# the metahash won't match.
compute_meta_hash() {
    if [[ ! -f "$BASELINE_FILE" ]]; then
        echo "WARNING: Cannot compute meta-hash — baseline file missing."
        return 1
    fi

    local baseline_hash
    baseline_hash=$(_hash_file "$BASELINE_FILE")

    # Write meta file: hash + timestamp + baseline filename
    local tmp_meta
    tmp_meta=$(mktemp)
    echo "# Sentry baseline meta-hash - $(date -Iseconds)" > "$tmp_meta"
    echo "# Protects sentry-baseline.sha256 from tampering" >> "$tmp_meta"
    echo "${baseline_hash}  sentry-baseline.sha256" >> "$tmp_meta"
    mv "$tmp_meta" "$META_FILE"
    chmod 600 "$META_FILE" 2>/dev/null || true

    # Hash the meta file itself (second level of chain)
    local meta_hash
    meta_hash=$(_hash_file "$META_FILE")
    echo "${meta_hash}  sentry-baseline.sha256.meta" > "$META_META_FILE"
    chmod 600 "$META_META_FILE" 2>/dev/null || true

    # Try to set macOS immutable flag (requires root; silently skipped otherwise)
    if [[ "$(uname -s)" == "Darwin" && "$(id -u)" -eq 0 ]]; then
        chflags schg "$META_FILE" 2>/dev/null || true
        chflags schg "$META_META_FILE" 2>/dev/null || true
        chflags schg "$BASELINE_FILE" 2>/dev/null || true
    fi

    echo "Meta-hash chain computed and protected."
}

# Verify the meta-hash chain before trusting the baseline.
# Returns 0 if chain is intact, 1 if tampering detected.
verify_meta_hash() {
    # Step 1: Verify META_META_FILE → META_FILE chain
    if [[ ! -f "$META_META_FILE" ]]; then
        echo "⚠️  No meta-hash file found. Baseline is unprotected."
        echo "   Run: $0 baseline"
        log_selfguard "META_UNPROTECTED" "Meta-hash file missing — baseline has no tamper protection" \
            "{\"file\":\"$META_META_FILE\"}"
        return 1
    fi

    if [[ ! -f "$META_FILE" ]]; then
        echo "🔴 META FILE MISSING: $META_FILE"
        log_selfguard "META_FILE_MISSING" "Meta file missing — baseline integrity cannot be verified" \
            "{\"file\":\"$META_FILE\"}"
        return 1
    fi

    local expected_meta_hash
    expected_meta_hash=$(awk '/^[^#]/ && NF>=2 {print $1; exit}' "$META_META_FILE" 2>/dev/null)

    if [[ -z "$expected_meta_hash" ]]; then
        echo "🔴 META-HASH FILE CORRUPT: cannot read expected hash"
        log_selfguard "META_CORRUPT" "Meta-hash file is corrupt or empty" \
            "{\"file\":\"$META_META_FILE\"}"
        return 1
    fi

    local actual_meta_hash
    actual_meta_hash=$(_hash_file "$META_FILE")

    if [[ "$actual_meta_hash" != "$expected_meta_hash" ]]; then
        echo "🔴🔴 META FILE TAMPERED: $META_FILE has been modified!"
        echo "   Expected: ${expected_meta_hash:0:16}..."
        echo "   Got:      ${actual_meta_hash:0:16}..."
        log_selfguard "META_TAMPER" "Meta file has been tampered with — baseline trust chain broken" \
            "{\"file\":\"$META_FILE\",\"expected\":\"${expected_meta_hash:0:16}\",\"actual\":\"${actual_meta_hash:0:16}\"}"
        return 1
    fi

    # Step 2: Verify META_FILE → BASELINE_FILE chain
    if [[ ! -f "$BASELINE_FILE" ]]; then
        echo "🔴 BASELINE FILE MISSING: $BASELINE_FILE"
        log_selfguard "BASELINE_MISSING" "Baseline file missing despite meta-hash existing" \
            "{\"file\":\"$BASELINE_FILE\"}"
        return 1
    fi

    local expected_baseline_hash
    expected_baseline_hash=$(awk '/^[^#]/ && NF>=2 {print $1; exit}' "$META_FILE" 2>/dev/null)

    if [[ -z "$expected_baseline_hash" ]]; then
        echo "🔴 META FILE CORRUPT: cannot read expected baseline hash"
        log_selfguard "META_CORRUPT" "Meta file cannot't be parsed for baseline hash" \
            "{\"file\":\"$META_FILE\"}"
        return 1
    fi

    local actual_baseline_hash
    actual_baseline_hash=$(_hash_file "$BASELINE_FILE")

    if [[ "$actual_baseline_hash" != "$expected_baseline_hash" ]]; then
        echo "🔴🔴 BASELINE TAMPERED: $BASELINE_FILE has been modified!"
        echo "   Expected: ${expected_baseline_hash:0:16}..."
        echo "   Got:      ${actual_baseline_hash:0:16}..."
        log_selfguard "BASELINE_TAMPER" "Baseline file has been tampered with — all integrity checks unreliable" \
            "{\"file\":\"$BASELINE_FILE\",\"expected\":\"${expected_baseline_hash:0:16}\",\"actual\":\"${actual_baseline_hash:0:16}\"}"
        return 1
    fi

    echo "🔒 Meta-hash chain verified — baseline is trustworthy."
    return 0
}

# Files to protect (relative to SCRIPT_DIR)
PROTECTED_FILES=(
    "sentryctl"
    "sentry-config.sh"
    "sentry-logger.sh"
    "sentry-selfguard.sh"
    "sentry-status.sh"
    "sandbox-hooks.zsh"
    "sandbox-monitor.fswatch.sh"
    "enforcement_recovery_module.sh"
    "sandbox-egress-watcher.sh"
)

PROTECTED_DIRS=(
    "$SCRIPT_DIR"
    "$SENTRY_HOME"
)

# --- Baseline management ---

compute_baseline() {
    local baseline_lock="$SENTRY_LOG_DIR/selfguard-baseline.lock"
    echo "Computing SHA-256 baseline for Sentry scripts..."
    local tmp
    tmp=$(mktemp)

    echo "# Sentry integrity baseline - $(date -Iseconds)" > "$tmp"
    echo "# Auto-generated by sentry-selfguard.sh" >> "$tmp"
    echo "" >> "$tmp"

    local count=0
    for f in "${PROTECTED_FILES[@]}"; do
        local full_path="$SCRIPT_DIR/$f"
        if [[ -f "$full_path" ]]; then
            local hash
            if command -v shasum >/dev/null 2>&1; then
                hash=$(shasum -a 256 "$full_path" | awk '{print $1}')
            else
                hash=$(sha256sum "$full_path" | awk '{print $1}')
            fi
            echo "$hash  $f" >> "$tmp"
            ((count++))
        fi
    done

    # Also hash the safety rules and config
    for f in "$SENTRY_HOME/sentry-config.json" "$SENTRY_HOME/safety-rules.json"; do
        if [[ -f "$f" ]]; then
            local hash
            if command -v shasum >/dev/null 2>&1; then
                hash=$(shasum -a 256 "$f" | awk '{print $1}')
            else
                hash=$(sha256sum "$f" | awk '{print $1}')
            fi
            echo "$hash  $(basename "$f")" >> "$tmp"
            ((count++))
        fi
    done

    # Acquire lock so fswatch ignores our own writes to baseline/meta files
    echo "$$" > "$baseline_lock"

    # Remove macOS immutable flags before overwriting (set by previous compute_meta_hash)
    if [[ "$(uname -s)" == "Darwin" ]]; then
        chflags noschg "$BASELINE_FILE" 2>/dev/null || true
        chflags noschg "$META_FILE" 2>/dev/null || true
        chflags noschg "$META_META_FILE" 2>/dev/null || true
    fi

    mv "$tmp" "$BASELINE_FILE"
    chmod 600 "$BASELINE_FILE" 2>/dev/null || true

    echo "Baseline saved: $BASELINE_FILE ($count files hashed)"
    log_selfguard "BASELINE" "Computed integrity baseline for $count protected files" \
        "{\"count\":$count,\"baseline_file\":\"$BASELINE_FILE\"}"

    # Compute meta-hash chain to protect the baseline file itself
    compute_meta_hash

    # Release lock (fswatch will now detect external changes to baseline/meta)
    rm -f "$baseline_lock"
}

verify_integrity() {
    if [[ ! -f "$BASELINE_FILE" ]]; then
        echo "No baseline found. Run: $0 baseline"
        return 1
    fi

    # Verify baseline file integrity via meta-hash FIRST
    echo "=== Sentry Integrity Check ==="
    local meta_ok=true
    if ! verify_meta_hash; then
        meta_ok=false
    fi
    echo ""

    local tampered=0
    local checked=0
    local results=()

    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue

        local expected_hash file_ref
        expected_hash=$(echo "$line" | awk '{print $1}')
        file_ref=$(echo "$line" | awk '{print $2}')

        # Resolve file path
        local full_path
        case "$file_ref" in
            sentry-config.json|safety-rules.json)
                full_path="$SENTRY_HOME/$file_ref" ;;
            *)
                full_path="$SCRIPT_DIR/$file_ref" ;;
        esac

        if [[ ! -f "$full_path" ]]; then
            results+=("MISSING: $file_ref")
            ((tampered++))
            ((checked++))
            continue
        fi

        local actual_hash
        if command -v shasum >/dev/null 2>&1; then
            actual_hash=$(shasum -a 256 "$full_path" | awk '{print $1}')
        else
            actual_hash=$(sha256sum "$full_path" | awk '{print $1}')
        fi

        if [[ "$actual_hash" != "$expected_hash" ]]; then
            results+=("TAMPERED: $file_ref (expected ${expected_hash:0:12}... got ${actual_hash:0:12}...)")
            ((tampered++))
        else
            results+=("OK: $file_ref")
        fi
        ((checked++))
    done < "$BASELINE_FILE"

    echo "Checked: $checked files"
    echo "Tampered/Missing: $tampered"
    echo ""
    for r in "${results[@]}"; do
        if [[ "$r" == TAMPERED* || "$r" == MISSING* ]]; then
            echo "  🔴 $r"
        else
            echo "  🟢 $r"
        fi
    done

    if [[ "$meta_ok" == false ]] || (( tampered > 0 )); then
        log_selfguard "INTEGRITY_FAIL" "$tampered file(s) failed integrity check (meta_ok=$meta_ok)" \
            "{\"tampered\":$tampered,\"checked\":$checked,\"meta_ok\":$meta_ok}"
        return 1
    else
        log_selfguard "INTEGRITY_OK" "All $checked files passed integrity check" \
            "{\"checked\":$checked}"
        return 0
    fi
}

# --- fswatch self-protection monitor ---

start_selfguard() {
    if ! command -v fswatch >/dev/null 2>&1; then
        echo "ERROR: fswatch not installed. Install with: brew install fswatch"
        exit 1
    fi

    # Compute baseline if not exists
    if [[ ! -f "$BASELINE_FILE" ]]; then
        compute_baseline
    fi

    echo "=== Sentry Selfguard Monitor ==="
    echo "Watching: ${PROTECTED_DIRS[*]}"
    echo "Baseline: $BASELINE_FILE"
    echo "Any modification to Sentry scripts triggers tamper alert."
    echo "PID: $$"
    echo ""

    # Store PID for status checks
    echo "$$" > "$SELFGUARD_PID_FILE"

    # Cleanup on exit
    trap 'rm -f "$SELFGUARD_PID_FILE"; echo "Selfguard stopped."' EXIT

    # Start fswatch on protected dirs
    fswatch -r -x --event-flags "${PROTECTED_DIRS[@]}" 2>/dev/null | while IFS= read -r line; do
        # Parse the event
        local path events
        local event_regex=' (Removed|Renamed|Updated|Attribute Modified|PlatformSpecific|Created|Moved|IsDir|IsFile)'
        if [[ "$line" =~ $event_regex ]]; then
            path="${line%%$event_regex*}"
            events="${line#*${path} }"
        else
            path="$line"
            events="Unknown"
        fi

        # Filter: only care about modifications to Sentry-related files
        local is_sentry_file=false
        local matched_file=""

        for f in "${PROTECTED_FILES[@]}"; do
            if [[ "$path" == *"$f" ]]; then
                is_sentry_file=true
                matched_file="$f"
                break
            fi
        done

        # Also check config files
        if [[ "$path" == *"sentry-config.json" || "$path" == *"safety-rules.json" ]]; then
            is_sentry_file=true
            matched_file=$(basename "$path")
        fi

        # Skip our own log writes and meta/baseline self-writes
        if [[ "$path" == *".log" || "$path" == *".pid" || "$path" == *".rotate_counter" ]]; then
            continue
        fi

        # Detect external tampering on baseline/meta/metahash files using a lockfile
        if [[ "$path" == *"sentry-baseline.sha256" || "$path" == *".sha256.meta" || "$path" == *".sha256.metahash" ]]; then
            if [[ -f "$SENTRY_LOG_DIR/selfguard-baseline.lock" ]]; then
                continue  # our own write, skip
            fi
            is_sentry_file=true
            matched_file=$(basename "$path")
        fi

        if $is_sentry_file; then
            local reason="TAMPER: Sentry file '$matched_file' was modified ($events)"
            echo "🚨 [SELFGUARD] $reason"
            echo "   Path: $path"
            echo "   Events: $events"
            echo "   Time: $(date)"

            # Structured log
            log_selfguard "TAMPER" "$reason" \
                "{\"file\":\"$matched_file\",\"path\":\"$path\",\"events\":\"$events\"}"

            # macOS notification
            osascript -e "display notification \"Sentry file '$matched_file' was modified! Check integrity.\" with title \"🚨 SENTRY TAMPER ALERT\"" 2>/dev/null || true

            # Run integrity check
            echo ""
            echo "Running integrity verification..."
            verify_integrity || true

            # Trigger enforcement if in hard mode
            if [[ "${SENTRY_MODE:-soft-block}" == "hard" ]]; then
                echo "Hard mode: triggering enforcement for tamper event..."
                if [[ -x "$ENFORCEMENT_SCRIPT" ]]; then
                    "$ENFORCEMENT_SCRIPT" enforce "SELFGUARD TAMPER: $matched_file modified" || true
                fi
            fi

            # Also update baseline after legitimate edits (user can re-run baseline manually)
            echo ""
            echo "If this was a legitimate edit, re-run: $0 baseline"
        fi
    done
}

# --- Status ---

# Colors (matching sentryctl)
_SG_RED='\033[0;31m'
_SG_GREEN='\033[0;32m'
_SG_YELLOW='\033[1;33m'
_SG_BLUE='\033[0;34m'
_SG_CYAN='\033[0;36m'
_SG_DIM='\033[2m'
_SG_BOLD='\033[1m'
_SG_NC='\033[0m'

selfguard_status() {
    echo -e "${_SG_BLUE}${_SG_BOLD}━━━ Sentry Selfguard Status ━━━${_SG_NC}"
    echo ""

    # Check if running
    _sg_header "Monitor"
    if [[ -f "$SELFGUARD_PID_FILE" ]]; then
        local pid
        pid=$(cat "$SELFGUARD_PID_FILE" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo -e "  ${_SG_GREEN}✓ RUNNING${_SG_NC} ${_SG_DIM}(PID $pid)${_SG_NC}"
        else
            echo -e "  ${_SG_YELLOW}⚠ STALE PID FILE${_SG_NC} ${_SG_DIM}(PID $pid not running)${_SG_NC}"
        fi
    else
        echo -e "  ${_SG_YELLOW}⚠ NOT RUNNING${_SG_NC}"
    fi

    echo ""

    # Baseline status
    _sg_header "Baseline"
    if [[ -f "$BASELINE_FILE" ]]; then
        local age
        age=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$BASELINE_FILE" 2>/dev/null || \
              stat -c "%y" "$BASELINE_FILE" 2>/dev/null | cut -d. -f1 || echo "unknown")
        local count
        count=$(grep -v '^#' "$BASELINE_FILE" | grep -v '^$' | wc -l | tr -d ' ')
        echo -e "  ${_SG_BOLD}File:${_SG_NC}    $BASELINE_FILE"
        echo -e "  ${_SG_BOLD}Updated:${_SG_NC} $age"
        echo -e "  ${_SG_BOLD}Tracked:${_SG_NC} $count files"
    else
        echo -e "  ${_SG_YELLOW}⚠ NOT CREATED${_SG_NC}"
        echo -e "  ${_SG_DIM}Run: sentryctl selfguard baseline${_SG_NC}"
    fi

    echo ""

    # Meta-hash chain status
    _sg_header "Meta-hash chain"
    if [[ -f "$META_FILE" ]]; then
        echo -e "  Meta file:     ${_SG_GREEN}✓${_SG_NC} present"
    else
        echo -e "  Meta file:     ${_SG_RED}✗${_SG_NC} MISSING"
    fi
    if [[ -f "$META_META_FILE" ]]; then
        echo -e "  Metahash file: ${_SG_GREEN}✓${_SG_NC} present"
    else
        echo -e "  Metahash file: ${_SG_RED}✗${_SG_NC} MISSING"
    fi
    if [[ -f "$META_FILE" && -f "$META_META_FILE" && -f "$BASELINE_FILE" ]]; then
        if verify_meta_hash >/dev/null 2>&1; then
            echo -e "  Chain status:  ${_SG_GREEN}${_SG_BOLD}🔒 INTACT${_SG_NC}"
        else
            echo -e "  Chain status:  ${_SG_RED}${_SG_BOLD}🔴 BROKEN${_SG_NC}"
        fi
    else
        echo -e "  Chain status:  ${_SG_YELLOW}⚠ INCOMPLETE${_SG_NC} ${_SG_DIM}(run: sentryctl selfguard baseline)${_SG_NC}"
    fi

    echo ""

    # Selfguard log
    _sg_header "Selfguard Log"
    if [[ -f "$SENTRY_SELFLOG" ]]; then
        local total
        total=$(wc -l < "$SENTRY_SELFLOG" 2>/dev/null | tr -d ' ')
        local tamper_count
        tamper_count=$(grep -c '"TAMPER"' "$SENTRY_SELFLOG" 2>/dev/null) || tamper_count=0
        echo -e "  ${_SG_BOLD}File:${_SG_NC}    $SENTRY_SELFLOG"
        echo -e "  ${_SG_BOLD}Events:${_SG_NC}  $total total  ${_SG_RED}$tamper_count tamper${_SG_NC}"

        if (( total > 0 )); then
            echo ""
            echo -e "  ${_SG_BOLD}Last 3 events:${_SG_NC}"
            tail -3 "$SENTRY_SELFLOG" | while read -r line; do
                if command -v jq >/dev/null 2>&1; then
                    local ts decision reason
                    ts=$(echo "$line" | jq -r '.ts // ""' | cut -d'T' -f2 | cut -d'+' -f1)
                    decision=$(echo "$line" | jq -r '.decision // ""')
                    reason=$(echo "$line" | jq -r '.reason // ""' | cut -c1-70)
                    local color="${_SG_GREEN}"
                    [[ "$decision" == *"TAMPER"* || "$decision" == *"FAIL"* ]] && color="${_SG_RED}"
                    printf "    ${color}[%s] %s — %s${_SG_NC}\n" "$ts" "$decision" "$reason"
                else
                    echo "    $line"
                fi
            done
        fi
    else
        echo -e "  ${_SG_DIM}No events yet${_SG_NC}"
    fi
}

# Helper for section headers inside selfguard
_sg_header() {
    echo -e "${_SG_CYAN}${_SG_BOLD}$1${_SG_NC}"
}

# --- Main ---

case "${1:-status}" in
    start|monitor)
        start_selfguard
        ;;
    baseline|hash)
        compute_baseline
        ;;
    verify|check)
        verify_integrity
        ;;
    status)
        selfguard_status
        ;;
    *)
        echo -e "${_SG_BOLD}Usage:${_SG_NC} sentryctl selfguard ${_SG_DIM}<subcommand>${_SG_NC}"
        echo ""
        echo -e "  ${_SG_CYAN}start${_SG_NC}      Launch fswatch self-protection monitor"
        echo -e "  ${_SG_CYAN}baseline${_SG_NC}   Compute SHA-256 checksums of protected files"
        echo -e "  ${_SG_CYAN}verify${_SG_NC}     One-shot integrity check against baseline"
        echo -e "  ${_SG_CYAN}status${_SG_NC}     Show selfguard health and recent events"
        exit 1
        ;;
esac
