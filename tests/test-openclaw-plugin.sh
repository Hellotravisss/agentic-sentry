#!/bin/bash
# test-openclaw-plugin.sh - Sanity checks for the OpenClaw plugin package
# (No OpenClaw runtime in CI; validates structure and contract markers.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"

test_isolate

PLUGIN_DIR="$PROJECT_DIR/integrations/openclaw/sentry-guard"

test_suite_begin "openclaw plugin — package sanity"

_T_CURRENT_TEST="manifest is valid JSON with required fields"
if jq -e '.id == "sentry-guard" and (.entry | length > 0) and (.description | length > 0)' \
    "$PLUGIN_DIR/openclaw.plugin.json" >/dev/null 2>&1; then
    _pass
else
    _fail "openclaw.plugin.json invalid or missing fields"
fi

_T_CURRENT_TEST="entry file exists and registers before_tool_call"
entry=$(jq -r '.entry' "$PLUGIN_DIR/openclaw.plugin.json")
if [[ -f "$PLUGIN_DIR/$entry" ]] && grep -q '"before_tool_call"' "$PLUGIN_DIR/$entry"; then
    _pass
else
    _fail "entry file missing or does not register before_tool_call"
fi

_T_CURRENT_TEST="plugin uses block and requireApproval contract"
if grep -q 'block: true' "$PLUGIN_DIR/index.ts" && grep -q 'requireApproval' "$PLUGIN_DIR/index.ts"; then
    _pass
else
    _fail "decision contract markers missing"
fi

_T_CURRENT_TEST="plugin calls sentryctl check with --json"
if grep -q '"check"' "$PLUGIN_DIR/index.ts" && grep -q '"--json"' "$PLUGIN_DIR/index.ts"; then
    _pass
else
    _fail "plugin must delegate to sentryctl check --json"
fi

_T_CURRENT_TEST="plugin never auto-approves"
if grep -qE 'approve.*true|allow.*true' "$PLUGIN_DIR/index.ts"; then
    _fail "plugin must not contain auto-approve paths"
else
    _pass
fi

test_suite_end
test_cleanup
test_report
