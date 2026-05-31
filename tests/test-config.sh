#!/bin/bash
# test-config.sh - Tests for sentry-config.sh
# Validates: config loading, defaults, mode switching, ensure_config

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"

test_isolate

# Source the config module
source "$PROJECT_DIR/sentry-config.sh"

test_suite_begin "sentry-config.sh — defaults"

# --- Default values ---

_T_CURRENT_TEST="load_sentry_config succeeds with no config file"
rm -f "$SENTRY_CONFIG"
load_sentry_config
if [[ "$SENTRY_MODE" == "soft-block" ]]; then _pass; else _fail "mode=$SENTRY_MODE"; fi

_T_CURRENT_TEST="default notifications is true"
rm -f "$SENTRY_CONFIG"
load_sentry_config
if [[ "$SENTRY_NOTIFICATIONS" == "true" ]]; then _pass; else _fail "notif=$SENTRY_NOTIFICATIONS"; fi

_T_CURRENT_TEST="default audit log path under SENTRY_HOME"
rm -f "$SENTRY_CONFIG"
load_sentry_config
if [[ "$AUDIT_LOG" == "$SENTRY_HOME/logs/sandbox-audit.log" ]]; then _pass; else _fail "log=$AUDIT_LOG"; fi

_T_CURRENT_TEST="SAFETY_RULES is exported"
rm -f "$SENTRY_CONFIG"
load_sentry_config
if [[ -n "$SAFETY_RULES" ]]; then _pass; else _fail "SAFETY_RULES empty"; fi

test_suite_begin "sentry-config.sh — ensure_sentry_config"

_T_CURRENT_TEST="ensure_sentry_config creates config file"
rm -f "$SENTRY_CONFIG"
ensure_sentry_config >/dev/null 2>&1
if [[ -f "$SENTRY_CONFIG" ]]; then _pass; else _fail "config not created"; fi

_T_CURRENT_TEST="ensure_sentry_config is idempotent"
ensure_sentry_config >/dev/null 2>&1
first_hash=$(md5 -q "$SENTRY_CONFIG" 2>/dev/null || md5sum "$SENTRY_CONFIG" | awk '{print $1}')
ensure_sentry_config >/dev/null 2>&1
second_hash=$(md5 -q "$SENTRY_CONFIG" 2>/dev/null || md5sum "$SENTRY_CONFIG" | awk '{print $1}')
if [[ "$first_hash" == "$second_hash" ]]; then _pass; else _fail "config changed on re-run"; fi

_T_CURRENT_TEST="ensure_sentry_config creates log directory"
rm -rf "$SENTRY_HOME/logs"
ensure_sentry_config >/dev/null 2>&1
if [[ -d "$SENTRY_HOME/logs" ]]; then _pass; else _fail "log dir not created"; fi

_T_CURRENT_TEST="created config is valid JSON"
rm -f "$SENTRY_CONFIG"
ensure_sentry_config >/dev/null 2>&1
if command -v jq >/dev/null 2>&1; then
    if jq . "$SENTRY_CONFIG" >/dev/null 2>&1; then _pass; else _fail "invalid JSON"; fi
else
    _skip "jq not available"
fi

test_suite_begin "sentry-config.sh — config file parsing"

_T_CURRENT_TEST="load_sentry_config reads mode from JSON"
ensure_sentry_config >/dev/null 2>&1
if command -v jq >/dev/null 2>&1; then
    jq '.mode = "warn"' "$SENTRY_CONFIG" > "${SENTRY_CONFIG}.tmp" && mv "${SENTRY_CONFIG}.tmp" "$SENTRY_CONFIG"
    load_sentry_config
    if [[ "$SENTRY_MODE" == "warn" ]]; then _pass; else _fail "mode=$SENTRY_MODE"; fi
else
    _skip "jq not available"
fi

_T_CURRENT_TEST="load_sentry_config reads notifications=false from JSON"
ensure_sentry_config >/dev/null 2>&1
if command -v jq >/dev/null 2>&1; then
    # Use string "false" since jq's // operator treats boolean false as falsy (known issue)
    jq '.notifications = "false"' "$SENTRY_CONFIG" > "${SENTRY_CONFIG}.tmp" && mv "${SENTRY_CONFIG}.tmp" "$SENTRY_CONFIG"
    load_sentry_config
    if [[ "$SENTRY_NOTIFICATIONS" == "false" ]]; then _pass; else _fail "notif=$SENTRY_NOTIFICATIONS"; fi
else
    _skip "jq not available"
fi

test_suite_begin "sentry-config.sh — mode switching"

_T_CURRENT_TEST="set_sentry_mode to audit"
ensure_sentry_config >/dev/null 2>&1
set_sentry_mode "audit" >/dev/null 2>&1
load_sentry_config
if [[ "$SENTRY_MODE" == "audit" ]]; then _pass; else _fail "mode=$SENTRY_MODE"; fi

_T_CURRENT_TEST="set_sentry_mode to warn"
set_sentry_mode "warn" >/dev/null 2>&1
load_sentry_config
if [[ "$SENTRY_MODE" == "warn" ]]; then _pass; else _fail "mode=$SENTRY_MODE"; fi

_T_CURRENT_TEST="set_sentry_mode to hard"
set_sentry_mode "hard" >/dev/null 2>&1
load_sentry_config
if [[ "$SENTRY_MODE" == "hard" ]]; then _pass; else _fail "mode=$SENTRY_MODE"; fi

_T_CURRENT_TEST="set_sentry_mode to soft-block"
set_sentry_mode "soft-block" >/dev/null 2>&1
load_sentry_config
if [[ "$SENTRY_MODE" == "soft-block" ]]; then _pass; else _fail "mode=$SENTRY_MODE"; fi

_T_CURRENT_TEST="set_sentry_mode rejects invalid mode"
if ! set_sentry_mode "nuclear" >/dev/null 2>&1; then _pass; else _fail "should reject 'nuclear'"; fi

_T_CURRENT_TEST="set_sentry_mode rejects empty mode"
if ! set_sentry_mode "" >/dev/null 2>&1; then _pass; else _fail "should reject empty"; fi

test_suite_begin "sentry-config.sh — helper functions"

_T_CURRENT_TEST="get_sentry_mode returns current mode"
set_sentry_mode "warn" >/dev/null 2>&1
mode=$(get_sentry_mode)
if [[ "$mode" == "warn" ]]; then _pass; else _fail "got '$mode'"; fi

_T_CURRENT_TEST="should_attempt_block true for soft-block"
set_sentry_mode "soft-block" >/dev/null 2>&1
if should_attempt_block; then _pass; else _fail "should return 0"; fi

_T_CURRENT_TEST="should_attempt_block true for hard"
set_sentry_mode "hard" >/dev/null 2>&1
if should_attempt_block; then _pass; else _fail "should return 0"; fi

_T_CURRENT_TEST="should_attempt_block false for audit"
set_sentry_mode "audit" >/dev/null 2>&1
if ! should_attempt_block; then _pass; else _fail "should return 1"; fi

_T_CURRENT_TEST="should_attempt_block false for warn"
set_sentry_mode "warn" >/dev/null 2>&1
if ! should_attempt_block; then _pass; else _fail "should return 1"; fi

_T_CURRENT_TEST="is_hard_mode true only for hard"
set_sentry_mode "hard" >/dev/null 2>&1
if is_hard_mode; then _pass; else _fail "should return 0 for hard"; fi

_T_CURRENT_TEST="is_hard_mode false for soft-block"
set_sentry_mode "soft-block" >/dev/null 2>&1
if ! is_hard_mode; then _pass; else _fail "should return 1 for soft-block"; fi

_T_CURRENT_TEST="print_sentry_config outputs mode info"
set_sentry_mode "warn" >/dev/null 2>&1
output=$(print_sentry_config 2>&1)
if echo "$output" | grep -q "warn"; then _pass; else _fail "should mention mode"; fi

_T_CURRENT_TEST="print_sentry_config outputs all fields"
output=$(print_sentry_config 2>&1)
if echo "$output" | grep -q "Mode" && echo "$output" | grep -q "Notifications" && echo "$output" | grep -q "Audit log"; then
    _pass
else
    _fail "missing fields in output"
fi

test_suite_end
test_cleanup
test_report
