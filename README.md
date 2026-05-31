# Agentic Sandbox Sentry

**A lightweight, open-source macOS security tool that provides millisecond-level protection against rogue AI agents remotely controlling your Terminal.**

When you let phone or cloud-based AI agents (like ChatGPT, Claude, Grok, etc.) run commands on your Mac, there is always a risk of unintended or malicious file deletion and credential access. Agentic Sandbox Sentry solves this by monitoring commands and file system events in real time and **physically cutting network access + freezing processes** the moment dangerous behavior is detected — with no LLM second pass.

## Core Features

- **Millisecond detection** — zsh preexec hooks + fswatch event monitoring
- **Physical enforcement** — immediately disables Wi-Fi/Ethernet + loads full outbound block via pf + freezes suspicious processes (`kill -STOP`)
- **Zero LLM dependency** in the hot path — pure local rules
- **Self-protection** — monitors its own files, rules, and baseline integrity with meta-hash verification
- **Lightweight** — pure shell + fswatch, no heavy dependencies
- **macOS native** — works with standard tools (`networksetup`, `ifconfig`, `pmset`, `launchd`, `pfctl`)
- **Robust recovery** — mandatory one-time restore code + auto-resume of frozen processes

## What It Blocks

- `rm -rf` and destructive operations outside allowed project directories
- Access to `~/.ssh`, `~/.gnupg`, Keychains, `/etc`, `/System`, credentials
- Any `sudo` command or privilege escalation
- Network configuration changes and egress attempts
- `curl ... | bash` and one-liner execution patterns
- File operations on sensitive paths (Removed, Renamed, chmod, etc.) via fswatch
- Common bypass techniques (exec, subshells, python -c, expect, etc.)

## Quick Start

### Prerequisites

```bash
brew install fswatch jq
```

### 1. Clone and Install

```bash
git clone https://github.com/your-org/Agentic-Sandbox-Sentry.git
cd Agentic-Sandbox-Sentry
chmod +x *.sh sentryctl
./install.sh
```

The installer:
- Detects your script directory dynamically
- Generates a tailored launchd plist
- Sets up baseline integrity hashes for self-protection
- Provides clear next steps

### 2. Load Shell Protection (zsh)

```bash
echo 'source "$(pwd)/sandbox-hooks.zsh"' >> ~/.zshrc
source ~/.zshrc
```

### 3. Enable Background Monitoring (recommended)

Install the launchd agent for automatic startup and recovery:

```bash
./install.sh launchd   # or manually load the generated plist
```

Or run manually:

```bash
nohup ./sandbox-monitor.fswatch.sh > /tmp/sentry-monitor.log 2>&1 &
```

### 4. Verify Status

```bash
./sentry-status.sh
# or
./sentryctl status
```

## Usage Examples

### Normal Operation
```bash
$ ls
Documents  Downloads  ...

$ cd ~/safe-project
$ echo "hello" > test.txt
# Works normally
```

### Detection in Action
```bash
$ rm -rf ~/Documents
🚨 BLOCKED: rm outside allowed project dirs
[Agentic Sandbox Sentry] Enforcement triggered. Network isolated. Processes frozen.
Restore code: A7K9P2QX
See /tmp/agentsentry-restore.code
```

### Recovery
```bash
./enforcement_recovery_module.sh restore
# Enter the exact restore code when prompted
```

## Configuration

Key files:
- `safety-rules.json` — sensitive paths and patterns
- `sentry-config.sh` — allowed directories, logging settings
- Edit `sandbox-hooks.zsh` to customize `is_path_in_allowed_project()` logic

Allowed directories are defined relative to your home (supports spaces in paths like "Vibe Coding").

## Troubleshooting

### Hooks not triggering
- Ensure `source .../sandbox-hooks.zsh` is in `~/.zshrc` (not `.zprofile`)
- Run `typeset -f preexec` to verify the function is loaded
- Check for syntax errors: `zsh -n sandbox-hooks.zsh`

### fswatch monitor not starting
- Verify `fswatch --version`
- Check launchd status: `launchctl list | grep agentsentry`
- Logs: `tail -f /tmp/sentry-monitor.log`

### False positives on safe paths
- Update the allow-list logic in `sandbox-hooks.zsh` (function `is_path_in_allowed_project`)
- Use full realpath resolution (already handled)

### Restore code lost
- The code is also written to `/tmp/agentsentry-restore.code`
- Emergency override available (intentionally cumbersome)

### Self-protection alerts
- If sentry files are modified, full enforcement triggers automatically
- Re-run `./install.sh` to regenerate baseline hashes after intentional updates

### Network not restoring
- Run `./enforcement_recovery_module.sh restore` with the code
- Manual fallback: `sudo pfctl -F all -f /etc/pf.conf && networksetup -setairportpower en0 on`

## Project Structure

```
Agentic-Sandbox-Sentry/
├── sandbox-hooks.zsh              # zsh command interceptor + policy
├── sandbox-monitor.fswatch.sh     # real-time fswatch file monitor + PID hints
├── enforcement_recovery_module.sh # physical network cut + process freeze + restore
├── sandbox-egress-watcher.sh      # outbound connection monitor
├── sentry-status.sh               # diagnostics and health checks
├── sentry-logger.sh               # structured JSON logging with rotation
├── sentry-selfguard.sh            # self-protection + baseline integrity
├── sentryctl                      # main control CLI
├── sentry-config.sh               # environment and path configuration
├── safety-rules.json              # detection rules
├── com.agentsentry.fswatch.plist  # launchd auto-start (generated)
├── install.sh                     # robust one-command installer + launchd setup
├── auditd-lightweight.rules       # optional auditd support
├── tests/                         # validation suite
├── README.md
├── ARCHITECTURE.md
└── LICENSE
```

## Recovery & Enforcement Flow

1. Violation detected via hook or fswatch
2. Enforcement script called with context (path, PID hints)
3. Network isolated (Wi-Fi off, pf outbound block)
4. Suspicious processes frozen with `kill -STOP`
5. Random 8-char restore code displayed + saved
6. On restore: verify code, flush pf, re-enable network, `kill -CONT` frozen processes

## License

MIT License — free for personal and commercial use.

## Contributing

Pull requests are welcome. Please keep changes lightweight and focused on the "no LLM in hot path + physical enforcement" philosophy. Run the test suite in `tests/` before submitting.

## Disclaimer

This tool performs aggressive network isolation and process suspension. Use at your own risk. Always test in a safe environment first. The authors are not responsible for data loss or lockouts.
