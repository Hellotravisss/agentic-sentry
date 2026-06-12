#!/bin/bash
# sentry-rate.sh - Repetition (retry-loop) detection — threat model T9
#
# Agents stuck in retry loops re-run the same command over and over,
# burning API budget and tool quota without new evidence. No single
# repetition is dangerous, so per-command rules never fire; this tracks
# command frequency in a sliding window instead.
#
# Signal-only by design: callers LOG the detection (decision RATE_REPEAT),
# they never block on it — re-running tests is a normal workflow.
#
#   sentry_rate_check <command>
#     Records the command and returns 0 exactly when the repetition count
#     CROSSES the threshold (once per window, so callers don't spam logs),
#     setting SENTRY_RATE_REASON. Returns 1 otherwise.
#
# Tunables (env or values in sentry-config.json take effect via env):
#   SENTRY_RATE_WINDOW     seconds of sliding window   (default 600)
#   SENTRY_RATE_THRESHOLD  repeats that trigger        (default 8)
#   SENTRY_RATE_FILE       state file                  (default $SENTRY_HOME/logs/.recent-commands)
#
# Works when sourced from bash or zsh.

sentry_rate_check() {
    local cmd="${1:-}"
    SENTRY_RATE_REASON=""
    [[ -z "$cmd" ]] && return 1

    local window="${SENTRY_RATE_WINDOW:-600}"
    local threshold="${SENTRY_RATE_THRESHOLD:-8}"
    local state_home="${SENTRY_HOME:-$HOME/.agentsentry}"
    local state_file="${SENTRY_RATE_FILE:-$state_home/logs/.recent-commands}"

    mkdir -p "$(dirname "$state_file")" 2>/dev/null || return 1

    local now sig
    now=$(date +%s)
    # cksum is fast and available everywhere; collisions just merge counts,
    # which at worst surfaces a repeat warning slightly early.
    sig=$(printf '%s' "$cmd" | cksum 2>/dev/null | awk '{print $1"-"$2}') || return 1

    echo "$now $sig" >> "$state_file" 2>/dev/null || return 1

    local cutoff=$(( now - window ))
    local count
    count=$(awk -v c="$cutoff" -v s="$sig" '$1 >= c && $2 == s' "$state_file" 2>/dev/null | wc -l | tr -d ' ')

    # Opportunistic prune so the state file cannot grow unbounded
    local lines
    lines=$(wc -l < "$state_file" 2>/dev/null | tr -d ' ')
    if [[ "${lines:-0}" -gt 1000 ]]; then
        local tmp="${state_file}.prune.$$"
        awk -v c="$cutoff" '$1 >= c' "$state_file" > "$tmp" 2>/dev/null \
            && mv "$tmp" "$state_file" 2>/dev/null \
            || rm -f "$tmp" 2>/dev/null
    fi

    # Fire exactly at the crossing, not on every repeat after it
    if [[ "$count" -eq "$threshold" ]]; then
        SENTRY_RATE_REASON="REPEAT: same command run ${count}x in the last $(( window / 60 )) min (possible agent retry loop)"
        return 0
    fi
    return 1
}
