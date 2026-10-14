#!/bin/bash
# swap-guard server-retry: opt-in, only server_error/overloaded, wakes with exit 2,
# at most 3 tries per session per hour, and is registered by the installer's fragment.
. "$(dirname "$0")/lib.sh"
new_home
export SWAP_RETRY_DELAYS="0 0 0"
B="$HOME/.claude-swap-backup"
ev() { printf '{"session_id":"%s","hook_event_name":"StopFailure","error":"%s"}' "$1" "$2"; }
run() { ev "$1" "$2" | "$SG" server-retry --hook 2>"$HOME/err"; rc=$?; }

run s1 server_error
assert_eq "$rc" "0" "off by default: no retry"
assert_eq "$("$SG" server-retry status | jq -r .serverRetry)" "false" "status says off"
"$SG" server-retry on >/dev/null
run s1 server_error
assert_eq "$rc" "2" "server_error → wake the session (exit 2)"
assert_contains "$(cat "$HOME/err")" "automatic retry 1 of 3" "with a message that counts the tries"
assert_absent "$(cat "$HOME/err")" "stop and tell the user" "an early try doesn't tell Claude to give up"
run s1 overloaded
assert_eq "$rc" "2" "overloaded → wake too"
run s1 rate_limit
assert_eq "$rc" "0" "rate_limit is not this hook's (instant swap handles it)"
run s1 authentication_failed
assert_eq "$rc" "0" "auth errors are never retried"
run s1 server_error
assert_contains "$(cat "$HOME/err")" "retry 3 of 3" "third try"
assert_contains "$(cat "$HOME/err")" "last automatic retry" "the last try tells Claude to stop if it fails again"
run s1 server_error
assert_eq "$rc" "0" "a fourth failure within the hour gives up (no loop)"
assert_contains "$(tail -n 1 "$B/auto.log")" '"gave-up"' "and logs it"
run s2 server_error
assert_eq "$rc" "2" "the cap is per session"
printf '%s\n%s\n%s\n' "$(( $(date +%s) - 4000 ))" "$(( $(date +%s) - 3700 ))" "$(( $(date +%s) - 3601 ))" > "$B/ctx/s3.retry"
run s3 server_error
assert_eq "$rc" "2" "tries older than an hour don't count"
assert_eq "$(wc -l < "$B/ctx/s3.retry" | tr -d ' ')" "1" "and are dropped"
ev s4 server_error | SWAP_RETRY_DELAYS="1 1 1" "$SG" server-retry --hook 2>/dev/null; t0=$?
assert_eq "$t0" "2" "waits before waking (delay honored)"
printf '{"session_id":"../../x","error":"server_error"}' | "$SG" server-retry --hook 2>/dev/null
assert_eq "$([ -e "$B/x.retry" ] || [ -e "$HOME/x.retry" ] && echo leaked || echo ok)" "ok" "session id cannot escape the state dir"
# The session moved on while the hook waited (asyncRewake: the user can type) → no late "continue".
tp="$HOME/t.jsonl"; echo x > "$tp"; touch -t 202001010000 "$tp"
( printf '{"session_id":"s6","error":"server_error","transcript_path":"%s"}' "$tp" | SWAP_RETRY_GRACE=0 SWAP_RETRY_DELAYS="4 4 4" "$SG" server-retry --hook 2>/dev/null; echo $? > "$HOME/rc6" ) &
# Touch it only once the hook is waiting (it logs "retrying" first), a second later.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do grep -q '"session":"s6"' "$B/auto.log" 2>/dev/null && break; sleep 0.2; done
sleep 1; echo y >> "$tp"; wait
assert_eq "$(cat "$HOME/rc6")" "0" "transcript grew during the wait → no wake"
assert_contains "$(tail -n 1 "$B/auto.log")" '"session-moved-on"' "and logs why"
touch -t 202001010000 "$tp"
( printf '{"session_id":"s8","error":"server_error","transcript_path":"%s"}' "$tp" | SWAP_RETRY_DELAYS="2 2 2" "$SG" server-retry --hook 2>/dev/null; echo $? > "$HOME/rc8" ) &
sleep 1; echo z >> "$tp"; wait
assert_eq "$(cat "$HOME/rc8")" "2" "a write right after the failure (inside the grace period) is Claude Code's own: still wakes"
touch -t 202001010000 "$tp"
printf '{"session_id":"s7","error":"server_error","transcript_path":"%s"}' "$tp" | SWAP_RETRY_DELAYS="1 1 1" "$SG" server-retry --hook 2>/dev/null
assert_eq "$?" "2" "an untouched transcript → wakes as before"
"$SG" server-retry off >/dev/null
run s5 server_error
assert_eq "$rc" "0" "off again → no retry"
f="$(jq -c '.hooks.StopFailure[] | select(.matcher == "server_error|overloaded") | .hooks[0] | {command, asyncRewake}' "$REPO/settings/settings-fragment.json")"
assert_eq "$f" '{"command":"~/.local/bin/swap-guard server-retry --hook","asyncRewake":true}' "fragment registers the hook with asyncRewake"

rm -rf "$HOME"
finish
