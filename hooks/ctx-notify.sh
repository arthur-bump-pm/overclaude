#!/usr/bin/env bash
# ctx-notify.sh — Claude Code Stop hook.
# Passive banner: when context usage sits in a threshold band that has not
# been bannered yet, emit {"systemMessage": ...}. NEVER emits a "decision"
# field. Contract: always exit 0, silent on every error path, defensive
# jq parsing, no-op when stop_hook_active.
exec 2>/dev/null

# Thresholds.
T1=60
T2=75
T3=85

STATE_ROOT="$HOME/.claude-swap-backup"
CTX_DIR="$STATE_ROOT/ctx"

INPUT="$(cat)" || INPUT=""
command -v jq >/dev/null 2>&1 || exit 0

# Never act on our own stop cycle.
sha="$(jq -r '.stop_hook_active // false' <<<"$INPUT" 2>/dev/null)"
[ "$sha" = "true" ] && exit 0

session_id="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)"
[ -n "$session_id" ] || exit 0

# Relay pct (missing -> silent exit).
relay="$CTX_DIR/$session_id.json"
[ -f "$relay" ] || exit 0
pct_raw="$(jq -r 'if (.pct|type) == "number" then .pct else empty end' "$relay" 2>/dev/null)"
[ -n "$pct_raw" ] || exit 0
pct="$(awk -v p="$pct_raw" 'BEGIN { printf "%d", p }')"
case "$pct" in ''|*[!0-9]*) exit 0 ;; esac

# State (missing/corrupt -> fired=0 bannered=0).
state="$CTX_DIR/$session_id.state"
fired=0
bannered=0
if [ -f "$state" ]; then
    f="$(jq -r '.fired // 0' "$state" 2>/dev/null)"
    b="$(jq -r '.bannered // 0' "$state" 2>/dev/null)"
    case "$f" in 0|60|75|85) fired=$f ;; esac
    case "$b" in 0|60|75|85) bannered=$b ;; esac
fi

# band = highest threshold <= pct (0 if < 60).
band=0
for t in "$T1" "$T2" "$T3"; do
    [ "$pct" -ge "$t" ] && band=$t
done

if [ "$pct" -ge "$T1" ] && [ "$band" -gt "$bannered" ]; then
    printf '{"systemMessage":"context %d%% — /handoff available"}\n' "$pct"
    mkdir -p "$CTX_DIR" || exit 0
    tmp="$state.tmp.$$"
    printf '{"fired":%d,"bannered":%d}\n' "$fired" "$band" > "$tmp" && mv -f "$tmp" "$state"
fi
exit 0
