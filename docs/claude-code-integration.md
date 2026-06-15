# Claude Code Integration

Agentic Sentry can run inside Claude Code's official hook system, evaluating
every Bash command the agent attempts **before** it executes — using the same detection
rules as the zsh hook, but at the tool layer where it cannot be bypassed by switching
shells.

This is the recommended way to use Sentry with Claude Code. The zsh `preexec` hook
still covers commands you (or other tools) type into a terminal.

## How it works

Claude Code invokes [`integrations/claude-code/sentry-pretooluse-hook.sh`](../integrations/claude-code/sentry-pretooluse-hook.sh)
as a `PreToolUse` hook for the `Bash` tool. The hook:

1. Reads the proposed command from the hook's JSON input.
2. Evaluates it with Sentry's real `is_dangerous()` engine (rules from
   `safety-rules.json`, same allowed-dirs and bypass detection as the shell hook).
3. Maps your configured Sentry mode to a Claude Code permission decision:

| Sentry mode | Decision | Effect in Claude Code |
|---|---|---|
| safe command (any mode) | *defer* | Invisible — normal permission flow applies |
| `audit` | *defer* + log | Command proceeds normally; detection is logged |
| `warn` | `ask` | Permission prompt appears with Sentry's reason |
| `dry-run` | `ask` | Prompt labeled as dry run, with the would-block reason |
| `soft-block` | `deny` | Command blocked; Claude sees the reason and adapts |
| `hard` | `deny` | Same as soft-block — **no physical enforcement from hooks** |

Every detection is written to the audit log with component `claude-hook`, so
`sentryctl logs`, `stats`, and `watch` show agent activity alongside shell activity.

## Install

```bash
cd agentic-sentry
./integrations/claude-code/install-claude-hook.sh
```

This registers the hook in `~/.claude/settings.json` (idempotent, with a timestamped
backup). Use `--project` to install into the current project's `.claude/settings.json`
instead, or `--settings PATH` for a custom location.

Claude Code reads hook config at session start — restart any running session.

Try it: ask Claude Code to run `sudo whoami`. In `soft-block` mode the call is denied
with a reason; in `warn` mode you get a permission prompt.

## Uninstall

```bash
./integrations/claude-code/install-claude-hook.sh --uninstall
```

## Companion skill: sentry-audit

The hook blocks; the skill explains. `sentry-audit` teaches Claude how to read
Sentry's audit records back to you — ask things like *"what has the agent tried to do
recently?"* or *"why was that command blocked?"* and Claude will use `sentryctl
stats`/`violations`/`logs`, group repeated attempts (retry-loop detection, threat
model T9), and translate rule jargon into plain language. It is read-only by design:
the skill never changes modes, rules, or hooks unless you explicitly ask.

```bash
./integrations/claude-code/install-claude-skill.sh             # install
./integrations/claude-code/install-claude-skill.sh --uninstall # remove
```

Installed to `~/.claude/skills/sentry-audit/` with the repo path baked in, so it works
from any project. Like hooks, skills load at session start.

## Design notes

- **Fail-safe means defer, not approve.** On any internal error (missing `jq`/`zsh`,
  malformed input), the hook exits 0 with no output, which leaves Claude Code's own
  permission prompts fully in charge. The hook never auto-approves anything.
- **No enforcement from hooks.** In `hard` mode the hook only denies. Cutting network
  or freezing processes from inside an agent's tool call would be destructive in the
  wrong context; physical enforcement stays with the shell-side monitors.
- **Injection-safe.** The agent-controlled command string is passed to the detection
  engine via environment variables, never interpolated into shell code. Covered by
  tests (`tests/test-claude-hook.sh`).
- **Why this beats the zsh hook for agents:** `preexec` only sees commands typed into
  an interactive zsh. Claude Code's Bash tool spawns its own shell, so the zsh hook
  never fires for agent commands — the PreToolUse hook is the layer that actually
  intercepts them. The threat-model entries T6/T8 (orphaned processes, stale authority)
  remain out of scope here; see [threat-model.md](threat-model.md).
