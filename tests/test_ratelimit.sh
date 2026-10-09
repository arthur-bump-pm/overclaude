#!/bin/bash
# swap-guard ratelimit (StopFailure hook): instant swap on a usage cap, against a stub cswap.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 2

STUB="$HOME/stubbin"; mkdir -p "$STUB"
cat > "$STUB/cswap" <<'EOF'
#!/bin/bash
case "$1" in
  list)   printf '%s\n' "$STUB_LIST" ;;
  switch) echo "switch $2" >> "$HOME/switched"
          if [ -n "${STUB_NOOP:-}" ]; then echo '{"switched":false,"reason":"already-active"}'; else echo '{"switched":true}'; fi
          exit "${STUB_SW_RC:-0}" ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$STUB/cswap"
export PATH="$STUB:$PATH"

FUT="$(iso_in 86400)"; PAST="$(iso_in -60)"
acct() { # acct <n> <alias> <status> <5h> <week> <fable> [fable-reset] [extra-json]
  printf '{"number":%s,"email":"%s@example.com","alias":"%s","active":%s,"usageStatus":"%s","usage":{"fiveHour":{"pct":%s,"resetsAt":"%s"},"sevenDay":{"pct":%s,"resetsAt":"%s"},"scoped":[{"name":"Fable","pct":%s,"resetsAt":"%s"}]}%s}' \
    "$1" "$2" "$2" "$([ "$1" = 2 ] && echo true || echo false)" "$3" "$4" "$FUT" "$5" "$FUT" "$6" "${7:-$FUT}" "${8:-}"
}
list_of() { printf '{"activeAccountNumber":2,"accounts":[%s]}' "$(IFS=,; echo "$*")"; }
CAP="You've reached your Fable limit · resets Thu 09:00"
hit() { # hit <sid> <message> [error] — run the hook, capture rc + stderr
  rm -f "$HOME/stderr"
  printf '{"session_id":"%s","error":"%s","last_assistant_message":"%s"}' "$1" "${3:-rate_limit}" "$2" |
    "$SG" ratelimit --no-notify 2> "$HOME/stderr"; rc=$?
}
switches() { cat "$HOME/switched" 2>/dev/null | tr '\n' ';'; }
lastlog() { tail -n 1 "$HOME/.claude-swap-backup/auto.log" | jq -r "$1"; }
reset_state() { rm -f "$HOME/switched" "$HOME/.claude-swap-backup/ratelimit-last.json" "$HOME/.claude-swap-backup/ratelimit-capped.json" "$HOME/.claude-swap-backup/ctx/"*.rlwake; }

export STUB_LIST="$(list_of "$(acct 1 work ok 10 20 5)" "$(acct 2 personal ok 40 60 100)")"

hit s1 "API Error: Rate limit reached"
assert_eq "$(switches)" "" "transient 429 never switches"
assert_eq "$(lastlog .reason)" "transient-429" "transient 429 logged as ignored"

hit s1 "$CAP" overloaded
assert_eq "$(switches)" "" "a non-rate-limit error is ignored"

hit s1 "$CAP"
assert_eq "$(switches)" "switch 1;" "usage cap → switched to the account with room"
assert_eq "$rc" "2" "exit 2 wakes the stopped session (asyncRewake)"
assert_contains "$(cat "$HOME/stderr")" "switched from personal to work" "wake text names both accounts"
assert_contains "$(cat "$HOME/stderr")" "Fable 5%" "wake text includes the limit that triggered"
assert_eq "$(lastlog .model)" "Fable" "the capped model is parsed from the message"
assert_eq "$(jq -r .to "$HOME/.claude-swap-backup/ratelimit-last.json")" "1" "last swap recorded"

hit s2 "$CAP"
assert_eq "$(switches)" "switch 1;" "a second session within the cooldown reuses the swap"
assert_eq "$(lastlog .action)" "reused" "reuse is logged"
assert_eq "$rc" "2" "the second session is woken too"

# Loop guard: same session, cooldown over, still capped → switch again but no second wake.
jq '.ts = 1' "$HOME/.claude-swap-backup/ratelimit-last.json" > "$HOME/t" && mv "$HOME/t" "$HOME/.claude-swap-backup/ratelimit-last.json"
hit s1 "$CAP"
assert_eq "$rc" "0" "a session is woken at most once per 10 minutes"

reset_state
"$SG" auto instant off >/dev/null
hit s1 "$CAP"
assert_eq "$(switches)" "" "instant swap off → no switch"
assert_eq "$(lastlog .reason)" "instant-swap-off" "off is logged"
assert_eq "$("$SG" auto instant status | jq -r .instantSwap)" "false" "instant status reports off"
"$SG" auto instant on >/dev/null

reset_state
STUB_LIST="$(list_of "$(acct 1 work ok 10 20 100)" "$(acct 2 personal ok 40 60 100)")" hit s1 "$CAP"
assert_eq "$(switches)" "" "every other account capped on that model → no switch"
assert_eq "$(lastlog .reason)" "no-account-with-room" "no room is logged"

reset_state
STUB_LIST="$(list_of "$(acct 1 work ok 10 20 100 "$PAST")" "$(acct 2 personal ok 40 60 100)")" hit s1 "$CAP"
assert_eq "$(switches)" "switch 1;" "a window whose reset passed counts as empty"

reset_state
STUB_LIST="$(list_of "$(acct 1 work relogin_required 0 0 0)" "$(acct 3 side ok 50 50 50 "" ',"disabled":true')" "$(acct 4 api api_key 0 0 0)" "$(acct 2 personal ok 40 60 100)")" hit s1 "$CAP"
assert_eq "$(switches)" "" "dead, disabled and API-key accounts are never targets"

reset_state
STUB_LIST="$(list_of "$(acct 1 work ok 10 90 5)" "$(acct 3 side ok 10 30 5)" "$(acct 2 personal ok 40 60 100)")" hit s1 "$CAP"
assert_eq "$(switches)" "switch 3;" "the account with the most room wins"

reset_state
STUB_SW_RC=1 hit s1 "$CAP"
assert_eq "$(lastlog .action)" "error" "a failed switch is logged as an error"
assert_eq "$rc" "0" "a failed switch never wakes the session"

reset_state
NOSCOPE='{"number":1,"email":"work@example.com","alias":"work","active":false,"usageStatus":"ok","usage":{"fiveHour":{"pct":10},"sevenDay":{"pct":20},"scoped":[]}}'
STUB_LIST="$(list_of "$NOSCOPE" "$(acct 3 side ok 50 50 5)" "$(acct 2 personal ok 40 60 100)")" hit s1 "$CAP"
assert_eq "$(switches)" "switch 1;" "an account with no data for that model still counts (as 0%), not dropped"

reset_state
STUB_NOOP=1 hit s1 "$CAP"
assert_eq "$(lastlog .action)" "error" "cswap's switched:false no-op is not reported as a switch"
assert_eq "$rc" "0" "a no-op switch never wakes the session"

# No ping-pong: after work capped on Fable, a later cap elsewhere must not hop back onto work.
reset_state
hit s1 "$CAP"
assert_eq "$(jq -r '.[0].slot' "$HOME/.claude-swap-backup/ratelimit-capped.json")" "2" "the capped account is remembered until its reset"
rm -f "$HOME/switched" "$HOME/.claude-swap-backup/ratelimit-last.json" "$HOME/.claude-swap-backup/ctx/"*.rlwake
echo '[{"slot":"1","model":"Fable","until":9999999999}]' > "$HOME/.claude-swap-backup/ratelimit-capped.json"
hit s3 "$CAP"
assert_eq "$(switches)" "" "an account still capped on that model is never a target, whatever the cache says"

reset_state
out=$(printf '{"session_id":"s1","error":"rate_limit","last_assistant_message":"%s"}' "$CAP" | "$SG" ratelimit --dry-run --print --no-notify)
assert_eq "$(printf '%s' "$out" | jq -r .action)" "would-switch" "dry run reports the decision"
assert_eq "$(switches)" "" "dry run never switches"

rm -rf "$HOME"
finish
