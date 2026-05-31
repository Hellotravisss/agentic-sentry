# SentryMenuBar — SwiftUI Menu Bar Spike

A working prototype of a macOS menu bar companion for Agentic Sandbox Sentry.

## What it does

- **Shield icon** in the menu bar — green when safe, red when enforcement is active
- **Popover** showing: status, enforcement state, violation count, health bar
- **Recent events** pulled from `/tmp/agentsentry.log`
- **Action buttons**: Refresh, Open Dashboard, Enable/Disable Sentry, Quit
- **Auto-polls** every 3 seconds for live status

## Build & Run

```bash
# Debug build (fast)
swift build

# Run it
.build/debug/SentryMenuBar &

# Release build (optimized)
swift build -c release
.build/release/SentryMenuBar &
```

No Xcode project needed — pure Swift Package Manager.

## Requirements

- macOS 13+ (Ventura) — uses `MenuBarExtra`
- Swift 5.9+ / Xcode 15+ or standalone Swift toolchain

## Architecture

```
Sources/
├── SentryMenuBarApp.swift   — @main app entry, MenuBarExtra scene
├── SentryState.swift        — ObservableObject, polls sentry-status.sh
└── SentryPopover.swift      — Popover UI: status grid, events, actions
```

## Integration points

The app reads data from:
- `./sentry-status.sh` — main status output
- `/tmp/agentsentry-enforcement.lock` — enforcement state
- `/tmp/agentsentry.log` — recent violation events
- `pgrep -f sandbox-monitor` — process liveness
- `http://localhost:5100` — web dashboard (opens in browser)

## Next steps (production hardening)

1. **launchd agent** — auto-start on login, keep-alive
2. **Real-time updates** — replace polling with file watch on `/tmp/agentsentry.log`
3. **Notifications** — `UserNotifications` for enforcement alerts even when popover is closed
4. **Settings window** — configure allowed dirs, sensitivity, notification preferences
5. **Signed .app bundle** — for distribution outside Homebrew
6. **Right-click menu** — quick toggle via NSStatusItem (requires AppKit bridge)
