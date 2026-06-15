"""
Agentic Sentry — Web Dashboard
Lightweight Flask + HTMX dashboard showing system status, violations, and selfguard health.

Usage:
    cd dashboard
    pip install -r requirements.txt
    python app.py                   # http://localhost:7777
    PORT=8080 python app.py         # custom port

Design: wraps existing shell scripts (sentry-status.sh, sentry-selfguard.sh)
and parses the JSON-lines audit log directly. No extra daemons or DBs needed.
"""

import json
import os
import subprocess
import re
from datetime import datetime
from pathlib import Path
from flask import Flask, render_template, jsonify, request, Response

app = Flask(__name__)

# Resolve paths relative to this file
DASHBOARD_DIR = Path(__file__).resolve().parent
PROJECT_DIR = DASHBOARD_DIR.parent
SENTRY_HOME = Path(os.environ.get("SENTRY_HOME", Path.home() / ".hermes"))

# Log file resolution (matches sentry-status.sh logic)
AUDIT_LOG = SENTRY_HOME / "logs" / "sandbox-audit.log"
if not AUDIT_LOG.exists():
    _fallback = Path("/tmp/sandbox-audit.log")
    if _fallback.exists():
        AUDIT_LOG = _fallback

ENFORCE_LOG = SENTRY_HOME / "logs" / "enforcement.log"
SELFGUARD_LOG = SENTRY_HOME / "logs" / "selfguard.log"
BASELINE_FILE = SENTRY_HOME / "sentry-baseline.sha256"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _run_script(script: str, args: list[str] | None = None, timeout: int = 10) -> tuple[str, int]:
    """Run a project shell script and return (stdout, returncode)."""
    cmd = ["/bin/bash", str(PROJECT_DIR / script)]
    if args:
        cmd.extend(args)
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
            cwd=str(PROJECT_DIR),
        )
        return result.stdout, result.returncode
    except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError) as e:
        return str(e), 1


def _parse_audit_log(limit: int = 200) -> list[dict]:
    """Parse the JSON-lines audit log, returning the last `limit` entries."""
    if not AUDIT_LOG.exists():
        return []
    try:
        lines = AUDIT_LOG.read_text().strip().splitlines()
        entries = []
        for line in lines[-limit:]:
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                continue
        return entries
    except Exception:
        return []


def _violation_summary(entries: list[dict]) -> dict:
    """Compute summary stats from parsed audit log entries."""
    total = len(entries)
    blocked = sum(1 for e in entries if "BLOCK" in e.get("decision", "") or "HARD" in e.get("decision", ""))
    detected = sum(1 for e in entries if e.get("decision") == "DETECTED")
    hard = sum(1 for e in entries if "HARD" in e.get("decision", ""))

    # Severity breakdown
    critical = sum(1 for e in entries if e.get("severity") == "critical")
    warning = sum(1 for e in entries if e.get("severity") == "warning")
    info = sum(1 for e in entries if e.get("severity") == "info")

    # Top reasons
    reason_counts: dict[str, int] = {}
    for e in entries:
        r = e.get("reason", "unknown")
        reason_counts[r] = reason_counts.get(r, 0) + 1
    top_reasons = sorted(reason_counts.items(), key=lambda x: -x[1])[:10]

    # Top commands
    cmd_counts: dict[str, int] = {}
    for e in entries:
        c = e.get("cmd", "")[:80]
        if c:
            cmd_counts[c] = cmd_counts.get(c, 0) + 1
    top_commands = sorted(cmd_counts.items(), key=lambda x: -x[1])[:10]

    # Time range
    first_ts = entries[0].get("ts", "") if entries else ""
    last_ts = entries[-1].get("ts", "") if entries else ""

    return {
        "total": total,
        "blocked": blocked,
        "detected": detected,
        "hard_enforcement": hard,
        "critical": critical,
        "warning": warning,
        "info": info,
        "top_reasons": [{"reason": r, "count": c} for r, c in top_reasons],
        "top_commands": [{"cmd": c, "count": n} for c, n in top_commands],
        "first_event": first_ts,
        "last_event": last_ts,
    }


def _component_status() -> dict:
    """Check running status of background components."""
    def _pgrep(pattern: str) -> str | None:
        try:
            r = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True, timeout=5)
            if r.returncode == 0 and r.stdout.strip():
                return r.stdout.strip().splitlines()[0]
        except Exception:
            pass
        return None

    fswatch_pid = _pgrep("sandbox-monitor.fswatch.sh")
    egress_pid = _pgrep("egress-watcher")

    # Selfguard PID check
    sg_pid_file = SENTRY_HOME / "logs" / "selfguard.pid"
    selfguard_pid = None
    if sg_pid_file.exists():
        try:
            pid = sg_pid_file.read_text().strip()
            if pid:
                # Check if process is alive
                check = subprocess.run(["kill", "-0", pid], capture_output=True, timeout=3)
                if check.returncode == 0:
                    selfguard_pid = pid
        except Exception:
            pass

    # launchd
    launchd_loaded = False
    try:
        r = subprocess.run(["launchctl", "list"], capture_output=True, text=True, timeout=5)
        launchd_loaded = "agentsentry" in r.stdout
    except Exception:
        pass

    # fswatch binary
    fswatch_installed = subprocess.run(["which", "fswatch"], capture_output=True, timeout=3).returncode == 0
    jq_installed = subprocess.run(["which", "jq"], capture_output=True, timeout=3).returncode == 0

    return {
        "fswatch_monitor": {"running": fswatch_pid is not None, "pid": fswatch_pid},
        "selfguard": {"running": selfguard_pid is not None, "pid": selfguard_pid},
        "egress_watcher": {"running": egress_pid is not None, "pid": egress_pid},
        "launchd": {"loaded": launchd_loaded},
        "fswatch_binary": {"installed": fswatch_installed},
        "jq": {"installed": jq_installed},
    }


def _selfguard_health() -> dict:
    """Check selfguard baseline and meta-hash chain status."""
    result = {
        "baseline_exists": BASELINE_FILE.exists(),
        "baseline_age": None,
        "baseline_files": 0,
        "meta_file_exists": False,
        "metahash_file_exists": False,
        "chain_verified": False,
        "last_verify_result": None,
    }

    if BASELINE_FILE.exists():
        try:
            stat = BASELINE_FILE.stat()
            result["baseline_age"] = datetime.fromtimestamp(stat.st_mtime).isoformat()
            lines = BASELINE_FILE.read_text().strip().splitlines()
            result["baseline_files"] = sum(1 for l in lines if l and not l.startswith("#"))
        except Exception:
            pass

    meta_file = SENTRY_HOME / "sentry-baseline.sha256.meta"
    metahash_file = SENTRY_HOME / "sentry-baseline.sha256.metahash"
    result["meta_file_exists"] = meta_file.exists()
    result["metahash_file_exists"] = metahash_file.exists()

    # Quick verify
    if BASELINE_FILE.exists() and meta_file.exists() and metahash_file.exists():
        try:
            stdout, rc = _run_script("sentry-selfguard.sh", ["verify"], timeout=15)
            result["chain_verified"] = rc == 0
            result["last_verify_result"] = stdout[:500]
        except Exception:
            pass

    return result


def _compute_health_score(components: dict, selfguard: dict) -> dict:
    """Compute overall health score (0-100)."""
    score = 100
    issues = []

    if not components["fswatch_monitor"]["running"]:
        score -= 15
        issues.append("fswatch monitor not running")
    if not components["selfguard"]["running"]:
        score -= 10
        issues.append("selfguard monitor not running")
    if not components["egress_watcher"]["running"]:
        score -= 5
        issues.append("egress watcher not running (optional)")
    if not components["launchd"]["loaded"]:
        score -= 5
        issues.append("launchd agent not loaded")
    if not components["fswatch_binary"]["installed"]:
        score -= 25
        issues.append("fswatch binary not installed")
    if not components["jq"]["installed"]:
        score -= 5
        issues.append("jq not installed")
    if not selfguard["baseline_exists"]:
        score -= 10
        issues.append("integrity baseline not created")
    elif not selfguard.get("chain_verified"):
        score -= 15
        issues.append("integrity chain not verified")

    score = max(0, score)

    if score >= 80:
        level = "healthy"
    elif score >= 50:
        level = "degraded"
    else:
        level = "critical"

    return {"score": score, "level": level, "issues": issues}


def _log_stats() -> dict:
    """Get size and line counts for all log files."""
    stats = {}
    for name, path in [("audit", AUDIT_LOG), ("enforcement", ENFORCE_LOG), ("selfguard", SELFGUARD_LOG)]:
        if path.exists():
            try:
                text = path.read_text()
                lines = len(text.strip().splitlines())
                size = path.stat().st_size
                # Count rotated files
                rotated = len(list(path.parent.glob(f"{path.name}.*")))
                stats[name] = {
                    "path": str(path),
                    "lines": lines,
                    "size_bytes": size,
                    "size_human": f"{size // 1024}KB" if size > 1024 else f"{size}B",
                    "rotated_files": rotated,
                }
            except Exception:
                stats[name] = {"path": str(path), "error": "unreadable"}
        else:
            stats[name] = {"path": str(path), "exists": False}
    return stats


# ---------------------------------------------------------------------------
# Routes: HTML pages
# ---------------------------------------------------------------------------

@app.route("/")
def index():
    """Main dashboard page."""
    return render_template("index.html")


# ---------------------------------------------------------------------------
# Routes: JSON API
# ---------------------------------------------------------------------------

@app.route("/api/status")
def api_status():
    """Full system status as JSON."""
    components = _component_status()
    selfguard = _selfguard_health()
    health = _compute_health_score(components, selfguard)
    logs = _log_stats()
    entries = _parse_audit_log(limit=50)
    violations = _violation_summary(entries)

    return jsonify({
        "timestamp": datetime.now().isoformat(),
        "host": os.uname().nodename,
        "project_dir": str(PROJECT_DIR),
        "sentry_home": str(SENTRY_HOME),
        "components": components,
        "selfguard": selfguard,
        "health": health,
        "logs": logs,
        "violations": violations,
    })


@app.route("/api/violations")
def api_violations():
    """Violation data from the audit log."""
    limit = request.args.get("limit", 200, type=int)
    entries = _parse_audit_log(limit=limit)
    summary = _violation_summary(entries)

    # Recent entries (last 20)
    recent = entries[-20:] if entries else []

    return jsonify({
        "summary": summary,
        "recent_events": recent,
    })


@app.route("/api/selfguard")
def api_selfguard():
    """Selfguard health status."""
    return jsonify(_selfguard_health())


@app.route("/api/health")
def api_health():
    """Health score."""
    components = _component_status()
    selfguard = _selfguard_health()
    health = _compute_health_score(components, selfguard)
    return jsonify(health)


@app.route("/api/components")
def api_components():
    """Component running status."""
    return jsonify(_component_status())


@app.route("/api/logs")
def api_logs():
    """Recent log entries."""
    log_type = request.args.get("type", "audit")
    limit = request.args.get("limit", 50, type=int)

    path_map = {"audit": AUDIT_LOG, "enforcement": ENFORCE_LOG, "selfguard": SELFGUARD_LOG}
    log_path = path_map.get(log_type, AUDIT_LOG)

    if not log_path or not log_path.exists():
        return jsonify({"entries": [], "count": 0})

    try:
        lines = log_path.read_text().strip().splitlines()
        entries = []
        for line in lines[-limit:]:
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                entries.append({"raw": line})
        return jsonify({"entries": entries, "count": len(entries), "log_type": log_type})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


# ---------------------------------------------------------------------------
# Routes: HTMX partials (return HTML fragments)
# ---------------------------------------------------------------------------

@app.route("/partials/health")
def partial_health():
    """HTMX partial: health score badge."""
    components = _component_status()
    selfguard = _selfguard_health()
    health = _compute_health_score(components, selfguard)
    return render_template("partials/health.html", health=health)


@app.route("/partials/components")
def partial_components():
    """HTMX partial: component status table."""
    components = _component_status()
    return render_template("partials/components.html", components=components)


@app.route("/partials/violations")
def partial_violations():
    """HTMX partial: violation summary + recent events."""
    entries = _parse_audit_log(limit=200)
    summary = _violation_summary(entries)
    recent = entries[-20:] if entries else []
    return render_template("partials/violations.html", summary=summary, recent=recent)


@app.route("/partials/selfguard")
def partial_selfguard():
    """HTMX partial: selfguard status."""
    sg = _selfguard_health()
    return render_template("partials/selfguard.html", sg=sg)


@app.route("/partials/logs")
def partial_logs():
    """HTMX partial: recent log entries."""
    entries = _parse_audit_log(limit=20)
    recent = entries[-10:] if entries else []
    return render_template("partials/logs.html", entries=list(reversed(recent)))


# ---------------------------------------------------------------------------
# SSE (Server-Sent Events) for live log streaming
# ---------------------------------------------------------------------------

@app.route("/stream/logs")
def stream_logs():
    """SSE endpoint for live log streaming."""
    def generate():
        if not AUDIT_LOG.exists():
            yield f"data: {json.dumps({'type': 'info', 'message': 'No audit log yet'})}\n\n"
            return

        # Start from end of file
        import time
        last_pos = AUDIT_LOG.stat().st_size

        while True:
            time.sleep(1)
            if not AUDIT_LOG.exists():
                continue
            current_size = AUDIT_LOG.stat().st_size
            if current_size > last_pos:
                with open(AUDIT_LOG, "r") as f:
                    f.seek(last_pos)
                    new_lines = f.read().strip().splitlines()
                    for line in new_lines:
                        try:
                            entry = json.loads(line)
                            yield f"data: {json.dumps(entry)}\n\n"
                        except json.JSONDecodeError:
                            continue
                last_pos = current_size

    return Response(generate(), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 7777))
    host = os.environ.get("HOST", "127.0.0.1")
    debug = os.environ.get("FLASK_DEBUG", "0") == "1"

    display_host = "localhost" if host in {"127.0.0.1", "localhost"} else host
    print(f"\n  Agentic Sentry Dashboard")
    print(f"  http://{display_host}:{port}\n")
    app.run(host=host, port=port, debug=debug)
