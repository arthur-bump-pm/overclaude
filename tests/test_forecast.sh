#!/bin/bash
# swap-guard forecast: reads cswap's usage cache only, estimates the pace from the
# last week, simulates 7 days drawing on the soonest-resetting account with room,
# and names the account to use first. Statusline: "⏳ use first" and run-out warning.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 2
B="$HOME/.claude-swap-backup"
NOW="$(date +%s)"
iso() { date -u -r $(( NOW + $1 )) '+%Y-%m-%dT%H:%M:%S.000000+00:00'; }
usage() { # usage <p1> <reset1-in> <p2> <reset2-in> [extra-json-for-1]
  cat > "$B/cache/usage.json" <<EOF
{"schemaVersion": 2, "accounts": {
  "1": {"fetchedAt": $NOW, "lastError": null, "authDeadStrikes": 0 ${5:-},
        "lastGood": {"five_hour": {"pct": 0}, "seven_day": {"pct": $1, "resets_at": "$(iso "$2")"},
                     "scoped": [{"name": "Fable", "pct": $1, "resets_at": "$(iso "$2")"}]}},
  "2": {"fetchedAt": $(( NOW - 30000 )), "lastError": null, "authDeadStrikes": 0,
        "lastGood": {"five_hour": {"pct": 20, "resets_at": "$(iso 3600)"}, "seven_day": {"pct": $3, "resets_at": "$(iso "$4")"},
                     "scoped": [{"name": "Fable", "pct": 10, "resets_at": "$(iso "$4")"}]}}}}
EOF
}

# work (1): untouched, week resets in 90 min. personal (2, active): 70%, resets in 2 days.
usage 0 5400 70 172800
out="$("$SG" forecast)"
assert_eq "$(printf '%s' "$out" | jq -r '.week.useFirst | "\(.slot) \(.active) \(.room)"')" "1 false 100" "use first: the account with room that resets soonest"
assert_eq "$(printf '%s' "$out" | jq -r '.week.runsOutAt')" "null" "at this pace the week lasts"
assert_eq "$(printf '%s' "$out" | jq -r '.week.ratePerHour')" "0.58" "pace = 70% over the 120 h its window has run"
assert_eq "$(printf '%s' "$out" | jq -r '.week.accountWeeksPerWeek')" "1" "≈ one account's week per week"
assert_eq "$(printf '%s' "$out" | jq -r '.week.detail[] | select(.slot == "1") | .unusedAtReset >= 95')" "true" "most of work's room resets unused (90 min at this pace)"
assert_eq "$(printf '%s' "$out" | jq -r '.week.detail[] | select(.slot == "2") | .ageHours')" "8" "each account's data age"
assert_eq "$(jq -r '.week.useFirst.slot' "$B/cache/forecast.json")" "1" "the forecast is cached for the statusline"
txt="$("$SG" forecast --text)"
assert_contains "$txt" "Weekly limit: lasts the next 7 days" "text: verdict"
assert_contains "$txt" "use first: work — 100% left, resets in 1h " "text: the use-first account"
assert_contains "$txt" "Fable limit:" "and the Fable limit too"
assert_contains "$txt" "(numbers 8h old)" "old numbers are marked"
assert_contains "$txt" "--strategy consume-first" "points at the automatic way"

# Heavy pace, little room → runs out within hours.
usage 90 432000 95 432000
out="$("$SG" forecast)"
r="$(printf '%s' "$out" | jq -r '.week.runsOutAt')"
case "$r" in ''|null|*[!0-9]*) fail "runs out: expected a time" "$r";; *)
  assert_le "$(( r - NOW ))" $(( 5 * 3600 )) "185% used in 48 h, 15% left → out within hours"
  assert_le $(( 3 * 3600 )) "$(( r - NOW ))" "but not instantly";; esac

# A week whose reset already passed is empty again; dead / ending logins don't count.
usage 80 -60 70 172800
assert_eq "$("$SG" forecast | jq -r '.week.detail[] | select(.slot == "1") | "\(.pct) \(.resetsAt > '"$NOW"')"')" "0 true" "reset passed → 0% used, next reset ahead"
usage 0 5400 70 172800 ',"lastError":"invalid_grant"'
assert_eq "$("$SG" forecast | jq -r '[.week.detail[].slot] | join(",")')" "2" "a dead login doesn't count"
usage 0 5400 70 172800
printf '{"checkedAt":%s,"accounts":[{"slot":"1","endsAt":%s}]}' "$NOW" "$(( NOW + 600 ))" > "$B/cache/logins.json"
assert_eq "$("$SG" forecast | jq -r '.week.useFirst.slot')" "2" "nor one whose login ends within hours"
rm -f "$B/cache/logins.json"

# Usage with no reset time still counts toward the pace.
cat > "$B/cache/usage.json" <<EOF
{"schemaVersion":2,"accounts":{"1":{"fetchedAt":$NOW,"lastGood":{"seven_day":{"pct":50,"resets_at":null}}},
 "2":{"fetchedAt":$NOW,"lastGood":{"seven_day":{"pct":0,"resets_at":"$(iso 100000)"}}}}}
EOF
assert_eq "$("$SG" forecast | jq -r '.week.ratePerHour > 0')" "true" "50% used without a reset time → pace above zero"
cat > "$B/cache/usage.json" <<EOF
{"schemaVersion":2,"accounts":{"1":{"fetchedAt":$NOW,"lastGood":{"seven_day":{"pct":50,"resets_at":null}}},
 "2":{"fetchedAt":$NOW,"lastGood":{"seven_day":{"pct":10,"resets_at":"$(iso $(( 604800 - 36000 )))"}}}}}
EOF
assert_eq "$("$SG" forecast | jq -r '.week.ratePerHour')" "1.3" "mixed: 10% over its 10 h window + 50% over a full week = 1.0 + 0.3"
# Everything excluded → says so instead of printing nothing.
usage 0 5400 70 172800 ',"lastError":"invalid_grant"'
jq '.accounts["2"].lastError = "invalid_grant"' "$B/cache/usage.json" > "$HOME/u" && mv "$HOME/u" "$B/cache/usage.json"
assert_contains "$("$SG" forecast --text)" "No account to forecast" "all accounts excluded → a clear line"

# Unknown cache format or no data → a clear error, nothing guessed.
jq '.schemaVersion = 3' "$B/cache/usage.json" > "$HOME/u" && mv "$HOME/u" "$B/cache/usage.json"
out="$("$SG" forecast)"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .error)" "1:no-data" "an unknown cache format is not read"

# A control character in an alias can't turn into code.
usage 0 5400 70 172800
jq --arg a "$(printf 'x\0371\037now[$(touch %s)]' "$HOME/pwned")" '.accounts["1"].alias = $a' "$B/sequence.json" > "$HOME/s" && cp "$HOME/s" "$B/sequence.json"
"$SG" forecast --text >/dev/null 2>&1
assert_eq "$([ -e "$HOME/pwned" ] && echo ran || echo no)" "no" "a crafted alias never runs"
write_seq 2

# Statusline: "⏳ use first" on work's line; not once it has little room left.
export SWAP_CLAUDE_JSON=/dev/null
sl="$(echo '{"model":{"display_name":"M"}}' | bash "$SL" | strip_ansi)"
assert_contains "$(printf '%s\n' "$sl" | grep '↳ work')" "⏳ use first" "statusline: use work first"
usage 80 5400 70 172800
sl="$(echo '{"model":{"display_name":"M"}}' | bash "$SL" | strip_ansi)"
assert_absent "$sl" "use first" "not when it has under 30% left"
usage 0 259200 70 172800
sl="$(echo '{"model":{"display_name":"M"}}' | bash "$SL" | strip_ansi)"
assert_absent "$sl" "use first" "nor when it resets after the active account"
printf '{"asOf":%s,"week":{"runsOutAt":%s}}' "$NOW" "$(( NOW + 10800 ))" > "$B/cache/forecast.json"
sl="$(echo '{"model":{"display_name":"M"}}' | bash "$SL" | strip_ansi)"
assert_contains "$(printf '%s\n' "$sl" | sed -n 2p)" "⚠ accounts out ~" "line 2 warns when every account runs out within a day"
printf '{"asOf":%s,"week":{"runsOutAt":%s}}' "$NOW" "$(( NOW + 200000 ))" > "$B/cache/forecast.json"
sl="$(echo '{"model":{"display_name":"M"}}' | bash "$SL" | strip_ansi)"
assert_absent "$sl" "accounts out" "not when it's days away"

rm -rf "$HOME"
finish
