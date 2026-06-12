#!/bin/bash
# sentry-status.sh - Comprehensive health check and violation reporting
# Shows the full operational status of the Agentic Sandbox Sentry system.
#
# Usage:
#   sentry-status.sh              # Full status report
#   sentry-status.sh --json       # Machine-readable JSON output
#   sentry-status.sh --violations # Violation report only
#   sentry-status.sh --health     # Health check only (exit code reflects health)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCEMENT="$SCRIPT_DIR/enforcement_recovery_module.sh"
SELFGUARD="$SCRIPT_DIR/sentry-selfguard.sh"

# Load config + logger
if [[ -f "$SCRIPT_DIR/sentry-config.sh" ]]; then
    source "$SCRIPT_DIR/sentry-config.sh"
    load_sentry_config 2>/dev/null || true
fi
if [[ -f "$SCRIPT_DIR/sentry-logger.sh" ]]; then
    source "$SCRIPT_DIR/sentry-logger.sh"
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Resolve log files (home resolution kept in sync with sentry-config.sh)
if [[ -z "${SENTRY_HOME:-}" ]]; then
    if [[ -f "$HOME/.agentsentry/sentry-config.json" ]]; then
        SENTRY_HOME="$HOME/.agentsentry"
    elif [[ -f "$HOME/.hermes/sentry-config.json" ]]; then
        SENTRY_HOME="$HOME/.hermes"
    else
        SENTRY_HOME="$HOME/.agentsentry"
    fi
fi
AUDIT_LOG="${AUDIT_LOG:-$SENTRY_HOME/logs/sandbox-audit.log}"
ENFORCE_LOG="${SENTRY_ENFORCE_LOG:-$SENTRY_HOME/logs/enforcement.log}"
SELFGUARD_LOG="${SENTRY_SELFLOG:-$SENTRY_HOME/logs/selfguard.log}"
[[ ! -f "$AUDIT_LOG" && -f "/tmp/sandbox-audit.log" ]] && AUDIT_LOG="/tmp/sandbox-audit.log"

# Parse args
JSON_OUTPUT=false
VIOLATIONS_ONLY=false
HEALTH_ONLY=false
for arg in "$@"; do
    case "$arg" in
        --json) JSON_OUTPUT=true ;;
        --violations) VIOLATIONS_ONLY=true ;;
        --health) HEALTH_ONLY=true ;;
    esac
done

# --- Health check helpers ---

_health_score=100  # Start at 100, deduct for issues
_health_issues=()

check_component() {
    local name="$1"
    local status="$2"  # "ok" "warn" "fail"
    local detail="${3:-}"

    case "$status" in
        ok)
            [[ "$JSON_OUTPUT" == "false" ]] && echo -e "  ${GREEN}✓${NC} $name${detail:+ — $detail}"
            ;;
        warn)
            [[ "$JSON_OUTPUT" == "false" ]] && echo -e "  ${YELLOW}⚠${NC} $name${detail:+ — $detail}"
            ((_health_score -= 10))
            _health_issues+=("$name: $detail")
            ;;
        fail)
            [[ "$JSON_OUTPUT" == "false" ]] && echo -e "  ${RED}✗${NC} $name${detail:+ — $detail}"
            ((_health_score -= 25))
            _health_issues+=("$name: $detail")
            ;;
    esac
}

# --- Violation reporting ---

generate_violation_report() {
    [[ ! -f "$AUDIT_LOG" ]] && echo "No audit log found." && return

    if ! command -v jq >/dev/null 2>&1; then
        echo "jq is required for violation reporting (brew install jq)"
        return
    fi

    local total blocked hard detected
    total=$(wc -l < "$AUDIT_LOG" 2>/dev/null | tr -d ' ' || echo 0)
    blocked=$(grep -cE '"decision":"(SOFT_BLOCKED|BLOCKED)"' "$AUDIT_LOG" 2>/dev/null) || blocked=0
    hard=$(grep -c '"HARD_ENFORCEMENT"' "$AUDIT_LOG" 2>/dev/null) || hard=0
    detected=$(grep -c '"decision":"DETECTED"' "$AUDIT_LOG" 2>/dev/null) || detected=0

    if [[ "$JSON_OUTPUT" == "true" ]]; then
        # JSON output
        printf '{"total_events":%d,"blocked":%d,"hard_enforcement":%d,"detected_allowed":%d' \
            "$total" "$blocked" "$hard" "$detected"

        # Time range
        if (( total > 0 )); then
            local first_ts last_ts
            first_ts=$(head -1 "$AUDIT_LOG" | jq -r '.ts // ""' 2>/dev/null)
            last_ts=$(tail -1 "$AUDIT_LOG" | jq -r '.ts // ""' 2>/dev/null)
            printf ',"first_event":"%s","last_event":"%s"' "$first_ts" "$last_ts"
        fi

        # Top violation reasons
        printf ',"top_reasons":['
        jq -r '.reason // empty' "$AUDIT_LOG" 2>/dev/null | \
            sort | uniq -c | sort -rn | head -5 | \
            while read -r count reason; do
                printf '{"count":%d,"reason":"%s"},' "$count" "$(echo "$reason" | sed 's/"/\\"/g')"
            done | sed 's/,$//'
        printf ']'

        # Top blocked commands
        printf ',"top_commands":['
        jq -r '.cmd // empty' "$AUDIT_LOG" 2>/dev/null | \
            cut -c1-80 | sort | uniq -c | sort -rn | head -5 | \
            while read -r count cmd; do
                printf '{"count":%d,"cmd":"%s"},' "$count" "$(echo "$cmd" | sed 's/"/\\"/g')"
            done | sed 's/,$//'
        printf ']'

        printf '}\n'
        return
    fi

    # Human-readable report
    echo -e "${BLUE}=== Violation Report ===${NC}"
    echo ""
    echo -e "  Total events:        $total"
    echo -e "  ${RED}Blocked (prevented): $blocked${NC}"
    echo -e "  ${RED}Hard enforcement:    $hard${NC}"
    echo -e "  ${YELLOW}Detected (allowed):  $detected${NC}"
    echo ""

    if (( total > 0 )); then
        local first_ts last_ts
        first_ts=$(head -1 "$AUDIT_LOG" | jq -r '.ts // "unknown"' 2>/dev/null | cut -d'T' -f1)
        last_ts=$(tail -1 "$AUDIT_LOG" | jq -r '.ts // "unknown"' 2>/dev/null | cut -d'T' -f1)
        echo -e "  Time range: ${first_ts} → ${last_ts}"
        echo ""
    fi

    # Top violation reasons
    echo -e "  ${BOLD}Top violation reasons:${NC}"
    jq -r '.reason // empty' "$AUDIT_LOG" 2>/dev/null | \
        sort | uniq -c | sort -rn | head -6 | while read -r count reason; do
            printf "    %4s  %s\n" "$count" "$reason"
        done 2>/dev/null || echo "    (no data)"

    echo ""

    # Top blocked commands
    echo -e "  ${BOLD}Most-triggered commands:${NC}"
    jq -r '.cmd // empty' "$AUDIT_LOG" 2>/dev/null | \
        cut -c1-80 | sort | uniq -c | sort -rn | head -6 | while read -r count cmd; do
            printf "    %4s  %s\n" "$count" "$cmd"
        done 2>/dev/null || echo "    (no data)"

    echo ""

    # Severity breakdown (from structured logs)
    echo -e "  ${BOLD}Severity breakdown:${NC}"
    local critical warning info
    critical=$(grep -c '"severity":"critical"' "$AUDIT_LOG" 2>/dev/null) || critical=0
    warning=$(grep -c '"severity":"warning"' "$AUDIT_LOG" 2>/dev/null) || warning=0
    info=$(grep -c '"severity":"info"' "$AUDIT_LOG" 2>/dev/null) || info=0
    echo -e "    ${RED}Critical: $critical${NC}  ${YELLOW}Warning: $warning${NC}  Info: $info"

    # Recent violations (last 5)
    echo ""
    echo -e "  ${BOLD}Last 5 violations:${NC}"
    tail -5 "$AUDIT_LOG" | while read -r line; do
        local ts decision reason
        ts=$(echo "$line" | jq -r '.ts // ""' 2>/dev/null | cut -d'T' -f2 | cut -d'+' -f1)
        decision=$(echo "$line" | jq -r '.decision // ""' 2>/dev/null)
        reason=$(echo "$line" | jq -r '.reason // ""' 2>/dev/null | cut -c1-70)
        local color="$GREEN"
        [[ "$decision" == *"BLOCK"* || "$decision" == *"HARD"* ]] && color="$RED"
        [[ "$decision" == "DETECTED" ]] && color="$YELLOW"
        printf "    ${color}[%s] %s — %s${NC}\n" "$ts" "$decision" "$reason"
    done 2>/dev/null || echo "    (no data)"
}

# --- Full status report ---

generate_full_status() {
    echo -e "${BLUE}${BOLD}=== Agentic Sandbox Sentry — Full Status ===${NC}"
    echo -e "Date: $(date)"
    echo -e "Host: $(hostname -s 2>/dev/null || hostname)"
    echo ""

    # 1. Configuration
    echo -e "${BOLD}1. Configuration${NC}"
    if command -v print_sentry_config >/dev/null 2>&1; then
        print_sentry_config 2>/dev/null | sed 's/^/  /'
    else
        echo "  Mode: ${SENTRY_MODE:-unknown}"
        echo "  Audit log: ${AUDIT_LOG:-unknown}"
    fi
    echo ""

    # 2. Component health
    echo -e "${BOLD}2. Component Health${NC}"

    # Shell hooks
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        check_component "Shell hooks (zsh)" "ok" "loaded"
    else
        check_component "Shell hooks" "warn" "not loaded in current shell (source sandbox-hooks.zsh)"
    fi

    # fswatch monitor
    if pgrep -f "sandbox-monitor.fswatch.sh" >/dev/null 2>&1; then
        local fswatch_pid
        fswatch_pid=$(pgrep -f "sandbox-monitor.fswatch.sh" | head -1)
        check_component "fswatch monitor" "ok" "PID $fswatch_pid"
    else
        check_component "fswatch monitor" "warn" "not running"
    fi

    # Selfguard
    local sg_pid_file="$SENTRY_LOG_DIR/selfguard.pid"
    if [[ -f "$sg_pid_file" ]]; then
        local sg_pid
        sg_pid=$(cat "$sg_pid_file" 2>/dev/null || echo "")
        if [[ -n "$sg_pid" ]] && kill -0 "$sg_pid" 2>/dev/null; then
            check_component "Selfguard monitor" "ok" "PID $sg_pid"
        else
            check_component "Selfguard monitor" "warn" "stale PID file"
        fi
    else
        check_component "Selfguard monitor" "warn" "not running"
    fi

    # Egress watcher
    if pgrep -f "egress-watcher" >/dev/null 2>&1; then
        check_component "Egress watcher" "ok" "running"
    else
        check_component "Egress watcher" "warn" "not running (optional)"
    fi

    # launchd
    if launchctl list 2>/dev/null | grep -q agentsentry; then
        check_component "launchd agent" "ok" "loaded"
    else
        check_component "launchd agent" "warn" "not loaded (run install.sh for persistence)"
    fi

    # fswatch binary
    if command -v fswatch >/dev/null 2>&1; then
        check_component "fswatch binary" "ok" "$(fswatch --version 2>/dev/null | head -1 || echo 'installed')"
    else
        check_component "fswatch binary" "fail" "not installed (brew install fswatch)"
    fi

    # jq
    if command -v jq >/dev/null 2>&1; then
        check_component "jq" "ok" "installed"
    else
        check_component "jq" "warn" "not installed (limits log parsing)"
    fi

    echo ""

    # 3. Integrity (selfguard)
    echo -e "${BOLD}3. Self-Protection / Integrity${NC}"
    if [[ -x "$SELFGUARD" ]]; then
        # Quick inline check
        local baseline_file="$SENTRY_HOME/sentry-baseline.sha256"
        if [[ -f "$baseline_file" ]]; then
            local age
            age=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$baseline_file" 2>/dev/null || \
                  stat -c "%y" "$baseline_file" 2>/dev/null | cut -d. -f1 || echo "unknown")
            echo "  Baseline: $baseline_file (updated: $age)"
        else
            echo "  Baseline: not created (run sentry-selfguard.sh baseline)"
        fi
    else
        echo "  Selfguard script not found or not executable"
    fi
    echo ""

    # 4. Log statistics
    echo -e "${BOLD}4. Log Statistics${NC}"
    for log_name in "Audit:$AUDIT_LOG" "Enforcement:$ENFORCE_LOG" "Selfguard:$SELFGUARD_LOG"; do
        local name="${log_name%%:*}"
        local path="${log_name#*:}"
        if [[ -f "$path" ]]; then
            local lines size
            lines=$(wc -l < "$path" 2>/dev/null | tr -d ' ')
            size=$(wc -c < "$path" 2>/dev/null | tr -d ' ')
            local size_human
            if (( size > 1048576 )); then
                size_human="$(( size / 1048576 ))MB"
            elif (( size > 1024 )); then
                size_human="$(( size / 1024 ))KB"
            else
                size_human="${size}B"
            fi
            local rotated
            rotated=$(ls -1 "${path}".* 2>/dev/null | wc -l | tr -d ' ')
            echo -e "  $name: $lines events, $size_human (${rotated} rotated files)"
        else
            echo -e "  $name: no log yet"
        fi
    done
    echo ""

    # 5. Violation report
    generate_violation_report
    echo ""

    # 6. Enforcement status
    echo -e "${BOLD}5. Enforcement Module${NC}"
    if [[ -x "$ENFORCEMENT" ]]; then
        "$ENFORCEMENT" status 2>/dev/null | sed 's/^/  /' || echo "  (run ./enforcement_recovery_module.sh setup first)"
    else
        echo "  Enforcement script not found or not executable"
    fi

    echo ""

    # Overall health score
    echo -e "${BOLD}6. Overall Health Score${NC}"
    local score_color="$GREEN"
    if (( _health_score < 50 )); then
        score_color="$RED"
    elif (( _health_score < 80 )); then
        score_color="$YELLOW"
    fi
    echo -e "  ${score_color}${BOLD}Score: $_health_score / 100${NC}"
    if (( ${#_health_issues[@]} > 0 )); then
        echo ""
        echo "  Issues:"
        for issue in "${_health_issues[@]}"; do
            echo -e "    ${YELLOW}• $issue${NC}"
        done
    fi

    echo ""
    echo -e "${CYAN}Commands: sentryctl logs --follow | sentryctl violations | sentryctl health${NC}"
}

# --- JSON status output ---

generate_json_status() {
    local mode="${SENTRY_MODE:-unknown}"
    local audit_total=0
    local audit_blocked=0

    if [[ -f "$AUDIT_LOG" ]]; then
        audit_total=$(wc -l < "$AUDIT_LOG" 2>/dev/null | tr -d ' ' || echo 0)
        audit_blocked=$(grep -cE '"decision":"(SOFT_BLOCKED|BLOCKED|HARD_ENFORCEMENT)"' "$AUDIT_LOG" 2>/dev/null) || audit_blocked=0
    fi

    # Component statuses
    local fswatch_running="false"
    pgrep -f "sandbox-monitor.fswatch.sh" >/dev/null 2>&1 && fswatch_running="true"
    local selfguard_running="false"
    local sg_pf="$SENTRY_LOG_DIR/selfguard.pid"
    if [[ -f "$sg_pf" ]]; then
        local sp; sp=$(cat "$sg_pf" 2>/dev/null || echo "")
        [[ -n "$sp" ]] && kill -0 "$sp" 2>/dev/null && selfguard_running="true"
    fi
    local egress_running="false"
    pgrep -f "egress-watcher" >/dev/null 2>&1 && egress_running="true"
    local launchd_loaded="false"
    launchctl list 2>/dev/null | grep -q agentsentry && launchd_loaded="true"

    printf '{"ts":"%s","host":"%s","mode":"%s"' \
        "$(date -Iseconds)" "$(hostname -s)" "$mode"
    printf ',"components":{"fswatch":%s,"selfguard":%s,"egress":%s,"launchd":%s}' \
        "$fswatch_running" "$selfguard_running" "$egress_running" "$launchd_loaded"
    printf ',"logs":{"audit_total":%d,"audit_blocked":%d' "$audit_total" "$audit_blocked"
    printf ',"audit_file":"%s"' "$AUDIT_LOG"
    printf '}'
    printf ',"health_score":%d' "$_health_score"
    printf '}\n'
}

# --- Main ---

if [[ "$JSON_OUTPUT" == "true" ]]; then
    # Run health checks silently (suppress output)
    exec 3>&1  # Save stdout
    # Run checks but capture score
    _json_mode=true
    # Quick health calculation
    pgrep -f "sandbox-monitor.fswatch.sh" >/dev/null 2>&1 || ((_health_score -= 10))
    pgrep -f "egress-watcher" >/dev/null 2>&1 || ((_health_score -= 5))
    launchctl list 2>/dev/null | grep -q agentsentry || ((_health_score -= 5))
    command -v fswatch >/dev/null 2>&1 || ((_health_score -= 25))
    command -v jq >/dev/null 2>&1 || ((_health_score -= 5))

    generate_json_status
    exit 0
fi

if [[ "$HEALTH_ONLY" == "true" ]]; then
    echo -e "${BLUE}${BOLD}=== Sentry Health Check ===${NC}"
    echo ""
    check_component "fswatch monitor" \
        "$(pgrep -f 'sandbox-monitor.fswatch.sh' >/dev/null 2>&1 && echo ok || echo warn)" \
        "$(pgrep -f 'sandbox-monitor.fswatch.sh' >/dev/null 2>&1 && echo 'running' || echo 'not running')"
    check_component "Selfguard" \
        "$(if [[ -f "$SENTRY_LOG_DIR/selfguard.pid" ]]; then p=$(cat "$SENTRY_LOG_DIR/selfguard.pid"); kill -0 "$p" 2>/dev/null && echo ok || echo warn; else echo warn; fi)" \
        "$(if [[ -f "$SENTRY_LOG_DIR/selfguard.pid" ]]; then echo "PID $(cat "$SENTRY_LOG_DIR/selfguard.pid")"; else echo "not running"; fi)"
    check_component "Egress watcher" \
        "$(pgrep -f 'egress-watcher' >/dev/null 2>&1 && echo ok || echo warn)" \
        "$(pgrep -f 'egress-watcher' >/dev/null 2>&1 && echo 'running' || echo 'not running')"
    check_component "fswatch binary" \
        "$(command -v fswatch >/dev/null 2>&1 && echo ok || echo fail)" \
        "$(command -v fswatch >/dev/null 2>&1 && echo 'installed' || echo 'NOT INSTALLED')"
    check_component "jq" \
        "$(command -v jq >/dev/null 2>&1 && echo ok || echo warn)" \
        "$(command -v jq >/dev/null 2>&1 && echo 'installed' || echo 'not installed')"

    echo ""
    score_color="$GREEN"
    (( _health_score < 50 )) && score_color="$RED"
    (( _health_score >= 50 && _health_score < 80 )) && score_color="$YELLOW"
    echo -e "  ${score_color}${BOLD}Health: $_health_score / 100${NC}"
    exit $(( _health_score < 50 ? 1 : 0 ))
fi

if [[ "$VIOLATIONS_ONLY" == "true" ]]; then
    generate_violation_report
    exit 0
fi

generate_full_status
