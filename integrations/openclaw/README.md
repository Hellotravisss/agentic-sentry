# OpenClaw Plugin: sentry-guard (experimental)

Bridges Agentic Sentry into OpenClaw's typed plugin hook system. The
plugin registers a `before_tool_call` handler that screens exec/shell commands
with `sentryctl check` before they run on the host.

| Sentry mode | OpenClaw behavior |
|---|---|
| safe command | invisible — normal policy applies |
| `audit` | command runs; detection logged to Sentry's audit log |
| `warn` / `dry-run` | operator approval prompt with Sentry's reason (timeout = deny) |
| `soft-block` / `hard` | blocked (`block: true`, terminal) |

Every detection lands in Sentry's audit log with component `openclaw-plugin`,
so `sentryctl logs` shows OpenClaw activity alongside Claude Code, Codex, and
shell events.

## Install

1. Copy (or symlink) the `sentry-guard/` directory into one of OpenClaw's
   plugin discovery locations, or register it in your OpenClaw config per the
   [plugin docs](https://docs.openclaw.ai/plugins).
2. Tell the plugin where Sentry lives if not at `~/agentic-sentry`:

   ```bash
   export SENTRY_REPO=/path/to/agentic-sentry
   ```

3. Enable the plugin and restart the OpenClaw gateway.

## Status: experimental

Written against the OpenClaw Plugin SDK documentation (`before_tool_call`
contract with `block` / `requireApproval` results). OpenClaw evolves quickly —
if the SDK shape has drifted in your version, the adapter is ~100 lines and
the fix is usually renaming a field. Issues and PRs welcome.

Fail-safe behavior: if `sentryctl` is missing or errors, the plugin returns
nothing, leaving OpenClaw's own exec-approval policy fully in charge. It never
auto-approves a command.
