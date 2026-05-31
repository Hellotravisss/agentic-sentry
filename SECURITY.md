# SECURITY.md

## Overview

This document describes the threat model, trust boundaries, and known limitations of Agentic Sandbox Sentry, with special focus on its self-protection mechanisms (`sentry-selfguard.sh` and baseline integrity system).

The primary goal of the system is to protect a macOS host from rogue AI agents that have gained shell access via remote control of Terminal (zsh). It does so through real-time command interception and filesystem monitoring, followed by aggressive physical enforcement (network isolation + process suspension).

## Threat Model

### Primary Threat Actor
- **Rogue or compromised AI agent** with interactive or scripted access to a zsh shell on the host.
- The agent may attempt:
  - Destructive file operations (`rm -rf` outside allowed directories)
  - Credential theft (access to `~/.ssh`, `~/.gnupg`, keychains)
  - Privilege escalation (`sudo`)
  - Egress / data exfiltration
  - Installation of persistence or backdoors
  - Direct tampering with Sentry components to disable protection

### Attacker Capabilities (Assumed)
- Full ability to execute arbitrary commands in the monitored shell.
- Ability to read/write files in user-writable locations.
- Knowledge of common bypass techniques (subshells, `exec`, `expect`, `python -c`, etc.).
- Potential awareness of Sentry's existence and desire to disable it.

### Out of Scope / Not Protected Against
- Physical access to the machine
- Kernel-level exploits or rootkits (before Sentry loads)
- Attacks against the macOS kernel or launchd itself
- Supply-chain attacks on `brew`, `fswatch`, or system binaries
- Social engineering of the human operator
- Compromise of the restore code storage location (`/tmp`)

## Trust Boundaries

1. **Shell Hook Boundary**
   - `sandbox-hooks.zsh` (sourced into `~/.zshrc`) runs in the same process as user/AI commands.
   - Trust: The hook must correctly classify commands before they execute. It is the first line of defense.

2. **Filesystem Monitoring Boundary**
   - `sandbox-monitor.fswatch.sh` and `sentry-selfguard.sh` run as background processes (often under launchd).
   - They observe events via `fswatch` and react by calling enforcement.
   - Trust: Event stream is reliable; PID extraction via `lsof` is accurate.

3. **Self-Protection / Baseline Boundary**
   - `sentry-selfguard.sh` maintains:
     - `sentry-baseline.sha256` (hashes of protected scripts)
     - `sentry-baseline.sha256.meta` (hash of the baseline)
     - `sentry-baseline.sha256.metahash` (hash of the meta file)
   - A two-level hash chain protects the baseline itself.
   - Optional use of `chflags schg` (immutable bit) when running as root.
   - Trust assumption: An attacker who can modify files can also attempt to modify the baseline files. The meta-chain is designed to detect this.

4. **Enforcement Boundary**
   - `enforcement_recovery_module.sh` performs network cut (`networksetup`, `ifconfig`, `pfctl`) and `kill -STOP`.
   - Requires the ability to modify network settings and signal processes.
   - Restore requires the one-time code or emergency phrase.

5. **Logging Boundary**
   - `sentry-logger.sh` uses mkdir-based locking for concurrency safety.
   - Logs are written to `$SENTRY_LOG_DIR` (default under `~/.hermes`).

## Self-Protection Mechanisms

- **Baseline computation** (`sentry-selfguard.sh baseline`): Hashes all core scripts + safety rules at install time or after updates.
- **Meta-hash chain**: Protects the baseline file from tampering. Tampering with the meta or metahash file is also detected.
- **fswatch monitoring**: Continuously watches protected directories and triggers `verify_integrity` + optional enforcement on any change.
- **Tamper response**: Structured logging, macOS notification, integrity re-check, and (in hard mode) full enforcement.
- **Lockfile skipping**: Own writes during baseline updates are ignored via a lockfile.

## Known Limitations of the Self-Protection System

1. **Baseline Must Be Established**
   - If `baseline` has never been run, or the baseline files are missing, self-protection provides no integrity guarantees.
   - First run after install is critical.

2. **Meta-Chain Requires All Three Files**
   - If any of `BASELINE_FILE`, `META_FILE`, or `META_META_FILE` is missing or corrupted, verification fails open (warning) or closed depending on context.

3. **Immutable Flag Requires Root**
   - `chflags schg` (make immutable) only works when the script runs as root. Most users run as non-root, so the flag is silently skipped. An attacker with user privileges can still modify files.

4. **fswatch / Event Reliability**
   - Relies on `fswatch` being installed and running.
   - Very rapid or bursty modifications might theoretically race with the monitor.
   - Does not protect against in-memory tampering of a running process (only on-disk files).

5. **Restore Code Location**
   - The restore code is written to `~/.hermes/agentsentry-restore.code` by default with `600` file permissions inside a `700` user-private directory. This reduces exposure compared with shared `/tmp`, but any process running as the same user may still read it.

6. **No Protection Before Loading**
   - If an attacker modifies scripts or `~/.zshrc` *before* the hooks and monitors are loaded (e.g., during initial setup or after a reboot before launchd starts), the system can be neutered.

7. **Hard Mode Enforcement Risk**
   - In `SENTRY_MODE=hard`, a false-positive tamper detection will trigger full network isolation and process freeze on the host. This is by design but increases operational risk.

8. **No Cryptographic Signatures**
   - Uses simple SHA-256 hashes only. No code signing, detached signatures, or Merkle trees beyond the basic meta-chain.

9. **macOS-Specific Assumptions**
   - Heavy use of `networksetup`, `pfctl`, `osascript`, `chflags`, and launchd. Behavior on other Unix systems is undefined.

10. **Human Operator Override**
    - The emergency restore phrase bypasses the code entirely. If the operator is socially engineered or the phrase is known, recovery is trivial for an attacker.

## Recommendations

- Always run `./install.sh` after any manual edits to protected files so the baseline is refreshed.
- Consider running the selfguard monitor under launchd with higher priority.
- Review `sentry-selfguard.sh` and `enforcement_recovery_module.sh` regularly.
- Test tamper scenarios in a safe environment (the `tests/` directory contains some validation).

## Reporting Security Issues

Please report suspected vulnerabilities privately via the project maintainer rather than opening public issues.

---

*This is a basic security document. It reflects the design as of the current implementation (pure shell + fswatch, no Python in hot path).*