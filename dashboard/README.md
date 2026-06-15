# Sentry Web Dashboard

Lightweight local web dashboard for Agentic Sentry.

## Stack

- **Backend**: Python Flask — wraps existing shell scripts (`sentry-status.sh`, `sentry-selfguard.sh`) and parses JSON-lines audit logs directly.
- **Frontend**: HTMX + Tailwind CSS — partial updates with zero JS framework overhead.
- **Port**: 7777 (configurable via `PORT` env var)

## Quick Start

```bash
cd dashboard
pip install -r requirements.txt
python app.py
# → http://localhost:7777
```

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /api/status` | Full system status (components, health, violations, logs) |
| `GET /api/violations` | Violation summary + recent events from audit log |
| `GET /api/selfguard` | Selfguard baseline and meta-hash chain status |
| `GET /api/health` | Health score (0–100) with issues list |
| `GET /api/components` | Background component running status |
| `GET /api/logs?type=audit&limit=50` | Raw log entries (audit, enforcement, selfguard) |
| `GET /stream/logs` | SSE stream for live log tailing |

## HTMX Partials

The dashboard auto-refreshes sections at different intervals:
- Health score: every 10s
- Components: every 10s
- Violations: every 15s
- Selfguard: every 30s
- Recent events: every 5s

## Design Philosophy

- No database — reads directly from log files and shell script output
- No build step — CDN-loaded Tailwind + HTMX
- No JS framework — server-rendered HTML fragments
- Matches the project's "no heavy frameworks" constraint
