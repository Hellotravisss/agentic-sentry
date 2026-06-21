#!/bin/bash
# One-command installer for Agentic Sentry
# Features: dependency checks, dynamic plist, shell hook setup, uninstall, idempotent
#
# Usage:
#   ./install.sh              # Full install
#   ./install.sh --uninstall  # Full uninstall
#   ./install.sh --dry-run    # Show what would happen without doing anything
#   ./install.sh --help       # Show help

set -euo pipefail

# ============================================================
# Constants
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="Agentic-Sentry"
# Home resolution (keep in sync with sentry-config.sh)
if [[ -z "${SENTRY_HOME:-}" ]]; then
    if [[ -f "$HOME/.agentsentry/sentry-config.json" ]]; then
        SENTRY_HOME="$HOME/.agentsentry"
    elif [[ -f "$HOME/.hermes/sentry-config.json" ]]; then
        SENTRY_HOME="$HOME/.hermes"
    else
        SENTRY_HOME="$HOME/.agentsentry"
    fi
fi
SENTRY_LOG_DIR="$SENTRY_HOME/logs"
SENTRY_BIN_DIR="$HOME/.local/bin"
PLIST_NAME="com.agentsentry.fswatch"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
ZSHRC="$HOME/.zshrc"
BASHRC="$HOME/.bashrc"
HOOK_LINE="source $SCRIPT_DIR/sandbox-hooks.zsh"
HOOK_MARKER="# >>> Agentic Sentry >>>"
HOOK_MARKER_END="# <<< Agentic Sentry <<<"
SENTRYCTL_LINK="$SENTRY_BIN_DIR/sentryctl"
VERSION="0.1.8"

# ============================================================
# Colors & helpers
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; }
step()    { echo -e "\n${CYAN}${BOLD}==>${NC} ${BOLD}$*${NC}"; }

DRY_RUN=false
DO_UNINSTALL=false

# ============================================================
# Argument parsing
# ============================================================
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n)  DRY_RUN=true ;;
        --uninstall|-u) DO_UNINSTALL=true ;;
        --help|-h)
            echo "Agentic Sentry Installer v${VERSION}"
            echo ""
            echo "Usage:"
            echo "  ./install.sh              Install and configure Sentry"
            echo "  ./install.sh --uninstall  Remove all Sentry components"
            echo "  ./install.sh --dry-run    Show what would happen (no changes)"
            echo "  ./install.sh --help       Show this help"
            echo ""
            echo "What it installs:"
            echo "  - Safety rules to \$SENTRY_HOME/safety-rules.json (default ~/.agentsentry)"
            echo "  - Config to \$SENTRY_HOME/sentry-config.json"
            echo "  - Audit logs directory \$SENTRY_HOME/logs/"
            echo "  - Dynamic launchd plist (macOS background monitor)"
            echo "  - Shell hooks in ~/.zshrc (or ~/.bashrc)"
            echo "  - sentryctl symlink in ~/.local/bin/"
            exit 0
            ;;
        *)
            error "Unknown option: $arg (try --help)"
            exit 1
            ;;
    esac
done

if $DRY_RUN; then
    info "DRY RUN mode — no changes will be made"
fi

# ============================================================
# UNINSTALL
# ============================================================
do_uninstall() {
    step "Uninstalling Agentic Sentry"

    # 1. Unload and remove launchd plist
    if [[ -f "$PLIST_PATH" ]]; then
        info "Unloading launchd plist..."
        if ! $DRY_RUN; then
            launchctl unload "$PLIST_PATH" 2>/dev/null || true
            rm -f "$PLIST_PATH"
        fi
        success "launchd plist removed"
    else
        info "No launchd plist found (already removed)"
    fi

    # 2. Kill any running fswatch monitor
    if pgrep -f "sandbox-monitor.fswatch.sh" >/dev/null 2>&1; then
        info "Stopping running fswatch monitor..."
        if ! $DRY_RUN; then
            pkill -f "sandbox-monitor.fswatch.sh" 2>/dev/null || true
        fi
        success "fswatch monitor stopped"
    fi

    # 3. Remove sentryctl symlink
    if [[ -L "$SENTRYCTL_LINK" ]]; then
        if ! $DRY_RUN; then
            rm -f "$SENTRYCTL_LINK"
        fi
        success "Removed sentryctl symlink: $SENTRYCTL_LINK"
    fi

    # 4. Remove shell hooks from .zshrc / .bashrc
    for rc_file in "$ZSHRC" "$BASHRC"; do
        if [[ -f "$rc_file" ]] && grep -q "$HOOK_MARKER" "$rc_file" 2>/dev/null; then
            info "Removing hooks from $rc_file..."
            if ! $DRY_RUN; then
                local tmp
                tmp=$(mktemp)
                sed "/$HOOK_MARKER/,/$HOOK_MARKER_END/d" "$rc_file" > "$tmp" && mv "$tmp" "$rc_file"
            fi
            success "Hooks removed from $rc_file"
        fi
    done

    # 5. Remove installed config/rules (but preserve audit logs by default)
    if [[ -f "$SENTRY_HOME/safety-rules.json" ]]; then
        if ! $DRY_RUN; then
            rm -f "$SENTRY_HOME/safety-rules.json"
        fi
        success "Removed safety-rules.json"
    fi

    if [[ -f "$SENTRY_HOME/sentry-config.json" ]]; then
        if ! $DRY_RUN; then
            rm -f "$SENTRY_HOME/sentry-config.json"
        fi
        success "Removed sentry-config.json"
    fi

    echo ""
    info "Audit logs preserved at: $SENTRY_LOG_DIR/"
    info "To remove logs too: rm -rf $SENTRY_LOG_DIR"
    echo ""
    success "Uninstall complete."
    exit 0
}

if $DO_UNINSTALL; then
    do_uninstall
fi

# ============================================================
# INSTALL
# ============================================================

echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║   Agentic Sentry — Installer      ║"
echo "  ║   v${VERSION}                                ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"

# ============================================================
# Step 1: OS detection
# ============================================================
step "Checking system requirements"

OS="$(uname -s)"
ARCH="$(uname -m)"
IS_MACOS=false

case "$OS" in
    Darwin)
        IS_MACOS=true
        success "macOS detected ($ARCH)"
        ;;
    Linux)
        warn "Linux detected — launchd plist will be skipped (use systemd instead)"
        ;;
    *)
        error "Unsupported OS: $OS"
        exit 1
        ;;
esac

# ============================================================
# Step 2: Dependency checks
# ============================================================
step "Checking dependencies"

MISSING_COUNT=0
MISSING_DEPS=""
OPTIONAL_MISSING=()

# Required: bash 4+ (for mapfile)
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
if [[ "$BASH_MAJOR" -lt 4 ]]; then
    warn "Bash $BASH_MAJOR detected — some features require bash 4+ (brew install bash)"
    OPTIONAL_MISSING+=("bash>=4")
else
    success "Bash $BASH_MAJOR"
fi

# Required: fswatch (critical for background monitor)
if command -v fswatch >/dev/null 2>&1; then
    success "fswatch $(fswatch --version 2>/dev/null | head -1 || echo 'installed')"
else
    MISSING_DEPS="$MISSING_DEPS fswatch"
    MISSING_COUNT=$((MISSING_COUNT + 1))
    warn "fswatch not found — background monitor won't work"
    info "Install with: brew install fswatch"
fi

# Required: jq (used everywhere for JSON parsing)
if command -v jq >/dev/null 2>&1; then
    success "jq $(jq --version 2>/dev/null)"
else
    MISSING_DEPS="$MISSING_DEPS jq"
    MISSING_COUNT=$((MISSING_COUNT + 1))
    warn "jq not found — many features require JSON parsing"
    info "Install with: brew install jq"
fi

# Optional: pgrep (for process management)
if command -v pgrep >/dev/null 2>&1; then
    success "pgrep available"
else
    OPTIONAL_MISSING+=("pgrep")
fi

# Report
if [[ "$MISSING_COUNT" -gt 0 ]]; then
    echo ""
    warn "Missing dependencies:$MISSING_DEPS"
    if $DRY_RUN; then
        info "(dry-run) Would continue with limited functionality"
    else
        echo ""
        read -rp "Continue with limited functionality? [Y/n] " answer
        if [[ "$answer" =~ ^[nN] ]]; then
            error "Aborting. Install dependencies first."
            exit 1
        fi
    fi
fi

# ============================================================
# Step 3: Create directory structure
# ============================================================
step "Creating directory structure"

DIRS_TO_CREATE=(
    "$SENTRY_HOME"
    "$SENTRY_LOG_DIR"
)

for dir in "${DIRS_TO_CREATE[@]}"; do
    if [[ ! -d "$dir" ]]; then
        if ! $DRY_RUN; then
            mkdir -p "$dir"
        fi
        success "Created: $dir"
    else
        info "Exists: $dir"
    fi
done

# ============================================================
# Step 4: Install safety rules
# ============================================================
step "Installing safety rules"

if [[ -f "$SCRIPT_DIR/safety-rules.json" ]]; then
    if ! $DRY_RUN; then
        cp "$SCRIPT_DIR/safety-rules.json" "$SENTRY_HOME/safety-rules.json"
    fi
    success "Rules installed to $SENTRY_HOME/safety-rules.json"
else
    warn "safety-rules.json not found in repo — scripts will use built-in defaults"
fi

# ============================================================
# Step 5: Ensure config exists
# ============================================================
step "Setting up configuration"

if [[ ! -f "$SENTRY_HOME/sentry-config.json" ]]; then
    if ! $DRY_RUN; then
        cat > "$SENTRY_HOME/sentry-config.json" << CFGEOF
{
  "version": "2.0",
  "mode": "soft-block",
  "notifications": true,
  "audit_log": "$SENTRY_LOG_DIR/sandbox-audit.log",
  "description": "Operational settings for Agentic Sentry. Use 'sentryctl mode <name>' to change."
}
CFGEOF
    fi
    success "Default config created at $SENTRY_HOME/sentry-config.json"
else
    success "Config already exists at $SENTRY_HOME/sentry-config.json"
fi

# ============================================================
# Step 6: Make scripts executable
# ============================================================
step "Setting permissions"

EXECUTABLES=(
    "sandbox-monitor.fswatch.sh"
    "enforcement_recovery_module.sh"
    "sandbox-hooks.zsh"
    "sentryctl"
    "sentry-status.sh"
    "sandbox-egress-watcher.sh"
)

for script in "${EXECUTABLES[@]}"; do
    if [[ -f "$SCRIPT_DIR/$script" ]]; then
        if ! $DRY_RUN; then
            chmod +x "$SCRIPT_DIR/$script"
        fi
        success "chmod +x $script"
    fi
done

# ============================================================
# Step 7: Install sentryctl to PATH
# ============================================================
step "Installing sentryctl command"

if ! $DRY_RUN; then
    mkdir -p "$SENTRY_BIN_DIR"
fi

if [[ -L "$SENTRYCTL_LINK" ]] || [[ -f "$SENTRYCTL_LINK" ]]; then
    if ! $DRY_RUN; then
        rm -f "$SENTRYCTL_LINK"
    fi
fi

if ! $DRY_RUN; then
    ln -s "$SCRIPT_DIR/sentryctl" "$SENTRYCTL_LINK"
fi
success "Symlinked: $SENTRYCTL_LINK -> $SCRIPT_DIR/sentryctl"

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$SENTRY_BIN_DIR:"* ]]; then
    warn "$SENTRY_BIN_DIR is not in your PATH"
    info "Add this to your shell profile:"
    echo "  export PATH=\"$SENTRY_BIN_DIR:\$PATH\""
fi

# ============================================================
# Step 8: Shell hooks (auto-configure .zshrc / .bashrc)
# ============================================================
step "Configuring shell hooks"

install_hooks_in_rc() {
    local rc_file="$1"
    local hook_cmd="$2"

    if [[ ! -f "$rc_file" ]]; then
        # Create it if parent shell uses it
        if ! $DRY_RUN; then
            touch "$rc_file"
        fi
        info "Created $rc_file"
    fi

    if grep -q "$HOOK_MARKER" "$rc_file" 2>/dev/null; then
        success "Hooks already present in $rc_file"
        return
    fi

    local hook_block
    hook_block=$(cat << HOOKEOF
$HOOK_MARKER
# Agentic Sentry — shell command interception
export PATH="$SENTRY_BIN_DIR:\$PATH"
$hook_cmd
$HOOK_MARKER_END
HOOKEOF
)

    if ! $DRY_RUN; then
        echo "" >> "$rc_file"
        echo "$hook_block" >> "$rc_file"
    fi
    success "Added hooks to $rc_file"
}

# Detect which shell config to update
CURRENT_SHELL="$(basename "${SHELL:-/bin/zsh}")"

case "$CURRENT_SHELL" in
    zsh)
        install_hooks_in_rc "$ZSHRC" "$HOOK_LINE"
        ;;
    bash)
        # Bash doesn't use .zsh hooks; create a source line for the hooks file
        install_hooks_in_rc "$BASHRC" "# Note: sandbox-hooks.zsh is zsh-specific. For bash, enforcement relies on launchd + fswatch."
        ;;
    *)
        warn "Unknown shell: $CURRENT_SHELL — skipping auto-hook setup"
        info "Manually add to your shell profile: $HOOK_LINE"
        ;;
esac

# ============================================================
# Step 9: Generate and load launchd plist (macOS only)
# ============================================================
step "Setting up background monitor (launchd)"

if $IS_MACOS; then
    if ! $DRY_RUN; then
        mkdir -p "$(dirname "$PLIST_PATH")"
    fi

    if ! $DRY_RUN; then
        cat > "$PLIST_PATH" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
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
    <string>${SENTRY_LOG_DIR}/fswatch.log</string>
    <key>StandardErrorPath</key>
    <string>${SENTRY_LOG_DIR}/fswatch.err</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>SAFETY_RULES</key>
        <string>$SENTRY_HOME/safety-rules.json</string>
        <key>ENFORCEMENT_SCRIPT</key>
        <string>$SCRIPT_DIR/enforcement_recovery_module.sh</string>
        <key>AUDIT_LOG</key>
        <string>${SENTRY_LOG_DIR}/sandbox-audit.log</string>
    </dict>
</dict>
</plist>
PLISTEOF
    fi
    success "Dynamic plist generated: $PLIST_PATH"

    # Unload old, load new
    if ! $DRY_RUN; then
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        if command -v fswatch >/dev/null 2>&1; then
            launchctl load "$PLIST_PATH" 2>/dev/null && \
                success "launchd monitor loaded" || \
                warn "launchd load failed — you may need to run: launchctl load $PLIST_PATH"
        else
            warn "fswatch not installed — plist created but not loaded"
            info "Install fswatch then run: launchctl load $PLIST_PATH"
        fi
    fi
else
    info "Skipping launchd (not macOS). For Linux, consider a systemd unit."
fi

# ============================================================
# Step 10: Initialize audit log
# ============================================================
step "Initializing audit log"

AUDIT_LOG_FILE="$SENTRY_LOG_DIR/sandbox-audit.log"
if [[ ! -f "$AUDIT_LOG_FILE" ]]; then
    if ! $DRY_RUN; then
        touch "$AUDIT_LOG_FILE"
    fi
    success "Created audit log: $AUDIT_LOG_FILE"
else
    lines=$(wc -l < "$AUDIT_LOG_FILE" 2>/dev/null | tr -d ' ' || echo 0)
    success "Audit log exists ($lines events)"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo -e "${BOLD}"
echo "  ╔═══════════════════════════════════════════╗"
echo "  ║         Installation Complete!            ║"
echo "  ╚═══════════════════════════════════════════╝"
echo -e "${NC}"

echo "  Installed components:"
echo "    • Safety rules:    $SENTRY_HOME/safety-rules.json"
echo "    • Config:          $SENTRY_HOME/sentry-config.json"
echo "    • Audit log:       $AUDIT_LOG_FILE"
echo "    • sentryctl:       $SENTRYCTL_LINK"
if $IS_MACOS; then
echo "    • launchd plist:   $PLIST_PATH"
fi
echo "    • Shell hooks:     Added to ${CURRENT_SHELL}rc"
echo ""
echo "  Quick start:"
echo "    sentryctl                   # Dashboard"
echo "    sentryctl status            # Full status"
echo "    sentryctl last              # Recent events"
echo "    sentryctl mode              # Show/change protection mode"
echo "    sentryctl test 'rm -rf /'   # Test a command"
echo ""
echo "  Reload your shell:"
echo "    source ~/.${CURRENT_SHELL}rc"
echo ""

if [[ "$MISSING_COUNT" -gt 0 ]]; then
    warn "Some dependencies are missing:$MISSING_DEPS"
    info "Install them for full functionality:"
    for dep in $MISSING_DEPS; do
        echo "      brew install $dep"
    done
    echo ""
fi

echo "  Uninstall: $SCRIPT_DIR/install.sh --uninstall"
echo ""
