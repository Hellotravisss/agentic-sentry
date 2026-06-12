# Agent Platform Integrations

Sentry's detection engine is agent-agnostic. One command is the integration
point for every platform:

```bash
sentryctl check --json [--log --component NAME] [--cwd DIR] -- "<command>"
# {"verdict":"dangerous","reason":"BLOCKED: sudo command detected","mode":"warn"}
# exit codes: 0 = safe, 1 = dangerous, 2 = cannot evaluate
```

Each adapter below is a thin translation layer between a platform's hook
protocol and that call. All adapters share two invariants: they **never
auto-approve** anything, and on any internal error they defer to the
platform's own permission system (fail-safe ≠ fail-open).

## Status matrix

| Platform | Mechanism | Status | Install |
|---|---|---|---|
| Claude Code | `PreToolUse` hook + `sentry-audit` skill | ✅ stable, tested | [claude-code-integration.md](claude-code-integration.md) |
| OpenAI Codex CLI | `PermissionRequest` hook | ✅ tested against documented protocol | `integrations/codex/install-codex-hook.sh` |
| OpenClaw | `before_tool_call` plugin (TypeScript) | 🧪 experimental | [integrations/openclaw/README.md](../integrations/openclaw/README.md) |
| Hermes Agent | no external policy hook today | 📋 cooperation guide below | — |
| Any zsh terminal | `preexec` hook | ✅ stable | `install.sh` |

## Decision mapping by platform

| Sentry mode | Claude Code | Codex | OpenClaw |
|---|---|---|---|
| safe command | invisible | invisible | invisible |
| `audit` | defer + log | defer + log | run + log |
| `warn` | **ask** with reason | defer + log¹ | **approval prompt** |
| `dry-run` | **ask** (labeled) | defer + log¹ | **approval prompt** |
| `soft-block` | **deny** | **deny** | **block** |
| `hard` | **deny**² | **deny**² | **block**² |

¹ Codex only fires `PermissionRequest` when it is already about to prompt the
user — its own prompt is the "ask", so the adapter just adds the audit trail.
Commands auto-approved inside Codex's sandbox never reach the hook; the
sandbox is the guard there.

² No adapter triggers physical enforcement (network cut / process freeze).
That stays with the shell-side monitors by design.

## Codex CLI

```bash
./integrations/codex/install-codex-hook.sh
```

Registers the hook in `~/.codex/hooks.json` (idempotent, backed up). **Codex
requires hook trust**: open Codex and run `/hooks` to review and trust the
Sentry hook before it takes effect. Uninstall with `--uninstall`.

## OpenClaw

See [integrations/openclaw/README.md](../integrations/openclaw/README.md).
Experimental: written against the Plugin SDK docs; OpenClaw moves fast.

## Hermes Agent

Hermes Agent (Nous Research) handles command approval internally — a curated
dangerous-pattern list plus optional LLM assessment in `smart` mode. As of
v0.14.x there is **no external policy hook**, so Sentry cannot screen Hermes
commands the way it does for Claude Code or Codex. What works today:

1. **Use Hermes' own controls** in `~/.hermes/config.yaml`:

   ```yaml
   approvals:
     mode: manual        # prompt before risky commands
     cron_mode: deny
   command_allowlist: [] # keep this tight
   ```

2. **Sentry's fswatch monitor still covers Hermes**: filesystem access to
   sensitive paths (`~/.ssh`, keychains) is detected regardless of which agent
   triggers it, and hard mode's self-protection applies machine-wide.

3. **Audit overlap warning**: Sentry's default home directory is currently
   `~/.hermes` — the same directory Hermes Agent uses. They coexist (Sentry
   only writes `sentry-config.json`, `safety-rules.json`, and `logs/sandbox-*`),
   but a dedicated Sentry home is planned to avoid confusion.

If Hermes adds a pre-execution policy hook, the adapter will be ~80 lines on
top of `sentryctl check` — contributions welcome, and a feature request
upstream would help.

## Writing your own adapter

For any platform with a pre-execution hook:

1. Extract the command string and working directory from the platform's event.
2. Call `sentryctl check --json --log --component <your-platform> -- "$CMD"`,
   passing the command **as an argument, never interpolated into shell code**.
3. Map the verdict + mode to the platform's decision vocabulary; when in
   doubt, prefer "ask the human" over allow or silent deny.
4. On any error in steps 1–3, do nothing — let the platform's own permission
   system decide.

The Claude Code adapter (`integrations/claude-code/sentry-pretooluse-hook.sh`)
is the reference implementation.
