# Agentic Sandbox Sentry

**A lightweight, open-source macOS security tool that provides millisecond-level protection against rogue AI agents remotely controlling your Terminal.**

When you let phone or cloud-based AI agents (like ChatGPT, Claude, Grok, etc.) run commands on your Mac, there is always a risk of unintended or malicious file deletion and credential access. Agentic Sandbox Sentry solves this by monitoring commands and file system events in real time and **physically cutting network access + freezing processes** the moment dangerous behavior is detected — with no LLM second pass.

## Core Features

- **Millisecond detection** — zsh preexec hooks + fswatch event monitoring
- **Physical enforcement** — immediately disables Wi-Fi/Ethernet + loads full outbound block via pf + freezes suspicious processes (`kill -STOP`)
- **Zero LLM dependency** in the hot path — pure local rules
- **Self-protection** — monitors its own files and rules
- **Lightweight** — pure shell + fswatch, no heavy dependencies
- **macOS native** — works with standard tools (`networksetup`, `ifconfig`, `pmset`, `launchd`)

## What It Blocks

- `rm -rf` outside allowed project directories
- Access to `~/.ssh`, `~/.gnupg`, Keychains, `/etc`, `/System`
- Any `sudo` command
- Network configuration changes
- `curl ... | bash` patterns
- File operations on sensitive paths via fswatch (Removed, Renamed, chmod, etc.)

## Quick Start

### 1. Install dependencies

```bash
brew install fswatch jq
```

### 2. One-time setup

```bash
cd /path/to/Agentic-Sandbox-Sentry
./enforcement_recovery_module.sh setup
```

### 3. Load shell protection

```bash
echo 'source /path/to/Agentic-Sandbox-Sentry/sandbox-hooks.zsh' >> ~/.zshrc
source ~/.zshrc
```

### 4. Enable background monitoring (recommended)

```bash
chmod +x sandbox-monitor.fswatch.sh
nohup ./sandbox-monitor.fswatch.sh &
```

Or install the launchd agent for automatic startup:

```bash
cp com.agentsentry.fswatch.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.agentsentry.fswatch.plist
```

## Project Structure

```
Agentic-Sandbox-Sentry/
├── sandbox-hooks.zsh              # zsh command interceptor
├── sandbox-monitor.fswatch.sh     # aggressive fswatch file monitor
├── enforcement_recovery_module.sh # physical network cut + process freeze
├── sandbox-egress-watcher.sh      # outbound connection monitor
├── sentry-status.sh               # status and diagnostics
├── safety-rules.json              # detection rules
├── com.agentsentry.fswatch.plist  # launchd auto-start
├── auditd-lightweight.rules       # optional auditd rules
└── install.sh                     # helper installer
```

## Recovery

After enforcement triggers, run:

```bash
./enforcement_recovery_module.sh restore
```

**This now requires the one-time restore code** that was printed in large text during enforcement (also saved to `/tmp/agentsentry-restore.code`).

There is also an emergency override path (type `EMERGENCY` then a confirmation phrase), but it is intentionally cumbersome.

Any processes that were frozen with `kill -STOP` will be automatically resumed (`kill -CONT`) upon successful restore.

## License

MIT License — free for personal and commercial use.

## Contributing

Pull requests are welcome. Please keep changes lightweight and focused on the "no LLM in hot path + physical enforcement" philosophy.

## Disclaimer

This tool performs aggressive network isolation. Use at your own risk. Always test in a safe environment first.