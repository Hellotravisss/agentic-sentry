# Agentic Sandbox Sentry Architecture

**Lightweight macOS-Native Real-Time Command Auditing & Physical Enforcement**

Current implementation (2026): Pure shell + fswatch. No Python in the hot path. Strong emphasis on self-protection, tamper detection, mandatory restore codes, and process suspension.

## Core Design Goals

- Real-time auditing of remote AI-controlled Terminal (zsh) sessions
- Detect: destructive `rm` outside allowed dirs, sensitive file/key access, sudo, network changes, egress attempts
- Latency: <50ms local detection, zero LLM involvement in enforcement path
- Constraints: pure POSIX shell + macOS builtins + fswatch, open-source, zero heavy frameworks
- Self-protection: monitor own scripts + rules + baseline integrity

## Tech Stack

- **Primary detection**: zsh `preexec` hooks (`sandbox-hooks.zsh`)
- **File monitoring**: `fswatch` (event-driven) via `sandbox-monitor.fswatch.sh`
- **Enforcement**: `enforcement_recovery_module.sh` — network isolation (`networksetup`, `ifconfig`, `pfctl`) + `kill -STOP` + auto-resume
- **Self-guard**: `sentry-selfguard.sh` with meta-hash verification of baseline
- **Logging**: `sentry-logger.sh` — structured JSON + rotation + mkdir lock
- **Control**: `sentryctl` CLI + `sentry-status.sh`
- **Config**: `sentry-config.sh` + `safety-rules.json`
- **Install/Launchd**: `install.sh` (dynamic path handling, plist generation)

No Python, no external pip packages, no kexts.

## Data Flow

1. **Shell session starts**
   - `~/.zshrc` sources `sandbox-hooks.zsh`
   - Preexec/precmd hooks registered

2. **Every command**
   - `preexec` captures full command line + cwd
   - `is_dangerous()` checks against rules (rm outside allowed, sudo, sensitive paths, bypass patterns)
   - On violation: call enforcement + log + block
   - Decision <10ms (pure shell)

3. **Background monitoring** (`sandbox-monitor.fswatch.sh`)
   - Watches project dirs + sensitive paths + self files
   - On event (Removed, Renamed, chmod, etc.): extract PID via lsof, trigger enforcement
   - Passes context to enforcement module

4. **Enforcement**
   - Disable Wi-Fi + Ethernet
   - Load pf rules for full outbound block
   - Freeze matching PIDs (`kill -STOP`)
   - Generate + display 8-char restore code
   - Write code to `~/.hermes/agentsentry-restore.code` with restricted permissions

5. **Restore**
   - Verify restore code (or EMERGENCY phrase)
   - Flush pf, re-enable network interfaces
   - Resume frozen processes (`kill -CONT`)
   - Log outcome

6. **Self-protection**
   - `sentry-selfguard.sh` runs on every check
   - Verifies SHA256 of baseline file + meta-hash of the baseline itself
   - Any tampering triggers full enforcement

## Key Components

| File | Purpose |
|------|---------|
| `sandbox-hooks.zsh` | Command interception, policy engine, bypass resistance |
| `sandbox-monitor.fswatch.sh` | Event-driven watcher with robust path/PID parsing |
| `enforcement_recovery_module.sh` | Physical cut + freeze + restore with confirmation |
| `sentry-selfguard.sh` | Tamper detection + baseline integrity |
| `sentry-logger.sh` | Structured logging with concurrency-safe locks |
| `sentry-status.sh` / `sentryctl` | Diagnostics, health, manual control |
| `install.sh` | One-command setup, dynamic plist generation, baseline init |
| `safety-rules.json` | Sensitive paths and patterns |

## Detection Rules (Hardcoded, No LLM)

- `rm` / `rmdir` / destructive ops outside allowed project dirs (supports paths with spaces)
- Access to `~/.ssh`, `~/.gnupg`, Keychains, `/etc`, `/System`, credentials
- Any `sudo` or privilege escalation
- Network changes, `curl|bash`, `python -c` dangerous patterns
- Subshell/exec bypass attempts (`exec rm`, `(zsh -c ...)`, `expect`, `script`)
- File events on sensitive paths via fswatch

## Performance & Robustness

- Hook overhead: <5ms
- fswatch: event-driven (near real-time)
- Path handling: robust line-based + realpath (handles spaces)
- Locking: mkdir-based for logger, stale lock cleanup
- macOS specifics: PlatformSpecific events, pfctl, networksetup, launchd Throttle/Nice

## Self-Protection

The system protects itself:
- Monitors its own script files and rules
- Baseline SHA256 + meta-hash of baseline file
- Tamper → immediate full enforcement

## Installation & Activation

See README.md for the recommended `install.sh` flow.

The architecture meets all constraints: pure scripts, sub-50ms detection, macOS-native, no heavy dependencies, suitable for AI agent sessions.

## Future / Extensibility

Keep additions lightweight. Prefer shell + fswatch over new daemons. Physical enforcement remains the core philosophy.