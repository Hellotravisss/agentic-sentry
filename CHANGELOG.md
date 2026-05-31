# Changelog

All notable changes to Agentic Sandbox Sentry are documented here.

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
