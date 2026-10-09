#!/bin/bash
# Statusline: weekly-reset segment, other-accounts line, fallbacks.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 2
export SWAP_CLAUDE_JSON=/dev/null

# Account 1: reset passed + dead token + empty 5h block (the "empty field shifts
# columns" regression). Account 2 (active): healthy, resets in ~1d 6h.
cat > "$HOME/.claude-swap-backup/cache/usage.json" <<EOF
{"schemaVersion": 2, "accounts": {
  "1": {"lastError": "invalid_grant", "authDeadStrikes": 1, "fetchedAt": $(( $(date +%s) - 7200 )),
        "lastGood": {"five_hour": {},
                     "seven_day": {"pct": 85.0, "resets_at": "$(iso_in -3600)"},
                     "scoped": [{"name": "Fable", "pct": 100.0, "resets_at": "$(iso_in -3600)"}]}},
  "2": {"lastError": null, "authDeadStrikes": 0, "fetchedAt": $(date +%s),
        "lastGood": {"five_hour": {"pct": 11.0, "resets_at": "$(iso_in 3600)"},
                     "seven_day": {"pct": 41.0, "resets_at": "$(iso_in 110000)"},
                     "scoped": [{"name": "Fable", "pct": 34.0, "resets_at": "$(iso_in 110000)"}]}}}}
EOF

out=$(echo '{"model":{"display_name":"M"},"context_window":{"used_percentage":12}}' | bash "$SL" | strip_ansi)
l1=$(printf '%s\n' "$out" | sed -n 1p)
l2=$(printf '%s\n' "$out" | sed -n 2p)
l3=$(printf '%s\n' "$out" | sed -n 3p)

assert_contains "$l1" "👤 personal [2/2] ↻ " "line 1 shows active account + weekly reset"
assert_contains "$l1" "(1d 6h)" "weekly reset countdown"
assert_contains "$l2" "week [████░░░░░░] 41%" "week bar from cache"
assert_contains "$l3" "↳ work [1]" "other-account line present"
assert_contains "$l3" "5h n/a" "empty 5h block renders n/a (no column shift)"
assert_contains "$l3" "week 0%" "passed reset on inactive account shows 0%"
assert_contains "$l3" "⚠ relogin" "dead token flagged"
assert_contains "$l3" "(2h 0m old)" "staleness marker"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "3" "three lines with two accounts"

# Healthy other account must NOT be flagged (regression: tab-collapse shifted fetchedAt into 'dead').
write_seq 1
l3=$(echo '{}' | bash "$SL" | strip_ansi | sed -n 3p)
assert_contains "$l3" "↳ personal [2] 5h 11% · week 41% · Fable 34% ↻ " "healthy other account renders fully"
assert_absent "$l3" "relogin" "healthy account not flagged"
l1=$(echo '{}' | bash "$SL" | strip_ansi | sed -n 1p)
assert_contains "$l1" "↻ week reset — refreshing" "active account with passed reset"

# Hide flag
n=$(echo '{}' | SWAP_HIDE_OTHERS=1 bash "$SL" | wc -l | tr -d ' ')
assert_eq "$n" "2" "SWAP_HIDE_OTHERS=1 hides other-account lines"

# No cache: stdin resets_at (epoch seconds) is the fallback for line 1
rm -f "$HOME/.claude-swap-backup/cache/usage.json"
write_seq 2
out=$(echo "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":40,\"resets_at\":$(( $(date +%s) + 91800 ))}}}" | bash "$SL" | strip_ansi)
assert_contains "$(printf '%s\n' "$out" | sed -n 1p)" "(1d 1h)" "stdin resets_at fallback"
assert_contains "$(printf '%s\n' "$out" | sed -n 3p)" "(no usage data)" "other account without cache"

finish
