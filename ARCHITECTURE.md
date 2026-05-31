Agentic Sandbox Sentry (智能体多宿主物理环境安全断路器)
Lightweight macOS-Native Real-Time Command Auditing Architecture

NOTE (2025 update): Implementation has diverged from this early design document.
- The project uses pure shell + fswatch (no Python policy/monitor files were ultimately created).
- Major hardening added later: real `kill -STOP` process suspension with auto-resume,
  mandatory one-time restore code + interactive confirmation, and bypass detection for common
  subshell / one-liner evasion techniques.
See REVIEW_AND_SUGGESTIONS.md for current status.

TARGET
- Real-time auditing of remote AI-controlled Terminal (zsh/bash) sessions
- Detect: `rm` outside allowed dirs, sensitive file/key access (e.g. ~/.ssh, ~/.aws, private keys)
- Latency: <100ms local detection, no second LLM pass
- Constraints: pure script (shell + Python stdlib), open-source, zero heavy frameworks/deps, macOS-native, kernel-script friendly

CHOSEN TECH STACK (lightweight, no external deps beyond macOS + std Python 3)
- Primary: zsh `preexec` + `precmd` hooks (or bash `trap DEBUG` + `PROMPT_COMMAND`)
- Command interception + policy engine: pure zsh/bash functions + Python stdlib (os, re, subprocess, time, json, pathlib)
- File/process monitoring fallback: macOS `fswatch` (if present, optional) OR pure Python `os.scandir` + `psutil` no - avoid psutil; use `pgrep`/`lsof` via subprocess + polling (tunable 50ms)
- Logging: append-only JSONL to /tmp/sandbox-audit.log (or $HOME/.sandbox)
- Alerting: stdout + optional macOS `osascript` notification (native, instant)
- No: auditd full config, dtrace, fsevents Python bindings, watchdog, any pip packages

WHY THIS IS LIGHTWEIGHT & KERNEL-SCRIPT FRIENDLY
- Hooks run in the same shell process (zero IPC for command capture)
- Preexec executes before command, decision <10ms (simple path checks)
- Python daemon only for background file watch (optional, stdlib only)
- macOS native: uses built-in zsh (default shell), /bin/bash, osascript, no kernel modules or kexts
- Scriptable: everything is plain .zshrc snippet + single .py file (<200 LOC)
- Open-source friendly: MIT, no compiled binaries, works on stock macOS + Python 3.9+
- <100ms guarantee: hook path is synchronous in shell; file monitor uses 50ms poll or fswatch event-driven when available

DATA FLOW
1. AI Terminal starts (remote session assumed to use zsh)
   - .zshrc sources sandbox-hooks.zsh (injected at session start or via env)
2. Every command:
   - preexec hook captures full command line + cwd
   - Python policy check (via `python3 -c` inline or small helper) OR pure zsh glob/path matching:
     - If `rm` and target outside ALLOWED_DIRS (e.g. ~/safe-zone) → block + log + alert
     - If command touches SENSITIVE_PATHS (~/.*ssh*, ~/.aws, id_rsa, etc.) → log + warn
   - Decision made in <50ms, command either proceeds or is replaced with `echo "BLOCKED: ..."`
3. Background (optional lightweight daemon):
   - python3 sandbox-monitor.py (launched once per user, or per session)
   - Uses fswatch (if `which fswatch`) or 50ms loop with `find` + `stat` on watched dirs
   - On violation event → immediate append to audit log + osascript alert
4. Audit log (JSONL):
   {"ts": "...", "session": "ai-123", "cmd": "rm -rf /tmp/foo", "cwd": "/Users/travis", "decision": "BLOCKED", "reason": "outside_allowed"}
5. Termination: session end runs precmd cleanup, daemon exits cleanly on SIGTERM

CORE COMPONENTS (all files in repo root)
- sandbox-hooks.zsh          # 40-line zsh preexec/precmd policy engine
- sandbox-hooks.bash         # equivalent for bash (trap DEBUG)
- sandbox-policy.py          # 80-line pure stdlib policy checker (importable or -c)
- sandbox-monitor.py         # 120-line optional file watcher (fswatch or poll)
- sandbox-config.sh          # env vars: ALLOWED_DIRS, SENSITIVE_PATHS, AUDIT_LOG
- install.sh                 # one-liner to append hook sourcing to .zshrc

DETECTION RULES (hardcoded in policy, no LLM)
- rm / rmdir / unlink outside ALLOWED_DIRS → immediate block
- cat / less / head / openssl on *.pem, id_*, .env, credentials → log + alert
- ssh-keygen, chmod 600 on private keys outside safe dir → alert
- Any command with `sudo` or targeting /etc, /System, /Library/Keychains → block

PERFORMANCE
- Hook overhead: <5ms per command (zsh native)
- Path check: O(1) glob + realpath (Python or zsh)
- File monitor poll: 50ms worst-case (configurable)
- Memory: <10MB for Python daemon
- No network, no model loading, fully offline

INSTALL / ACTIVATION (for remote AI sessions)
1. scp the 6 files to remote mac
2. source sandbox-config.sh; ./install.sh
3. Start AI terminal session (it inherits hooks)
4. Optional: launchctl or nohup sandbox-monitor.py &

This architecture meets all constraints: pure scripts, <100ms, macOS-native, no heavy frameworks, suitable for kernel-level script injection via shell rc files.