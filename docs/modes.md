# Operating Modes

Agentic Sandbox Sentry is designed to be conservative by default. It separates detection from physical enforcement so users can choose the right safety level for their environment.

## Summary

| Mode | Logs event | Warns user | Blocks command | Cuts network / freezes processes |
|---|---:|---:|---:|---:|
| `audit` | Yes | No | No | No |
| `warn` | Yes | Yes | No | No |
| `soft-block` | Yes | Yes | Best effort | No |
| `hard` | Yes | Yes | Yes | Yes |

`soft-block` is the default mode. It is intended to reduce accidental damage while avoiding surprise system-level changes.

## `audit`

Audit mode records risky command patterns but does not interrupt the terminal workflow.

Use this mode when:

- You are evaluating false positives.
- You want observability without enforcement.
- You are testing new detection rules.

Expected behavior:

- Risky commands are logged.
- The command is allowed to continue.
- No process or network state is changed.

## `warn`

Warn mode records risky commands and prints a warning, but still allows the command to continue.

Use this mode when:

- You want visible reminders without blocking work.
- You are onboarding users to the tool.
- You are testing rules in a shared development workflow.

Expected behavior:

- Risky commands are logged.
- A warning is shown in the terminal.
- The command is allowed to continue.
- No physical enforcement is triggered.

## `soft-block`

Soft-block mode attempts to stop risky commands at the shell hook layer. This is the recommended default for regular use.

Use this mode when:

- You want protection against accidental destructive shell commands.
- You are using AI coding agents that may propose or run risky commands.
- You want enforcement without cutting network access or freezing processes.

Expected behavior:

- Risky commands are logged.
- A warning is shown.
- The shell hook attempts to return a non-zero status before execution.
- No network isolation or process freezing is triggered by normal command detection.

Limitations:

- Soft blocking depends on shell hook coverage.
- Commands run outside the hooked shell may not be blocked.
- It is not a sandbox boundary.

## `hard`

Hard mode is the strongest enforcement level. It can trigger physical controls such as network isolation and process freezing.

Use this mode when:

- You are intentionally testing dangerous automated-agent workflows.
- You need a stronger emergency stop for high-risk operations.
- You understand the recovery process in [recovery.md](recovery.md).

Expected behavior:

- Risky commands are logged.
- The command is blocked when possible.
- Physical enforcement can cut network access.
- Suspicious processes may be frozen with `kill -STOP`.
- A one-time restore code is generated for recovery.

Risks:

- Network access may be interrupted.
- Processes may need to be resumed.
- Recovery may require administrator privileges for firewall or network state.

Do not use hard mode until you have read and tested the recovery workflow.

## Changing modes

Show the current mode:

```bash
./sentryctl mode
```

Switch modes:

```bash
./sentryctl mode audit
./sentryctl mode warn
./sentryctl mode soft-block
./sentryctl mode hard
```

## Recommended progression

1. Start with `audit` to understand what would be flagged.
2. Move to `warn` if the rules look reasonable.
3. Use `soft-block` for regular day-to-day protection.
4. Use `hard` only for controlled tests or high-risk agent workflows.

## Safety note

This project is a local safety tool, not a virtualization sandbox. It should be combined with normal security practices: backups, least privilege, code review, and isolated test environments for untrusted automation.
