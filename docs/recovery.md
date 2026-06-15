# Recovery Guide

This guide explains how to inspect and recover from Agentic Sentry enforcement events.

Read this before enabling `hard` mode.

## Quick recovery (60 seconds)

If enforcement just triggered and you want everything back:

```bash
./sentryctl restore        # full recovery: network + processes (asks for the restore code)
```

If only your processes are frozen (or you want them back before dealing with the network):

```bash
./sentryctl unfreeze       # resume frozen processes only — no restore code needed
```

Not sure what state you are in?

```bash
./sentryctl status
./enforcement_recovery_module.sh status
```

Want to preview what restore would do before running it?

```bash
./enforcement_recovery_module.sh restore --dry-run
```

## What may happen during hard enforcement

When hard enforcement is triggered, Sentry may:

- Cut network access using macOS network controls and a project-owned `pf` anchor.
- Freeze suspicious processes with `kill -STOP`.
- Save suspended PIDs so they can be resumed later.
- Generate a one-time restore code.
- Log the enforcement reason and recovery state.

Default `soft-block` mode does not normally cut network access or freeze processes.

## Check current status

Run:

```bash
./sentryctl status
./enforcement_recovery_module.sh status
```

Look for:

- Active network interface
- Wi-Fi device state
- Suspended process file
- Restore code file
- Enforcement log path

## Normal recovery path

Use the built-in restore command:

```bash
./sentryctl restore
```

or:

```bash
./enforcement_recovery_module.sh restore
```

If a restore code is required, use the code shown during enforcement. The restore code is stored under the private Sentry home directory with restricted permissions.

Default restore-code location:

```bash
~/.agentsentry/agentsentry-restore.code   # legacy installs: ~/.hermes/...
```

Permissions should be:

```bash
chmod 700 ~/.agentsentry
chmod 600 ~/.agentsentry/agentsentry-restore.code
```

## Resume frozen processes without touching the network

`unfreeze` resumes only the processes Sentry itself recorded as suspended. It never
changes network state, so it does not require the restore code — it is the fast,
low-stakes first step when a work process got frozen:

```bash
./sentryctl unfreeze            # interactive confirmation
./sentryctl unfreeze --yes      # non-interactive (for scripts)
./enforcement_recovery_module.sh unfreeze --dry-run   # just show what would resume
```

## Manual recovery: resume frozen processes

If restore fails to resume processes, inspect the suspended PID file:

```bash
cat /tmp/suspended_pids.txt
```

Resume a process manually:

```bash
kill -CONT <pid>
```

Resume all listed PIDs:

```bash
while read -r pid; do
  [ -n "$pid" ] && kill -CONT "$pid" 2>/dev/null || true
done < /tmp/suspended_pids.txt
```

Then remove the stale file:

```bash
rm -f /tmp/suspended_pids.txt
```

## Manual recovery: restore Wi-Fi

Find the Wi-Fi device:

```bash
networksetup -listallhardwareports
```

Turn Wi-Fi back on:

```bash
networksetup -setairportpower <device> on
```

Example:

```bash
networksetup -setairportpower en0 on
```

## Manual recovery: restore network interface

Bring an interface back up:

```bash
sudo ifconfig <interface> up
```

Example:

```bash
sudo ifconfig en0 up
```

Renew DHCP if needed:

```bash
sudo ipconfig set <interface> DHCP
```

## Manual recovery: clear Sentry pf rules

Sentry uses a project-owned `pf` anchor named `agentsentry`.

Flush only the Sentry anchor:

```bash
sudo pfctl -a agentsentry -F all
```

Do not disable global `pf` unless you understand your system firewall, VPN, or security tooling. Sentry restore intentionally avoids `pfctl -d` because that can disable unrelated rules.

## If DNS or routing is still broken

Try:

```bash
scutil --dns
route get default
networksetup -setdnsservers Wi-Fi Empty
```

Then reconnect Wi-Fi from macOS System Settings if needed.

## Recovery-code troubleshooting

If the restore code file is missing:

1. Check the enforcement log.
2. Confirm whether enforcement actually completed.
3. Use manual recovery steps above.
4. Re-run status after recovery.

The restore code is a safety confirmation mechanism. It is not intended as cryptographic authentication.

## Uninstall

If installed through `install.sh`, use the installer uninstall path if available:

```bash
./install.sh --uninstall
```

Then verify:

```bash
./sentryctl status
launchctl list | grep -i sentry || true
```

Clean user-local runtime files only after confirming no enforcement is active:

```bash
rm -f ~/.agentsentry/agentsentry-restore.code   # legacy: ~/.hermes/...
rm -f /tmp/suspended_pids.txt
```

## Prevention tips

- Start in `audit` or `warn` mode.
- Move to `soft-block` after reviewing false positives.
- Use `hard` mode only in controlled environments.
- Keep another terminal session open when testing hard enforcement.
- Review this recovery guide before running high-risk agent workflows.

## When to file an issue

Open a GitHub issue if:

- Restore does not resume processes.
- Network remains unavailable after following this guide.
- The tool freezes an unrelated critical process.
- Documentation does not match actual behavior.

For exploitable bypasses or vulnerabilities, follow [SECURITY.md](../SECURITY.md) instead of filing a public issue.
