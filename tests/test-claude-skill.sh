#!/bin/bash
# test-claude-skill.sh - Tests for the sentry-audit skill installer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"

test_isolate

INSTALLER="$PROJECT_DIR/integrations/claude-code/install-claude-skill.sh"
DEST_ROOT="$_T_ISOLATION_DIR/skills"

test_suite_begin "claude-code skill — installer"

_T_CURRENT_TEST="install creates SKILL.md in destination"
bash "$INSTALLER" --dest "$DEST_ROOT" >/dev/null 2>&1
if [[ -f "$DEST_ROOT/sentry-audit/SKILL.md" ]]; then
    _pass
else
    _fail "SKILL.md not created"
fi

_T_CURRENT_TEST="repo path placeholder is substituted"
if grep -q "__SENTRY_REPO__" "$DEST_ROOT/sentry-audit/SKILL.md"; then
    _fail "placeholder __SENTRY_REPO__ left unsubstituted"
elif grep -q "$PROJECT_DIR/sentryctl" "$DEST_ROOT/sentry-audit/SKILL.md"; then
    _pass
else
    _fail "absolute sentryctl path missing from installed skill"
fi

_T_CURRENT_TEST="frontmatter has name and description"
head -5 "$DEST_ROOT/sentry-audit/SKILL.md" | grep -q "^name: sentry-audit" \
    && grep -q "^description: " "$DEST_ROOT/sentry-audit/SKILL.md" \
    && _pass || _fail "frontmatter incomplete"

_T_CURRENT_TEST="reinstall is idempotent (single file, refreshed)"
bash "$INSTALLER" --dest "$DEST_ROOT" >/dev/null 2>&1
count=$(find "$DEST_ROOT/sentry-audit" -type f | wc -l | tr -d ' ')
if [[ "$count" == "1" ]]; then
    _pass
else
    _fail "expected 1 file after reinstall, found $count"
fi

_T_CURRENT_TEST="source template still contains the placeholder"
if grep -q "__SENTRY_REPO__" "$PROJECT_DIR/integrations/claude-code/skills/sentry-audit/SKILL.md"; then
    _pass
else
    _fail "source SKILL.md must keep __SENTRY_REPO__ placeholder"
fi

_T_CURRENT_TEST="uninstall removes the skill directory"
bash "$INSTALLER" --dest "$DEST_ROOT" --uninstall >/dev/null 2>&1
if [[ ! -d "$DEST_ROOT/sentry-audit" ]]; then
    _pass
else
    _fail "skill directory still present after uninstall"
fi

_T_CURRENT_TEST="uninstall on missing skill exits cleanly"
if bash "$INSTALLER" --dest "$DEST_ROOT" --uninstall >/dev/null 2>&1; then
    _pass
else
    _fail "uninstall should exit 0 when nothing installed"
fi

test_suite_end
test_cleanup
test_report
