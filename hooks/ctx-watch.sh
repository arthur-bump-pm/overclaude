#!/usr/bin/env bash
# ctx-watch.sh — Claude Code UserPromptSubmit hook.
# Reads the statusline relay for this session and, when context usage
# crosses a new threshold, injects the handoff-offer note into the turn.
# Contract: always exit 0, silent on every error path, defensive jq
# parsing, no state writes on the /handoff | /swap skip path.
exec 2>/dev/null

# Thresholds (contract: variables at top).
T1=60
T2=75
T3=85

STATE_ROOT="$HOME/.claude-swap-backup"
CTX_DIR="$STATE_ROOT/ctx"

INPUT="$(cat)" || INPUT=""
command -v jq >/dev/null 2>&1 || exit 0

# Skip path FIRST — before any state read/write.
prompt="$(jq -r '.prompt // empty' <<<"$INPUT" 2>/dev/null)"
case "$prompt" in
    "/handoff"*|"/swap"*) exit 0 ;;
esac

session_id="$(jq -r '.session_id // empty' <<<"$INPUT" 2>/dev/null)"
[ -n "$session_id" ] || exit 0

# Relay pct (missing file / null / non-number -> silent exit).
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

changed=0

# Re-arm rule: if pct < fired-10 -> fired = highest threshold <= pct
# (else 0), and bannered = min(bannered, fired).
if [ "$pct" -lt $(( fired - 10 )) ]; then
    new_fired=0
    for t in "$T1" "$T2" "$T3"; do
        [ "$pct" -ge "$t" ] && new_fired=$t
    done
    fired=$new_fired
    [ "$bannered" -gt "$fired" ] && bannered=$fired
    changed=1
fi

# Fire: highest threshold T with pct >= T and T > fired.
T=0
for t in "$T1" "$T2" "$T3"; do
    [ "$pct" -ge "$t" ] && T=$t
done
if [ "$T" -gt "$fired" ]; then
    printf '%s\n' "[context-watch] Context is at ${pct}%. After fully completing the user's current request, tell them context is filling up and OFFER /handoff to continue in a fresh session. Do NOT invoke the handoff skill yourself unless the user explicitly accepts in their own message — an offer you made is not acceptance. If they decline or ignore the offer, drop the subject; this notice will re-appear at the next threshold."
    fired=$T
    changed=1
fi

# Persist only when something changed (atomic write).
if [ "$changed" -eq 1 ]; then
    mkdir -p "$CTX_DIR" || exit 0
    tmp="$state.tmp.$$"
    printf '{"fired":%d,"bannered":%d}\n' "$fired" "$bannered" > "$tmp" && mv -f "$tmp" "$state"
fi
exit 0
