# Contributing to Agentic Sandbox Sentry

Thank you for considering a contribution. This project is a security-sensitive tool that can block terminal commands, freeze processes, and isolate network access in hard enforcement mode. Please favor correctness, safety, and clear recovery behavior over feature speed.

## Development setup

Clone the repository:

```bash
git clone https://github.com/Hellotravisss/agentic-sandbox-sentry.git
cd agentic-sandbox-sentry
```

Install useful development dependencies:

```bash
# macOS
brew install bash jq fswatch shellcheck go

# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y bash jq inotify-tools shellcheck golang
```

Make scripts executable if needed:

```bash
chmod +x run-tests.sh tests/run-tests.sh tests/lib/test-helpers.sh
chmod +x sentryctl *.sh
```

## Running tests

Run the full shell test suite:

```bash
./run-tests.sh --ci
```

Run Go TUI checks:

```bash
cd tui
go test ./...
go build -o /tmp/sentry-tui .
```

Run syntax checks:

```bash
for f in *.sh tests/*.sh tests/lib/*.sh; do bash -n "$f"; done
zsh -n sandbox-hooks.zsh
python3 -m py_compile dashboard/app.py
```

Run ShellCheck locally:

```bash
shellcheck *.sh tests/*.sh tests/lib/*.sh || true
```

ShellCheck is currently non-blocking in CI while legacy warnings are triaged.

## Pull request expectations

Before opening a PR:

1. Keep changes small and focused.
2. Include tests for behavior changes when practical.
3. Update README or docs when user-visible behavior changes.
4. Do not make physical enforcement more aggressive without documenting recovery behavior.
5. Avoid broad process matching, global firewall changes, or destructive shell operations unless there is a clear safety rationale.
6. Run the test commands above and include the results in the PR description.

## Security-sensitive changes

Changes are considered security-sensitive when they affect:

- Network isolation or `pf` rules
- Process freezing/resume behavior
- Restore-code generation, storage, or validation
- Shell command detection rules
- Self-protection/tamper detection
- Dashboard binding, debug mode, or exposed status data
- Installer or uninstall behavior

For these changes, please include:

- Threat or failure mode being addressed
- Expected safe behavior
- Recovery path if something goes wrong
- Tests or manual verification steps

## Reporting security issues

Please do not open a public issue for exploitable vulnerabilities or bypasses. Follow the reporting guidance in [SECURITY.md](SECURITY.md).

## Coding style

- Prefer explicit shell logic over clever one-liners.
- Quote variables unless word splitting is intentional.
- Keep defaults conservative.
- Fail safe: if uncertain, prefer audit/warn behavior over physical enforcement.
- Keep recovery commands documented and testable.

## Project values

Agentic Sandbox Sentry should help developers experiment with automated agents safely. Contributions should reduce risk, improve observability, or make recovery easier without surprising users.
