#!/bin/bash
# test-home-migration.sh - Tests for Sentry home resolution and migrate-home
# Uses a fake $HOME so the user's real directories are never touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$SCRIPT_DIR/lib/test-helpers.sh"

test_isolate

FAKE_HOME="$_T_ISOLATION_DIR/fakehome"
mkdir -p "$FAKE_HOME"

# Resolve SENTRY_HOME as sentry-config.sh would, under the fake HOME with
# no inherited Sentry env vars.
resolve_home() {
    env -i HOME="$FAKE_HOME" bash -c "source '$PROJECT_DIR/sentry-config.sh'; echo \"\$SENTRY_HOME\""
}

test_suite_begin "home resolution — precedence"

_T_CURRENT_TEST="fresh system defaults to ~/.agentsentry"
got=$(resolve_home)
if [[ "$got" == "$FAKE_HOME/.agentsentry" ]]; then
    _pass
else
    _fail "expected $FAKE_HOME/.agentsentry, got $got"
fi

_T_CURRENT_TEST="legacy ~/.hermes install keeps working"
mkdir -p "$FAKE_HOME/.hermes"
echo '{"mode":"warn"}' > "$FAKE_HOME/.hermes/sentry-config.json"
got=$(resolve_home)
if [[ "$got" == "$FAKE_HOME/.hermes" ]]; then
    _pass
else
    _fail "expected legacy $FAKE_HOME/.hermes, got $got"
fi

_T_CURRENT_TEST="~/.agentsentry wins over legacy when both exist"
mkdir -p "$FAKE_HOME/.agentsentry"
echo '{"mode":"warn"}' > "$FAKE_HOME/.agentsentry/sentry-config.json"
got=$(resolve_home)
if [[ "$got" == "$FAKE_HOME/.agentsentry" ]]; then
    _pass
else
    _fail "expected $FAKE_HOME/.agentsentry, got $got"
fi

_T_CURRENT_TEST="SENTRY_HOME env override wins over everything"
got=$(env -i HOME="$FAKE_HOME" SENTRY_HOME="/custom/path" bash -c "source '$PROJECT_DIR/sentry-config.sh'; echo \"\$SENTRY_HOME\"")
if [[ "$got" == "/custom/path" ]]; then
    _pass
else
    _fail "expected /custom/path, got $got"
fi

_T_CURRENT_TEST="logger log dir follows the same resolution"
rm -rf "$FAKE_HOME/.agentsentry"
got=$(env -i HOME="$FAKE_HOME" bash -c "source '$PROJECT_DIR/sentry-logger.sh' 2>/dev/null; echo \"\$SENTRY_LOG_DIR\"")
if [[ "$got" == "$FAKE_HOME/.hermes/logs" ]]; then
    _pass
else
    _fail "expected legacy logs dir, got $got"
fi

test_suite_begin "migrate-home — moves only Sentry-owned files"

# Build a legacy home that also contains Hermes Agent's own files
rm -rf "$FAKE_HOME/.hermes" "$FAKE_HOME/.agentsentry"
mkdir -p "$FAKE_HOME/.hermes/logs" "$FAKE_HOME/.hermes/sessions"
cat > "$FAKE_HOME/.hermes/sentry-config.json" <<'EOF'
{"version":"2.0","mode":"warn","notifications":true,"audit_log":"OLD"}
EOF
echo '{}' > "$FAKE_HOME/.hermes/safety-rules.json"
echo 'sentry log line' > "$FAKE_HOME/.hermes/logs/sandbox-audit.log"
echo 'hermes own config' > "$FAKE_HOME/.hermes/config.yaml"
echo 'hermes gateway log' > "$FAKE_HOME/.hermes/logs/gateway.log"

migrate_out=$(env HOME="$FAKE_HOME" SENTRY_HOME="" bash "$PROJECT_DIR/sentryctl" migrate-home 2>&1) || true

_T_CURRENT_TEST="sentry files moved to ~/.agentsentry"
if [[ -f "$FAKE_HOME/.agentsentry/sentry-config.json" \
   && -f "$FAKE_HOME/.agentsentry/safety-rules.json" \
   && -f "$FAKE_HOME/.agentsentry/logs/sandbox-audit.log" ]]; then
    _pass
else
    _fail "expected migrated files (output: $migrate_out)"
fi

_T_CURRENT_TEST="Hermes Agent's own files untouched"
if [[ -f "$FAKE_HOME/.hermes/config.yaml" && -f "$FAKE_HOME/.hermes/logs/gateway.log" \
   && -d "$FAKE_HOME/.hermes/sessions" ]]; then
    _pass
else
    _fail "non-Sentry files must stay in ~/.hermes"
fi

_T_CURRENT_TEST="legacy sentry files removed from ~/.hermes"
if [[ ! -f "$FAKE_HOME/.hermes/sentry-config.json" && ! -f "$FAKE_HOME/.hermes/logs/sandbox-audit.log" ]]; then
    _pass
else
    _fail "sentry files should be gone from legacy home"
fi

_T_CURRENT_TEST="audit_log path rewritten in migrated config"
if command -v jq >/dev/null 2>&1; then
    got=$(jq -r '.audit_log' "$FAKE_HOME/.agentsentry/sentry-config.json")
    if [[ "$got" == "$FAKE_HOME/.agentsentry/logs/sandbox-audit.log" ]]; then
        _pass
    else
        _fail "audit_log not rewritten (got: $got)"
    fi
else
    _skip "jq not available"
fi

_T_CURRENT_TEST="resolution now picks ~/.agentsentry"
got=$(resolve_home)
if [[ "$got" == "$FAKE_HOME/.agentsentry" ]]; then
    _pass
else
    _fail "expected new home after migration, got $got"
fi

_T_CURRENT_TEST="second migrate-home run is a clean no-op"
if env HOME="$FAKE_HOME" SENTRY_HOME="" bash "$PROJECT_DIR/sentryctl" migrate-home >/dev/null 2>&1; then
    _pass
else
    _fail "re-running migrate-home should exit 0"
fi

test_suite_end
test_cleanup
test_report
