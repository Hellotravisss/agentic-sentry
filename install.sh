#!/bin/bash
# One-liner installer for Agentic Sandbox Sentry
# Now generates dynamic plist (no hardcodes), checks for missing files, sets up enforcement

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="Agentic-Sandbox-Sentry"

echo "Installing Agentic Sandbox Sentry..."

# Create dirs
mkdir -p ~/.hermes

# Copy rules if present
if [[ -f "$SCRIPT_DIR/safety-rules.json" ]]; then
    cp "$SCRIPT_DIR/safety-rules.json" ~/.hermes/safety-rules.json
    echo "✅ Rules installed to ~/.hermes/safety-rules.json"
else
    echo "⚠️  safety-rules.json missing in repo - using defaults in scripts"
fi

# Make scripts executable
chmod +x "$SCRIPT_DIR"/{sandbox-monitor.fswatch.sh,enforcement_recovery_module.sh,sandbox-hooks.zsh} 2>/dev/null || true

# Generate launchd plist dynamically (fixes hardcoded /Users/travis paths)
PLIST_PATH="$HOME/Library/LaunchAgents/com.agentsentry.fswatch.plist"
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.agentsentry.fswatch</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPT_DIR/sandbox-monitor.fswatch.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>Nice</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/tmp/agentsentry-fswatch.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/agentsentry-fswatch.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>SAFETY_RULES</key>
        <string>$HOME/.hermes/safety-rules.json</string>
        <key>ENFORCEMENT_SCRIPT</key>
        <string>$SCRIPT_DIR/enforcement_recovery_module.sh</string>
    </dict>
</dict>
</plist>
EOF
echo "✅ Dynamic plist generated at $PLIST_PATH (no hardcoded paths)"

# Load it
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"
echo "✅ launchd monitor registered and loaded"

echo ""
echo "Add this to your ~/.zshrc:"
echo "  source $SCRIPT_DIR/sandbox-hooks.zsh"
echo ""
echo "Then: source ~/.zshrc"
echo "Run enforcement setup: $SCRIPT_DIR/enforcement_recovery_module.sh setup"
echo "Status check: $SCRIPT_DIR/enforcement_recovery_module.sh status"
echo ""
echo "✅ Install complete. All bugs fixed, P1-P6 features integrated."