#!/bin/bash
# install-claude-skill.sh - Install the sentry-audit skill for Claude Code
#
# Usage:
#   ./install-claude-skill.sh                  # install to ~/.claude/skills/sentry-audit
#   ./install-claude-skill.sh --uninstall      # remove it
#   ./install-claude-skill.sh --dest DIR       # custom skills directory
#
# Copies the skill and substitutes the absolute repo path so the skill
# works from any project. Idempotent: re-running refreshes the copy.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$SCRIPT_DIR/skills/sentry-audit/SKILL.md"

DEST_ROOT="$HOME/.claude/skills"
ACTION="install"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest)      DEST_ROOT="$2"; shift 2 ;;
        --uninstall) ACTION="uninstall"; shift ;;
        -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -10; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
done

DEST="$DEST_ROOT/sentry-audit"

if [[ "$ACTION" == "uninstall" ]]; then
    if [[ -d "$DEST" ]]; then
        rm -rf "$DEST"
        echo "✅ Removed skill: $DEST"
    else
        echo "Skill not installed at $DEST — nothing to do."
    fi
    exit 0
fi

[[ -f "$SRC" ]] || { echo "Error: skill source not found at $SRC"; exit 1; }

mkdir -p "$DEST"
sed "s|__SENTRY_REPO__|$PROJECT_DIR|g" "$SRC" > "$DEST/SKILL.md"

echo "✅ sentry-audit skill installed: $DEST/SKILL.md"
echo "   Repo path baked in: $PROJECT_DIR"
echo ""
echo "Claude Code picks up skills at session start — restart any running session."
echo "Try it: ask Claude 'what has the agent tried to do recently?' or"
echo "'why was that command blocked by Sentry?'"
echo "Uninstall with: $0 --uninstall"
