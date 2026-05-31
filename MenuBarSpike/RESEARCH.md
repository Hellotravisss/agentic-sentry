# macOS Menu Bar Tool — Research & Recommendation

## Task
Choose the best approach for a macOS menu bar companion app for Agentic Sandbox Sentry.
Options: SwiftUI, Swift + AppKit, or Go + Wails.

## Context
- Project is a lightweight shell-based macOS security tool
- Philosophy: "no heavy dependencies, macOS native, pure local rules"
- Menu bar app should show: status indicator, violation count, recent events, quick actions (enable/disable, open dashboard, run status check)
- Must feel native and lightweight

---

## Option 1: SwiftUI (MenuBarExtra) — RECOMMENDED

**Availability:** macOS 13+ (Ventura), fully mature on macOS 15+
**Approach:** `MenuBarExtra` scene with SwiftUI views

### Pros
- **Native & lightweight** — single Swift binary, no runtime deps
- **Declarative UI** — fast to build and iterate
- **First-class menu bar support** — `MenuBarExtra` gives you the status item + popover for free
- **Small binary** — ~2-5 MB stripped
- **Modern** — Apple's recommended path forward
- **No Xcode required** — builds with `swift build` from SPM
- **Matches project philosophy** — zero external deps, pure Apple frameworks

### Cons
- Requires macOS 13+ (Ventura) — but we're on macOS 26, so no issue
- Less granular control over NSStatusItem behavior (animation, right-click menus) compared to AppKit
- MenuBarExtra had bugs in early macOS 13, but stable since 14+

### Code complexity
~150 lines for a functional menu bar app with popover, status indicator, and action buttons.

---

## Option 2: Swift + AppKit (NSStatusItem)

**Availability:** All macOS versions
**Approach:** `NSStatusItem` with manual `NSPopover` or `NSMenu`

### Pros
- **Maximum control** — full access to NSStatusBar, custom views, animations
- **Works on any macOS version** — back to 10.x
- **Mature** — well-documented, battle-tested for decades
- **Same binary size** as SwiftUI approach

### Cons
- **More verbose** — imperative code, delegate patterns, ~2-3x more lines
- **Slower to iterate** — manual layout, no previews
- **Legacy feel** — Apple is investing in SwiftUI, AppKit is in maintenance mode
- **Overkill** for a status indicator + popover

### Code complexity
~400+ lines for equivalent functionality. More boilerplate, harder to maintain.

---

## Option 3: Go + Wails

**Availability:** Cross-platform (macOS, Windows, Linux)
**Approach:** Go backend + web frontend (HTML/CSS/JS) rendered in a WebView

### Pros
- **Cross-platform** — same codebase for macOS/Windows/Linux
- **Web UI skills** — frontend devs can contribute
- **Go backend** — could integrate with existing Go tooling if any

### Cons
- **Heavy runtime** — Wails embeds a WebView, binary ~20-40 MB
- **Not truly native** — looks and feels like a web app in a window
- **Menu bar support is second-class** — Wails is designed for windowed apps; menu bar mode requires hacks or the `v2/sysTray` binding which is limited
- **External dependency** — Wails framework, Node.js for frontend build
- **Violates project philosophy** — "lightweight, no heavy dependencies"
- **Go not used elsewhere** in the project (pure shell + fswatch)
- **Wails not installed** on this machine

### Code complexity
High setup overhead (Wails init, frontend scaffolding, binding generation). ~500+ lines across Go + JS/HTML/CSS.

---

## Recommendation: SwiftUI

| Criterion | SwiftUI | AppKit | Go + Wails |
|---|---|---|---|
| Binary size | ~3 MB | ~3 MB | ~30 MB |
| External deps | None | None | Wails, Node.js |
| Dev speed | Fast | Medium | Slow (setup) |
| Native feel | Yes | Yes | No (WebView) |
| macOS 13+ | Required | Not required | Not required |
| Menu bar quality | Excellent | Excellent | Poor/Hacked |
| Project fit | Perfect | Good | Poor |

**SwiftUI wins on every axis that matters for this project.** We're on macOS 26, the project is macOS-only, and the philosophy is lightweight + native. SwiftUI's `MenuBarExtra` gives us a polished menu bar app in ~150 lines with zero dependencies.

AppKit is the fallback if we ever need pixel-perfect control over the status item (custom animations, right-click context menus beyond what SwiftUI offers), but for a status + popover + actions pattern, SwiftUI is sufficient.

Go + Wails is eliminated: wrong tool for a macOS-native menu bar app, violates the lightweight philosophy, and menu bar support is a hack.

---

## Spike
See `MenuBarSpike/` — a working SwiftUI MenuBarExtra prototype that:
- Shows a shield icon in the menu bar (green = safe, red = enforcement active)
- Popover with: status, violation count, health score, recent events
- Action buttons: Run Status Check, Open Dashboard, Disable Sentry, Quit
- Builds with `swift build` (no Xcode project needed)
- Reads live data from sentryctl/sentry-status.sh via Process calls
