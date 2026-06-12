---
name: sentry-audit
description: Review and explain AI-agent activity recorded by Agentic Sandbox Sentry — blocked commands, permission denials, warnings, and suspicious patterns. Use when the user asks what the agent did or tried to do, why a Bash command was denied or prompted with a "Sentry" reason, to audit/review agent or shell activity, or to investigate Sentry logs, violations, or statistics.
---

# Sentry Audit

Agentic Sandbox Sentry is a runtime safety guard installed on this machine. It screens
shell commands (via zsh hooks) and Claude Code Bash tool calls (via a PreToolUse hook),
logging every detection as structured JSON. This skill is for reading those records
back to the user and explaining them.

## Locations

- Sentry repo: `__SENTRY_REPO__`
- CLI: `__SENTRY_REPO__/sentryctl`
- Sentry home: `~/.agentsentry` (legacy installs: `~/.hermes`) — call it `$SH` below
- Audit log (JSON lines): `$SH/logs/sandbox-audit.log` (rotated files alongside)
- Config: `$SH/sentry-config.json` (field `mode`: audit | warn | dry-run | soft-block | hard)

If the repo path above does not exist, search for `sentryctl` before giving up.

## Core commands

```bash
__SENTRY_REPO__/sentryctl stats              # activity summary, top violation reasons
__SENTRY_REPO__/sentryctl violations         # detailed violation report
__SENTRY_REPO__/sentryctl last               # 8 most recent events
__SENTRY_REPO__/sentryctl logs --blocked --since 24h   # filtered log view
__SENTRY_REPO__/sentryctl explain 1          # full details of the most recent event
__SENTRY_REPO__/sentryctl mode               # current protection mode
```

For agent-specific activity (Claude Code tool calls only), filter the raw log by
component:

```bash
SH=$([ -f ~/.agentsentry/sentry-config.json ] && echo ~/.agentsentry || echo ~/.hermes)
grep '"component":"claude-hook"' "$SH/logs/sandbox-audit.log" | tail -50
```

Each line is JSON with `ts`, `decision`, `reason`, `cmd`, `cwd`, `mode`. Decisions:

| Decision | Meaning |
|---|---|
| `CLAUDE_HOOK_DENY` | Agent Bash command was blocked before execution |
| `CLAUDE_HOOK_ASK` | User was prompted and made the call |
| `CLAUDE_HOOK_AUDIT` | Detected but allowed (audit mode) |
| `SOFT_BLOCKED` / `HARD_ENFORCEMENT` | Blocked at the zsh shell layer |
| `DETECTED` / `DRY_RUN` | Logged by the shell hook without blocking |
| `RATE_REPEAT` | Same command repeated past the threshold (default 8x/10min) — possible agent retry loop burning budget; never blocked |

## How to report

1. Lead with the headline: how many detections in the period, how many denied,
   the single most concerning item if any.
2. Group repeated identical commands instead of listing them one by one — and call
   out repetition explicitly: the same command denied many times in a short window
   usually means an agent retry loop burning budget (threat model T9). Count with:

   ```bash
   grep '"component":"claude-hook"' "$SH/logs/sandbox-audit.log" \
     | jq -r '.cmd' | sort | uniq -c | sort -rn | head
   ```

3. Translate reasons into plain language ("tried to read your SSH private key"),
   not rule jargon.
4. Distinguish "the guard working as intended" from "something needs attention".
   A handful of denied `sudo` attempts during normal work is the former.

## Remediation the user may ask about

- False positives on a legitimate project directory:
  `sentryctl allow-dir <path>`
- Too strict / too lax: `sentryctl mode <audit|warn|dry-run|soft-block|hard>`
- A Bash call denied in Claude Code shows reason "Sentry (<mode> mode): …" — that is
  the PreToolUse hook; uninstall with
  `__SENTRY_REPO__/integrations/claude-code/install-claude-hook.sh --uninstall`
- Full docs: `__SENTRY_REPO__/docs/` (modes, recovery, threat model)

Never modify Sentry's rules, mode, or hooks on the user's behalf without being asked —
this skill is for reading and explaining, not reconfiguring.
