#!/bin/bash
# sentry-tui.sh — Real-time Terminal User Interface for Agentic Sandbox Sentry
# Shows live status, component health, and recent violations in a full-screen TUI.
#
# Usage:
#   sentry-tui.sh              # Launch TUI (interactive)
#   sentry-tui.sh --once       # Single snapshot (non-interactive, CI-friendly)
#   sentry-tui.sh --interval N # Custom refresh interval in seconds (default: 2)
#
# Controls (interactive mode):
#   q / Esc   — Quit
#   r         — Force refresh
#   p         — Pause/resume auto-refresh
#   + / -     — Increase/decrease refresh interval
#
# Pure bash + ANSI escape codes. No ncurses, no Python, no external TUI libs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config + logger
# Save env-provided overrides before config load (which exports its own values)
_ENV_AUDIT_LOG="${AUDIT_LOG:-}"
_ENV_SENTRY_LOG_DIR="${SENTRY_LOG_DIR:-}"
_ENV_SENTRY_MODE="${SENTRY_MODE:-}"

if [[ -f "$SCRIPT_DIR/sentry-config.sh" ]]; then
    source "$SCRIPT_DIR/sentry-config.sh"
    load_sentry_config 2>/dev/null || true
fi

# Restore env overrides if they were explicitly set
[[ -n "$_ENV_AUDIT_LOG" ]] && export AUDIT_LOG="$_ENV_AUDIT_LOG"
[[ -n "$_ENV_SENTRY_LOG_DIR" ]] && export SENTRY_LOG_DIR="$_ENV_SENTRY_LOG_DIR"
[[ -n "$_ENV_SENTRY_MODE" ]] && export SENTRY_MODE="$_ENV_SENTRY_MODE"

# --- Terminal capabilities ---
# Prefer tput, fall back to ANSI escape sequences
if command -v tput >/dev/null 2>&1; then
    _HAS_TPUT=true
else
    _HAS_TPUT=false
fi

_tput_clear()    { $_HAS_TPUT && tput clear 2>/dev/null || printf '\033[2J\033[H'; }
_tput_home()     { $_HAS_TPUT && tput home 2>/dev/null || printf '\033[H'; }
_tput_cols()     { $_HAS_TPUT && tput cols 2>/dev/null || echo 80; }
_tput_lines()    { $_HAS_TPUT && tput lines 2>/dev/null || echo 24; }
_tput_cup()      { $_HAS_TPUT && tput cup "$1" "$2" 2>/dev/null || printf '\033[%d;%dH' "$(( $1 + 1 ))" "$(( $2 + 1 ))"; }
_tput_hide_cur() { $_HAS_TPUT && tput civis 2>/dev/null || printf '\033[?25l'; }
_tput_show_cur() { $_HAS_TPUT && tput cnorm 2>/dev/null || printf '\033[?25h'; }
_tput_sgr0()     { $_HAS_TPUT && tput sgr0 2>/dev/null || printf '\033[0m'; }

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'
BG_RED='\033[41m'
BG_GREEN='\033[42m'
BG_YELLOW='\033[43m'
BG_BLUE='\033[44m'

# --- State ---
TUI_INTERVAL="${TUI_INTERVAL:-2}"
TUI_PAUSED=false
TUI_ONCE=false
TUI_START_TIME=$(date +%s)
_last_log_lines=0
_last_log_mtime=0

# Resolve log files
SENTRY_LOG_DIR="${SENTRY_LOG_DIR:-$HOME/.hermes/logs}"
AUDIT_LOG="${AUDIT_LOG:-$SENTRY_LOG_DIR/sandbox-audit.log}"
ENFORCE_LOG="${SENTRY_ENFORCE_LOG:-$SENTRY_LOG_DIR/enforcement.log}"
SELFGUARD_LOG="${SENTRY_SELFLOG:-$SENTRY_LOG_DIR/selfguard.log}"
[[ ! -f "$AUDIT_LOG" && -f "/tmp/sandbox-audit.log" ]] && AUDIT_LOG="/tmp/sandbox-audit.log"

# --- Parse args ---
for arg in "$@"; do
    case "$arg" in
        --once|--snapshot) TUI_ONCE=true ;;
        --interval|--refresh)
            shift
            TUI_INTERVAL="${1:-2}"
            ;;
    esac
done
# Handle --interval N as two args
if [[ "${1:-}" == "--interval" && -n "${2:-}" ]]; then
    TUI_INTERVAL="$2"
fi

# --- Cleanup on exit ---
cleanup() {
    _tput_show_cur
    _tput_sgr0
    printf '\033[?1049l' 2>/dev/null || true  # restore screen if alt buffer used
    echo ""
}
trap cleanup EXIT INT TERM

# --- Drawing helpers ---

# Print a horizontal line of the given width using box-drawing chars
_draw_hline() {
    local width="$1"
    local char="${2:─}"
    local color="${3:-$DIM}"
    printf "${color}"
    printf '%*s' "$width" '' | tr ' ' "$char"
    printf "${NC}"
}

# Print text truncated to fit a given width, with optional color
_print_fit() {
    local text="$1"
    local max_width="$2"
    local color="${3:-}"
    if [[ ${#text} -gt $max_width ]]; then
        text="${text:0:$(( max_width - 1 ))}…"
    fi
    [[ -n "$color" ]] && printf "$color"
    printf '%s' "$text"
    [[ -n "$color" ]] && printf "$NC"
}

# Pad string to exact width
_pad() {
    local text="$1"
    local width="$2"
    local len=${#text}
    if (( len >= width )); then
        printf '%s' "${text:0:$width}"
    else
        printf '%s%*s' "$text" $(( width - len )) ''
    fi
}

# Status indicator dot
_status_dot() {
    local status="$1"  # ok, warn, fail
    case "$status" in
        ok)   printf "${GREEN}●${NC}" ;;
        warn) printf "${YELLOW}○${NC}" ;;
        fail) printf "${RED}✗${NC}" ;;
        *)    printf "${DIM}·${NC}" ;;
    esac
}

# Health bar (e.g. "████████░░" for 80%)
_health_bar() {
    local score="$1"
    local width="${2:-10}"
    local filled=$(( score * width / 100 ))
    local empty=$(( width - filled ))
    local color="$GREEN"
    (( score < 80 )) && color="$YELLOW"
    (( score < 50 )) && color="$RED"

    printf "$color"
    printf '█%.0s' $(seq 1 $filled 2>/dev/null) 2>/dev/null || printf '%*s' "$filled" '' | tr ' ' '█'
    printf "${DIM}"
    printf '░%.0s' $(seq 1 $empty 2>/dev/null) 2>/dev/null || printf '%*s' "$empty" '' | tr ' ' '░'
    printf "${NC}"
}

# --- Data collection ---

_collect_component_status() {
    # Returns: name|status|detail for each component
    local results=()

    # fswatch monitor
    local fswatch_pid
    if fswatch_pid=$(pgrep -f "sandbox-monitor.fswatch.sh" 2>/dev/null | head -1); then
        results+=("fswatch|ok|PID $fswatch_pid")
    else
        results+=("fswatch|warn|not running")
    fi

    # Selfguard
    local sg_pf="$SENTRY_LOG_DIR/selfguard.pid"
    if [[ -f "$sg_pf" ]]; then
        local sp; sp=$(cat "$sg_pf" 2>/dev/null || echo "")
        if [[ -n "$sp" ]] && kill -0 "$sp" 2>/dev/null; then
            results+=("selfguard|ok|PID $sp")
        else
            results+=("selfguard|warn|stale PID")
        fi
    else
        results+=("selfguard|warn|not running")
    fi

    # Egress watcher
    if pgrep -f "egress-watcher" >/dev/null 2>&1; then
        results+=("egress|ok|running")
    else
        results+=("egress|warn|not running")
    fi

    # launchd
    if launchctl list 2>/dev/null | grep -q agentsentry; then
        results+=("launchd|ok|loaded")
    else
        results+=("launchd|warn|not loaded")
    fi

    # fswatch binary
    if command -v fswatch >/dev/null 2>&1; then
        results+=("fswatch-bin|ok|installed")
    else
        results+=("fswatch-bin|fail|not installed")
    fi

    # jq
    if command -v jq >/dev/null 2>&1; then
        results+=("jq|ok|installed")
    else
        results+=("jq|warn|not installed")
    fi

    printf '%s\n' "${results[@]}"
}

_collect_health_score() {
    local score=100
    pgrep -f "sandbox-monitor.fswatch.sh" >/dev/null 2>&1 || (( score -= 15 ))
    pgrep -f "egress-watcher" >/dev/null 2>&1 || (( score -= 5 ))
    launchctl list 2>/dev/null | grep -q agentsentry || (( score -= 5 ))
    command -v fswatch >/dev/null 2>&1 || (( score -= 25 ))
    command -v jq >/dev/null 2>&1 || (( score -= 5 ))

    # Check selfguard
    local sg_pf="$SENTRY_LOG_DIR/selfguard.pid"
    if [[ -f "$sg_pf" ]]; then
        local sp; sp=$(cat "$sg_pf" 2>/dev/null || echo "")
        [[ -n "$sp" ]] && kill -0 "$sp" 2>/dev/null || (( score -= 10 ))
    else
        (( score -= 10 ))
    fi

    (( score < 0 )) && score=0
    echo "$score"
}

_collect_violation_stats() {
    # Returns: total|blocked|hard|detected
    if [[ ! -f "$AUDIT_LOG" ]]; then
        echo "0|0|0|0"
        return
    fi

    local total blocked hard detected
    total=$(wc -l < "$AUDIT_LOG" 2>/dev/null | tr -d ' ' || echo 0)
    blocked=$(grep -cE '"decision":"(SOFT_BLOCKED|BLOCKED)"' "$AUDIT_LOG" 2>/dev/null) || blocked=0
    hard=$(grep -c '"HARD_ENFORCEMENT"' "$AUDIT_LOG" 2>/dev/null) || hard=0
    detected=$(grep -c '"decision":"DETECTED"' "$AUDIT_LOG" 2>/dev/null) || detected=0

    echo "${total}|${blocked}|${hard}|${detected}"
}

_collect_recent_violations() {
    local count="${1:-12}"
    [[ ! -f "$AUDIT_LOG" ]] && return

    if command -v jq >/dev/null 2>&1; then
        tail -n "$count" "$AUDIT_LOG" 2>/dev/null | while IFS= read -r line; do
            local ts decision reason severity
            ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null | cut -d'T' -f2 | cut -d'+' -f1 | cut -d'.' -f1)
            decision=$(echo "$line" | jq -r '.decision // ""' 2>/dev/null)
            reason=$(echo "$line" | jq -r '.reason // ""' 2>/dev/null)
            severity=$(echo "$line" | jq -r '.severity // "info"' 2>/dev/null)
            echo "${ts}|${decision}|${reason}|${severity}"
        done
    else
        tail -n "$count" "$AUDIT_LOG" 2>/dev/null | while IFS= read -r line; do
            echo "??|??|${line:0:80}|info"
        done
    fi
}

_check_log_changed() {
    if [[ ! -f "$AUDIT_LOG" ]]; then
        echo "false"
        return
    fi
    local current_lines current_mtime
    current_lines=$(wc -l < "$AUDIT_LOG" 2>/dev/null | tr -d ' ' || echo 0)
    current_mtime=$(stat -f %m "$AUDIT_LOG" 2>/dev/null || stat -c %Y "$AUDIT_LOG" 2>/dev/null || echo 0)

    if [[ "$current_lines" != "$_last_log_lines" || "$current_mtime" != "$_last_log_mtime" ]]; then
        _last_log_lines="$current_lines"
        _last_log_mtime="$current_mtime"
        echo "true"
    else
        echo "false"
    fi
}

# --- Rendering ---

_render_header() {
    local cols="$1"
    local now
    now=$(date '+%H:%M:%S')
    local mode="${SENTRY_MODE:-unknown}"
    local host
    host=$(hostname -s 2>/dev/null || hostname)

    # Top bar
    printf "${BG_BLUE}${WHITE}${BOLD}"
    local title=" ◆ AGENTIC SANDBOX SENTRY "
    local right=" ${now} "
    local pad_len=$(( cols - ${#title} - ${#right} ))
    (( pad_len < 0 )) && pad_len=0
    printf '%s%*s%s' "$title" "$pad_len" '' "$right"
    printf "${NC}\n"

    # Sub-header
    local uptime_sec=$(( $(date +%s) - TUI_START_TIME ))
    local uptime_str
    if (( uptime_sec >= 86400 )); then
        uptime_str="$(( uptime_sec / 86400 ))d $(( (uptime_sec % 86400) / 3600 ))h"
    elif (( uptime_sec >= 3600 )); then
        uptime_str="$(( uptime_sec / 3600 ))h $(( (uptime_sec % 3600) / 60 ))m"
    else
        uptime_str="${uptime_sec}s"
    fi

    printf "  ${BOLD}Mode:${NC} ${YELLOW}%s${NC}" "$mode"
    printf "  ${DIM}│${NC}  ${BOLD}Host:${NC} %s" "$host"
    printf "  ${DIM}│${NC}  ${BOLD}Session:${NC} %s" "$uptime_str"
    if $TUI_PAUSED; then
        printf "  ${BG_YELLOW}${BOLD} PAUSED ${NC}"
    fi
    printf '\n'
}

_render_components() {
    local cols="$1"
    local half=$(( cols / 2 - 1 ))

    printf '\n'
    printf "  ${BOLD}${CYAN}┌─ COMPONENT HEALTH"
    printf '%*s' $(( half - 20 )) '' | tr ' ' '─'
    printf "┐${NC}\n"

    _collect_component_status | while IFS='|' read -r name status detail; do
        local dot
        dot=$(_status_dot "$status")
        local label
        case "$name" in
            fswatch)      label="fswatch monitor" ;;
            selfguard)    label="selfguard" ;;
            egress)       label="egress watcher" ;;
            launchd)      label="launchd agent" ;;
            fswatch-bin)  label="fswatch binary" ;;
            jq)           label="jq" ;;
            *)            label="$name" ;;
        esac

        printf "  ${CYAN}│${NC}  %s  " "$dot"
        _pad "$label" 18
        printf " ${DIM}%s${NC}" "$detail"
        # Pad to close the box
        local content_len=$(( 4 + ${#detail} + 18 ))
        local pad=$(( half - content_len - 1 ))
        (( pad > 0 )) && printf '%*s' "$pad" ''
        printf " ${CYAN}│${NC}\n"
    done

    printf "  ${BOLD}${CYAN}└"
    printf '%*s' "$half" '' | tr ' ' '─'
    printf "┘${NC}\n"
}

_render_violations_summary() {
    local cols="$1"
    local stats
    stats=$(_collect_violation_stats)
    IFS='|' read -r total blocked hard detected <<< "$stats"

    local health
    health=$(_collect_health_score)

    printf '\n'
    printf "  ${BOLD}${CYAN}┌─ VIOLATION SUMMARY"
    local half=$(( cols / 2 - 1 ))
    printf '%*s' $(( half - 21 )) '' | tr ' ' '─'
    printf "┐${NC}\n"

    printf "  ${CYAN}│${NC}  ${BOLD}Total events:${NC}   %-8s" "$total"
    printf "   ${CYAN}│${NC}\n"
    printf "  ${CYAN}│${NC}  ${RED}Blocked:${NC}        %-8s" "$blocked"
    printf "   ${CYAN}│${NC}\n"
    printf "  ${CYAN}│${NC}  ${RED}Hard enforce:${NC}   %-8s" "$hard"
    printf "   ${CYAN}│${NC}\n"
    printf "  ${CYAN}│${NC}  ${YELLOW}Detected:${NC}       %-8s" "$detected"
    printf "   ${CYAN}│${NC}\n"
    printf "  ${CYAN}│${NC}  ${BOLD}Health:${NC}  "
    _health_bar "$health" 12
    printf " %3d/100  ${CYAN}│${NC}\n" "$health"

    printf "  ${BOLD}${CYAN}└"
    printf '%*s' "$half" '' | tr ' ' '─'
    printf "┘${NC}\n"
}

_render_recent_violations() {
    local cols="$1"
    local max_rows="${2:-10}"
    local content_width=$(( cols - 6 ))

    printf '\n'
    printf "  ${BOLD}${CYAN}┌─ RECENT VIOLATIONS"
    printf '%*s' $(( cols - 24 )) '' | tr ' ' '─'
    printf "┐${NC}\n"

    local violations
    violations=$(_collect_recent_violations "$max_rows")

    if [[ -z "$violations" ]]; then
        printf "  ${CYAN}│${NC}  ${DIM}(no violations recorded yet)${NC}\n"
    else
        echo "$violations" | tail -r | while IFS='|' read -r ts decision reason severity; do
            local color="$GREEN" icon="ℹ"
            case "$decision" in
                *BLOCKED*|HARD_ENFORCEMENT) color="$RED"; icon="⛔" ;;
                SOFT_BLOCKED) color="$RED"; icon="⛔" ;;
                DETECTED) color="$YELLOW"; icon="⚠" ;;
            esac

            # Truncate reason to fit
            local reason_max=$(( content_width - 28 ))
            (( reason_max < 20 )) && reason_max=20
            if [[ ${#reason} -gt $reason_max ]]; then
                reason="${reason:0:$(( reason_max - 1 ))}…"
            fi

            printf "  ${CYAN}│${NC}  ${DIM}%s${NC} ${color}%s %s${NC}" \
                "${ts:-??:??:??}" "$icon" "$decision"
            printf " — %s\n" "$reason"
        done
    fi

    printf "  ${BOLD}${CYAN}└"
    printf '%*s' $(( cols - 2 )) '' | tr ' ' '─'
    printf "┘${NC}\n"
}

_render_footer() {
    local cols="$1"
    local changed
    changed=$(_check_log_changed)

    # Bottom bar
    printf "${DIM}"
    printf '%*s' "$cols" '' | tr ' ' '─'
    printf "${NC}\n"

    printf "  ${DIM}[q]${NC} Quit"
    printf "  ${DIM}[r]${NC} Refresh"
    printf "  ${DIM}[p]${NC} Pause"
    printf "  ${DIM}[+/-]${NC} Interval"
    printf "  ${DIM}│${NC}  Refresh: ${BOLD}%ds${NC}" "$TUI_INTERVAL"

    if [[ "$changed" == "true" ]]; then
        printf "  ${GREEN}● live${NC}"
    else
        printf "  ${DIM}● idle${NC}"
    fi

    printf '\n'
}

# --- Full render pass ---

_render_frame() {
    local cols lines
    cols=$(_tput_cols)
    lines=$(_tput_lines)

    # Clamp to reasonable minimums
    (( cols < 60 )) && cols=60
    (( lines < 20 )) && lines=20

    _tput_home

    _render_header "$cols"

    # Two-column layout for components + summary
    # We'll render them side by side conceptually, but since bash line-by-line
    # is tricky, we'll stack them instead for reliability.
    _render_components "$cols"
    _render_violations_summary "$cols"

    # Calculate remaining rows for violations list
    local used_rows=22  # approximate header + components + summary
    local avail_rows=$(( lines - used_rows - 3 ))  # 3 for footer
    (( avail_rows < 3 )) && avail_rows=3
    (( avail_rows > 20 )) && avail_rows=20

    _render_recent_violations "$cols" "$avail_rows"
    _render_footer "$cols"

    # Clear any leftover content below our render
    printf '\033[J'
}

# --- Once mode (non-interactive snapshot) ---

_render_once() {
    _render_frame
    echo ""
}

# --- Main loop ---

main() {
    if $TUI_ONCE; then
        _render_once
        exit 0
    fi

    # Enter alt screen buffer (so we restore the terminal on exit)
    printf '\033[?1049h' 2>/dev/null || true
    _tput_clear
    _tput_hide_cur

    # Initial render
    _render_frame

    while true; do
        # Non-blocking read for keypress (timeout = refresh interval)
        local key=""
        if read -rsn1 -t "$TUI_INTERVAL" key 2>/dev/null; then
            case "$key" in
                q|Q|$'\x1b')  # q or Escape
                    break
                    ;;
                r|R)
                    # Force refresh
                    _render_frame
                    ;;
                p|P)
                    if $TUI_PAUSED; then
                        TUI_PAUSED=false
                    else
                        TUI_PAUSED=true
                    fi
                    _render_frame
                    ;;
                +|=)
                    (( TUI_INTERVAL < 30 )) && (( TUI_INTERVAL++ ))
                    _render_frame
                    ;;
                -|_)
                    (( TUI_INTERVAL > 1 )) && (( TUI_INTERVAL-- ))
                    _render_frame
                    ;;
            esac
        fi

        # Auto-refresh if not paused
        if ! $TUI_PAUSED; then
            _render_frame
        fi
    done
}

main
