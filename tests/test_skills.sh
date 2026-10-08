#!/bin/bash
# The SHARED:* blocks are duplicated across the swap and handoff skills and must stay byte-identical.
. "$(dirname "$0")/lib.sh"
for blk in RESERVED-WORDS PREFLIGHT-RECIPE; do
  a=$(sed -n "/SHARED:$blk BEGIN/,/SHARED:$blk END/p" "$REPO/skills/handoff/SKILL.md")
  b=$(sed -n "/SHARED:$blk BEGIN/,/SHARED:$blk END/p" "$REPO/skills/swap/SKILL.md")
  if [ "$blk" = PREFLIGHT-RECIPE ]; then
    # the swap skill carries the recipe as plain numbered lines under its own heading
    a=$(printf '%s\n' "$a" | grep '^[0-9]\.')
    b=$(sed -n '/^## Preflight recipe/,/^## /p' "$REPO/skills/swap/SKILL.md" | grep '^[0-9]\.')
  fi
  [ -n "$a" ] && [ "$a" = "$b" ] && pass || fail "SHARED:$blk differs between skills"
done
finish
