# Agentic Sandbox Sentry

[![Tests](https://github.com/Hellotravisss/agentic-sandbox-sentry/actions/workflows/test.yml/badge.svg)](https://github.com/Hellotravisss/agentic-sandbox-sentry/actions/workflows/test.yml)

**A lightweight macOS runtime safety guard for local AI coding agents — command-level monitoring, soft blocking, audit logs, and emergency network/process controls when you explicitly enable hard enforcement.**

## What it does

Agentic Sandbox Sentry monitors commands executed in your Terminal in real time. In the default `soft-block` mode, it blocks or warns on dangerous behavior such as `rm -rf` outside allowed directories, accessing SSH keys, running `sudo`, or attempting network changes.

When configured for `hard` enforcement, or when self-protection monitors detect severe tampering, it can take physical action:

- Cuts network access (Wi-Fi + Ethernet)
- Freezes suspicious processes (`kill -STOP`)
- Logs the event with structured data

All detection and enforcement happens **locally with zero LLM involvement** in the hot path.

## Why it matters

When you allow AI agents (ChatGPT, Claude, Grok, Cursor, etc.) to run commands on your machine, you are giving them significant power. Even well-intentioned models can make catastrophic mistakes. Malicious prompts or compromised agents can cause irreversible damage.

Agentic Sandbox Sentry acts as a **runtime safety layer and emergency brake**. It does not replace a true sandbox or VM, but it can add practical guardrails around local terminal-based AI workflows.

## Core Features

- **Command-level runtime detection** — zsh preexec hooks + fswatch event monitoring
- **Safe demo mode** — preview how risky commands would be handled without executing them
- **Configurable physical enforcement** — hard mode can disable network + freeze processes
- **Zero LLM dependency** in the hot path — pure local rules
- **Self-protection** — monitors its own files and baseline integrity with meta-hash verification
- **Lightweight** — pure shell + fswatch, no heavy dependencies
- **macOS native** — works with standard tools (`networksetup`, `ifconfig`, `pfctl`, `launchd`)
- **Robust recovery** — mandatory one-time restore code + auto-resume of frozen processes

## What It Blocks

- `rm -rf` and destructive operations outside allowed project directories
- Access to `~/.ssh`, `~/.gnupg`, Keychains, `/etc`, `/System`, credentials
- Any `sudo` command or privilege escalation
- Network configuration changes and egress attempts
- `curl ... | bash` and one-liner execution patterns
- File operations on sensitive paths via fswatch
- Common bypass techniques (exec, subshells, `python -c`, `expect`, etc.)

## Installation

### Prerequisites

```bash
brew install fswatch jq
```

### One-command Install

```bash
git clone https://github.com/Hellotravisss/agentic-sandbox-sentry.git
cd agentic-sandbox-sentry
./install.sh
```

The installer will:
- Set up shell hooks
- Generate a launchd plist for background monitoring
- Initialize self-protection baseline
- Install the `sentryctl` command

See `./install.sh --help` for advanced options (`--dry-run`, `--uninstall`, etc.).

## Usage

After installation, you can interact with the tool in several ways:

```bash
# Check current status
sentryctl status

# Safely preview how risky commands would be handled across modes
sentryctl demo

# View recent violations
sentryctl violations

# Open the interactive TUI
sentryctl tui

# Open the web dashboard
sentryctl dashboard

# Check self-protection status
sentryctl selfguard status
```

## Documentation

- [Operating modes](docs/modes.md) — explains `audit`, `warn`, `soft-block`, and `hard` behavior.
- [Recovery guide](docs/recovery.md) — explains how to restore network/process state after hard enforcement.
- [Contributing guide](CONTRIBUTING.md) — explains local setup, tests, and security-sensitive PR expectations.
- [Changelog](CHANGELOG.md) — tracks release history.

## Safety Disclaimer

**Use at your own risk.**

This tool is a runtime guard, not a full VM/container sandbox. In hard enforcement mode it can perform aggressive actions including network isolation and process suspension. While designed to protect your system, it may:

- Interrupt legitimate workflows
- Require manual recovery in some edge cases
- Have limitations in detecting highly sophisticated attacks

Always test in a safe environment first. The authors are not responsible for any data loss or system issues caused by the use of this software.