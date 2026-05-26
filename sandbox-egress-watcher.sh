#!/bin/bash
# Minimal proc + network egress watcher (P5)
# Uses lsof loop (macOS builtin) to detect unexpected outbound connections
# Triggers enforcement on non-whitelisted PIDs. Lightweight, no extra deps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCEMENT_SCRIPT="${ENFORCEMENT_SCRIPT:-$SCRIPT_DIR/enforcement_recovery_module.sh}"
AUDIT_LOG="${AUDIT_LOG:-/tmp/sandbox-audit.log}"
WHITELIST_PIDS="^$$|fswatch|zsh|bash|Terminal|iTerm"  # basic self + common

echo "=== Egress Watcher (lsof mode) started ==="
echo "Watching for unexpected outbound TCP/UDP..."

while true; do
    # Find outbound connections not from whitelisted
    lsof -nPiTCP -sTCP:ESTABLISHED 2>/dev/null | awk 'NR>1 {print $2, $1, $8}' | while read pid cmd remote; do
        if ! echo "$pid" | grep -qE "$WHITELIST_PIDS"; then
            # Check if from allowed project cwd? Simple heuristic: if not in /Users/.../Projects etc skip for now
            reason="egress: unexpected outbound from PID $pid ($cmd) to $remote"
            echo "[EGRESS] $reason"
            echo "{\"ts\":\"$(date -Iseconds)\",\"event\":\"egress\",\"pid\":$pid,\"cmd\":\"$cmd\",\"remote\":\"$remote\"}" >> "$AUDIT_LOG"
            if [[ -x "$ENFORCEMENT_SCRIPT" ]]; then
                "$ENFORCEMENT_SCRIPT" enforce "$reason" || true
            fi
            sleep 30  # throttle after trigger
        fi
    done
    sleep 10
done
