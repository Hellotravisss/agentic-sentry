#!/bin/bash
# sentry-status: quick health check (P6)
# Shows monitor status, last enforcement, launchd, fswatch health

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCEMENT="$SCRIPT_DIR/enforcement_recovery_module.sh"

echo "=== Agentic Sandbox Sentry Status ==="
echo "Date: $(date)"
echo ""

echo "1. Enforcement module:"
"$ENFORCEMENT" status 2>/dev/null || echo "  (run ./enforcement_recovery_module.sh setup first)"

echo ""
echo "2. launchd agent:"
launchctl list | grep agentsentry || echo "  com.agentsentry.fswatch not loaded (run install.sh)"

echo ""
echo "3. fswatch process:"
pgrep -fl fswatch || echo "  No fswatch running"

echo ""
echo "4. Recent audit (tail):"
tail -5 /tmp/sandbox-audit.log 2>/dev/null || echo "  No audit log yet"

echo ""
echo "5. Egress watcher (if running):"
pgrep -fl egress-watcher || echo "  (optional) not running"

echo ""
echo "Usage: source sandbox-hooks.zsh | $SCRIPT_DIR/enforcement... | install.sh"
echo "Self-protection: fswatch monitors $SCRIPT_DIR too"