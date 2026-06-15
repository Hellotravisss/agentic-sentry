# Changelog

All notable changes to Agentic Sandbox Sentry are documented here.

## v0.1.6 - 2026-06-14

### Added

- Added retry-loop detection (threat model T9): `sentry-rate.sh` tracks command repetition in a sliding window (default 8x in 10 minutes) across the zsh hook and all agent adapters, logging a single `RATE_REPEAT` event at the crossing. Signal-only — repetition never blocks. Tune with `SENTRY_RATE_THRESHOLD` / `SENTRY_RATE_WINDOW`.

### Changed

- `sentryctl test` now delegates to the real detection engine via `sentryctl check`, so its verdict always matches what the hooks and agent integrations enforce (it previously used a separate, cruder heuristic).

### Removed

- Removed the no-op `check_hash_allowlist` stub from the zsh hook and the placeholder `trusted_hashes` field from `safety-rules.json` — they computed hashes but never enforced anything, implying a verification that did not exist.

### Fixed

- Fixed reason-string pollution for `rm`/`rmdir` detections: re-declaring `local` inside a zsh loop prints the variable value, which leaked `real_allowed=...` lines into the reasons shown by hooks and adapters. The shared checker also now filters reasons defensively.

## v0.1.5 - 2026-06-12

### Added

- Added Claude Code integration: a PreToolUse hook (`integrations/claude-code/`) that evaluates every agent Bash command with Sentry's detection engine before execution, mapping Sentry modes to allow/ask/deny decisions. Includes an idempotent installer for `~/.claude/settings.json` and full test coverage.
- Added `sentry-audit` Claude Code skill: teaches Claude to read Sentry's audit records — summarize detections, group retry loops, explain denials in plain language — without ever reconfiguring the guard. Installed via `install-claude-skill.sh`.
- Added `sentryctl check`: agent-agnostic machine-readable verdict command (`--json`, `--log`, exit 1 = dangerous) backing all platform adapters via the new shared `sentry-check.sh`.
- Added OpenAI Codex CLI adapter (`integrations/codex/`): PermissionRequest hook with hooks.json installer; soft-block/hard deny, other modes defer to Codex's own approval prompt with an audit-log entry.
- Added experimental OpenClaw plugin (`integrations/openclaw/sentry-guard`): `before_tool_call` handler mapping Sentry modes to block / requireApproval / logged passthrough.
- Added `docs/integrations.md`: per-platform status matrix, decision mapping, Hermes Agent cooperation guide, and a recipe for writing new adapters.

### Changed

- Sentry's default home directory moved from `~/.hermes` — which collides with Hermes Agent's config directory — to `~/.agentsentry`. Existing installs keep working (legacy `~/.hermes` is detected and used automatically); run `sentryctl migrate-home` to move Sentry's files out of Hermes' directory. `SENTRY_HOME` env override continues to win over both.

## v0.1.4 - 2026-06-12

### Added

- Added `dry-run` protection mode: blocks risky commands like `soft-block` while printing the full hard-enforcement action plan (network cut, firewall anchor, candidate PIDs) without executing any of it. Also available directly as `enforcement_recovery_module.sh enforce --dry-run` and `restore --dry-run`.
- Added `unfreeze` recovery command (`sentryctl unfreeze`): resumes Sentry-suspended processes without touching network state or requiring the restore code.
- Added `sentryctl restore` passthrough (previously documented but not implemented).
- Added `docs/threat-model.md`: concrete agent failure scenarios mapped to per-mode coverage, including quiet failure modes contributed in issue #5 (stale session reuse, retry budget burn, orphaned background processes, credential-bearing debug artifacts).
- Added automated release workflow: tag-triggered tarball build, SHA-256 checksums, signed build provenance via GitHub artifact attestation, and changelog-derived release notes. Documented in `docs/releasing.md`.
- Added test suites for dry-run behavior, process matching/suspension, false-positive regressions, and TTY-wrapper detection.

### Fixed

- Fixed a false positive where every `curl` command without a pipe was flagged as `curl | shell` (zsh ERE treated `\|` as alternation).
- Fixed a false positive where `bash -c` payloads containing the substring `sh` (for example `bash -c "echo fish"`) were blocked.
- Fixed TTY-wrapper detection (`nohup`, `script`, `expect`) which never matched because its pattern failed to compile in zsh — wrapped dangerous commands such as `nohup rm -rf` are now detected.
- Fixed a logger lock race where stale-lock reclaim could delete a lock another writer had just acquired, breaking mutual exclusion under concurrency.
- Fixed `_get_file_mtime` emitting empty or non-numeric output when the lock directory vanished mid-check (or via the GNU `stat -f` filesystem-mode fallback), which killed concurrent log writers under `set -eu` and dropped audit lines on Linux.

## v0.1.3 - 2026-05-31

### Added

- Added `sentryctl demo`, a safe dry-run walkthrough showing how representative risky commands would be handled across audit, warn, soft-block, and hard modes.
- Added README and modes documentation for demo mode.

### Changed

- Refined project positioning from strong sandbox language to a more accurate macOS runtime safety guard / emergency brake for local AI coding agents.
- Clarified that hard enforcement is optional and that the tool is not a full VM/container sandbox.

## v0.1.2 - 2026-05-31

### Added

- Added `CHANGELOG.md` to document release history.
- Added `CONTRIBUTING.md` with local setup, testing, pull request, and security contribution guidance.
- Added `docs/modes.md` explaining audit, warn, soft-block, and hard enforcement behavior.
- Added `docs/recovery.md` with recovery, rollback, uninstall, and manual restoration steps.
- Added non-blocking ShellCheck coverage to GitHub Actions.

### Changed

- Moved one-time restore code storage from shared `/tmp` to the private Sentry home directory.
- Documented safer restore-code permissions and recovery workflow.

## v0.1.1 - 2026-05-31

### Added

- Added Go module checksums for reproducible TUI builds.
- Added GitHub Actions coverage for Go TUI tests and builds.
- Added README test status badge.

### Changed

- Hardened the web dashboard by binding to localhost by default.
- Disabled Flask debug mode by default.
- Clarified README behavior for default soft-block mode versus hard enforcement.
- Unified user-facing version numbers to `0.1.1`.

### Fixed

- Fixed `sentryctl tui --once` in CI and non-interactive environments.
- Prevented duplicate `pf` anchor entries during setup.
- Avoided disabling global `pf` rules during restore.

## v0.1.0 - 2026-05-31

### Added

- Initial public release.
- Added terminal safety monitoring for risky automated-agent workflows.
- Added command evaluation modes: audit, warn, soft-block, and hard.
- Added physical enforcement and recovery module.
- Added structured local logging.
- Added Web dashboard and TUI status interfaces.
- Added `SECURITY.md` with threat model, trust boundaries, limitations, and reporting guidance.
- Added initial test suite and CI workflow.
