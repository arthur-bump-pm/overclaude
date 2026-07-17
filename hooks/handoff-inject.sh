#!/usr/bin/env bash
# handoff-inject.sh — Claude Code SessionStart hook (matcher: startup).
# Injects a pending handoff package for this cwd into the new session's
# context, then archives it. Contract: always exit 0, silent on every
# error path, defensive jq parsing, tolerate missing state root.
exec 2>/dev/null

STATE_ROOT="$HOME/.claude-swap-backup"
ARCHIVE_DIR="$STATE_ROOT/handoff-archive"
PENDING_TTL=600

INPUT="$(cat)" || INPUT=""
command -v jq >/dev/null 2>&1 || exit 0

cwd="$(jq -r '.cwd // empty' <<<"$INPUT" 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"

# Pending-file path: swap-guard is the canonical resolver; fall back to the
# shared-constants hash (identical result) if it is unavailable.
P=""
if command -v swap-guard >/dev/null 2>&1; then
    P="$(swap-guard path handoff --cwd "$cwd" 2>/dev/null)"
elif [ -x "$HOME/.local/bin/swap-guard" ]; then
    P="$("$HOME/.local/bin/swap-guard" path handoff --cwd "$cwd" 2>/dev/null)"
fi
if [ -z "$P" ]; then
    h="$(printf '%s' "$cwd" | /usr/bin/shasum -a 256 | awk '{print $1}' | cut -c1-12)"
    [ -n "$h" ] || exit 0
    P="$STATE_ROOT/handoff-pending-$h.md"
fi

[ -f "$P" ] || exit 0

# Line 1 must be: <!-- handoff cwd="<abs>" created="<epoch-int>" -->
header="$(head -n 1 "$P")"
emb_cwd="$(printf '%s' "$header" | sed -n 's/^<!-- handoff cwd="\(.*\)" created="[0-9][0-9]*" -->[[:space:]]*$/\1/p')"
emb_created="$(printf '%s' "$header" | sed -n 's/^<!-- handoff cwd=".*" created="\([0-9][0-9]*\)" -->[[:space:]]*$/\1/p')"

# Malformed header -> leave file, silent.
{ [ -n "$emb_cwd" ] && [ -n "$emb_created" ]; } || exit 0

# cwd mismatch -> leave file, silent.
[ "$emb_cwd" = "$cwd" ] || exit 0

now="$(date +%s)"
age=$(( now - emb_created ))

# Archive name: <YYYYmmdd-HHMMSS>-<HASH>.md (UTC); hash taken from filename.
base="${P##*/}"
fhash="${base#handoff-pending-}"
fhash="${fhash%.md}"
ts="$(date -u +%Y%m%d-%H%M%S)"

if [ "$age" -ge "$PENDING_TTL" ]; then
    # Expired -> archive with -expired suffix, no output.
    mkdir -p "$ARCHIVE_DIR" && mv -f "$P" "$ARCHIVE_DIR/$ts-$fhash-expired.md"
    exit 0
fi

# Claim first (atomic mv), then print from the archived path — prevents a
# concurrent same-cwd startup from injecting a dangling header after losing
# the race for the pending file.
A="$ARCHIVE_DIR/$ts-$fhash.md"
{ mkdir -p "$ARCHIVE_DIR" && mv "$P" "$A"; } 2>/dev/null || exit 0
printf '%s\n\n' "## Handoff from previous session (loaded by handoff-inject)"
tail -n +2 "$A"
exit 0
