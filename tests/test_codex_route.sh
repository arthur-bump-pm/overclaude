#!/bin/bash
. "$(dirname "$0")/lib.sh"
new_home
write_seq 2
B="$HOME/.claude-swap-backup"; NOW="$(date +%s)"; FUT="$(iso_in 86400)"; PAST="$(iso_in -60)"
mkdir -p "$HOME/stub" "$HOME/.codex/hooks" "$HOME/.codex/sessions/a"
printf '#!/bin/bash\n[ -z "${LOGIN_FAIL:-}" ]\n' > "$HOME/stub/codex"; chmod +x "$HOME/stub/codex"; export PATH="$HOME/stub:$PATH"
touch "$HOME/.codex/hooks/overcodex-handoff-inject.sh"
roll() { printf '{"timestamp":"%s","payload":{"rate_limits":{"primary":{"used_percent":%s,"window_minutes":300,"resets_at":%s},"rate_limit_reached_type":null}}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$((NOW + 3600))" > "$HOME/.codex/sessions/a/rollout-test.jsonl"; }
cache() { cat > "$B/cache/usage.json" <<JSON
{"accounts":{"1":{"fetchedAt":${3:-$NOW},"lastGood":{"seven_day":{"pct":$1,"resets_at":"${4:-$FUT}"}}},"2":{"fetchedAt":$NOW,"lastGood":{"seven_day":{"pct":$2,"resets_at":"$FUT"}}}}}
JSON
}
route() { "$SG" codex-route | jq -r .route; }
hook() { printf '{"session_id":"%s","tool_name":"Bash"}' "$1" | "$SG" checkpoint --hook; }
roll 10
cache 96.9 97
assert_eq "$(route)" claude "96.9 keeps Claude"
cache 97 97
assert_eq "$(route)" codex "both at 97 authorize Codex"
rm "$HOME/.codex/hooks/overcodex-handoff-inject.sh"
assert_eq "$(route)" codex "automatic continuation does not require the handoff hook"
assert_eq "$("$SG" codex-ready | jq -r .ready)" false "manual readiness still requires the hook"
touch "$HOME/.codex/hooks/overcodex-handoff-inject.sh"
pending="$HOME/.codex/overcodex/handoff-pending-$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12).md"
mkdir -p "${pending%/*}"
printf '<!-- handoff cwd="%s" created="%s" -->\n' "$PWD" "$((NOW - 600))" > "$pending"
assert_eq "$(route)" codex "600-second-old header is stale even with fresh mtime"
printf '<!-- handoff cwd="%s" created="%s" -->\n' "$PWD" "$NOW" > "$pending"
touch -t "$(date -r "$((NOW - 1000))" +%Y%m%d%H%M.%S)" "$pending"
assert_eq "$(route)" claude "fresh header blocks despite old mtime"
printf '<!-- handoff cwd="%s" created="%s" -->\n' /wrong "$NOW" > "$pending"
touch -t "$(date -r "$((NOW - 1000))" +%Y%m%d%H%M.%S)" "$pending"
assert_eq "$(route)" codex "wrong cwd falls back to old mtime"
rm "$pending"; mkfifo "$pending"
assert_eq "$(route)" claude "FIFO pending blocks without hanging"
assert_eq "$("$SG" codex-ready | jq -r '.ready,.continuationReady' | tr '\n' ',')" "false,false," "FIFO blocks manual and continuation readiness"
assert_contains "$("$SG" codex-ready | jq -r .detail)" "cannot be safely inspected" "unsafe pending has clear detail"
rm "$pending"; ln -s /dev/null "$pending"
assert_eq "$(route)" claude "symlink pending blocks"
assert_eq "$("$SG" codex-ready | jq -r '.ready,.continuationReady' | tr '\n' ',')" "false,false," "symlink blocks manual and continuation readiness"
rm "$pending"
cache 98 96
assert_eq "$(route)" claude "one account below 97 keeps Claude"
cache 96 98
assert_contains "$(hook alt)" "swap-guard auto tick --threshold 97" "known alternative triggers guarded Claude switch guidance"
cache 98 98 "$((NOW - 181))"
assert_eq "$(route)" claude "stale successful fetch keeps Claude"
# Successful scheduled observations remain distinct from fresh data and bounded.
for age in 300 600; do
  cache 98 98 "$((NOW - age))"
  jq --argjson n "$((NOW + 100))" '.accounts["1"].nextPollAt=$n | .accounts["1"].consecutiveFailures=0' "$B/cache/usage.json" > "$HOME/u"; mv "$HOME/u" "$B/cache/usage.json"
  assert_eq "$(route)" codex "scheduled success at age $age remains trusted"
  assert_eq "$("$SG" codex-route | jq -r '.accounts[] | select(.slot=="1") | [.fresh,.freshnessReason] | join(":")')" false:scheduled "scheduled age $age is not called fresh"
done
cache 98 98 "$((NOW - 661))"
jq --argjson n "$((NOW + 100))" '.accounts["1"].nextPollAt=$n' "$B/cache/usage.json" > "$HOME/u"; mv "$HOME/u" "$B/cache/usage.json"
assert_eq "$(route)" claude "scheduled evidence older than 660 seconds blocks"
cache 98 98 "$((NOW - 300))"
assert_eq "$(route)" claude "stale evidence without plan blocks"
jq --argjson n "$((NOW + 100))" '.accounts["1"].nextPollAt=$n | .accounts["1"].lastError="http-429" | .accounts["1"].consecutiveFailures=1' "$B/cache/usage.json" > "$HOME/u"; mv "$HOME/u" "$B/cache/usage.json"
assert_eq "$(route)" claude "failed fetch blocks scheduled trust"
cache 98 98 "$((NOW + 60))"
assert_eq "$(route)" claude "future observation blocks"
cache 98 98
jq '.accounts["1"].email="replacement@example.com"' "$B/cache/usage.json" > "$HOME/u"; mv "$HOME/u" "$B/cache/usage.json"
assert_eq "$(route)" claude "mismatched account identity blocks"
cache 98 98
jq '.accounts["1"].organizationUuid="new-org"' "$B/sequence.json" > "$HOME/q"; mv "$HOME/q" "$B/sequence.json"
jq '.accounts["1"].email="work@example.com" | .accounts["1"].organizationUuid="old-org"' "$B/cache/usage.json" > "$HOME/u"; mv "$HOME/u" "$B/cache/usage.json"
assert_eq "$(route)" claude "same email with different organization blocks trust"
assert_eq "$("$SG" codex-route | jq -r '.accounts[] | select(.slot=="1") | .freshnessReason')" unknown "organization mismatch is unknown"
write_seq 2
cache 98 98 "$NOW" "$PAST"
assert_eq "$(route)" claude "past reset keeps Claude"
cache 98 98
jq 'del(.accounts["1"].lastGood.seven_day.pct)' "$B/cache/usage.json" > "$HOME/u"; mv "$HOME/u" "$B/cache/usage.json"
assert_eq "$(route)" claude "missing usage keeps Claude"
cache 98 98
assert_eq "$(LOGIN_FAIL=1 route)" claude "failed login keeps Claude"
roll 100
assert_eq "$(route)" claude "known Codex exhaustion keeps Claude"
roll 10
rm "$HOME/.codex/sessions/a/rollout-test.jsonl"
assert_eq "$(route)" codex "unknown Codex usage is allowed with successful login"
assert_eq "$("$SG" codex-route | jq -r .codex.limitsKnown)" false "unknown Codex limits are explicit"
roll 10
cache 96 97
hook s1 >/dev/null
cache 97 97
assert_contains "$(hook s1)" "/handoff codex auto" "97 crosses independently of checkpoint band"
assert_eq "$(hook s1)" "" "notice deduplicated"
for state in "$B"/ctx/s1.codex-route-codex-*; do printf '%s\n' "$((NOW - 301))" > "$state"; done
assert_contains "$(hook s1)" "/handoff codex auto" "notice retries after cooldown"
assert_absent "$(printf '{"session_id":"s1"}' | "$SG" budget --hook)" "/handoff codex auto" "dedup shared with budget"
assert_absent "$(printf '{"session_id":"s2","agent_id":"a"}' | "$SG" checkpoint --hook)" "/handoff codex auto" "subagents never receive route notice"
assert_absent "$(CLAUDE_CODE_OAUTH_TOKEN=x hook s3)" "/handoff codex auto" "token jobs never receive route notice"
# Non-subscription slots must not prevent the two subscription accounts routing.
jq '.accounts["3"]={disabled:true} | .accounts["4"]={kind:"api_key"}' "$B/sequence.json" > "$HOME/q"
mv "$HOME/q" "$B/sequence.json"
assert_eq "$(route)" codex "disabled and API-key slots do not block exhausted subscriptions"
jq '.accounts["3"].disabled=false' "$B/sequence.json" > "$HOME/q"
mv "$HOME/q" "$B/sequence.json"
assert_eq "$(route)" claude "enabled account with missing usage blocks fallback"
write_seq 2
jq '.accounts["1"].disabled=true' "$B/sequence.json" > "$HOME/q"
mv "$HOME/q" "$B/sequence.json"
assert_eq "$(route)" claude "one enabled subscription does not qualify for multi-account policy"
# Hooks request a normal, debounced refresh without changing the cached evidence.
write_seq 2
cache 99 99 "$((NOW - 200))"
mkdir -p "$HOME/bin"
cat > "$HOME/bin/cswap" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/refresh-calls"
exit 1
STUB
chmod +x "$HOME/bin/cswap"; export PATH="$HOME/bin:$PATH"
assert_eq "$(SWAP_NO_REFRESH= "$SG" codex-route | jq -r .route)" claude "read-only route fails closed on stale evidence"
[ ! -f "$HOME/refresh-calls" ] && pass || fail "read-only route never starts refresh"
SWAP_NO_REFRESH= hook refresh1 >/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$HOME/refresh-calls" ] && break; sleep 0.1; done
assert_eq "$(cat "$HOME/refresh-calls" 2>/dev/null)" "list --json" "stale hook requests normal cswap list"
SWAP_NO_REFRESH= hook refresh2 >/dev/null
assert_eq "$(wc -l < "$HOME/refresh-calls" | tr -d ' ')" 1 "failed refresh is debounced across hooks"
assert_eq "$(route)" claude "failed refresh never makes stale evidence fresh"
# Even an old timestamp cannot break a live advisory lock or launch another cswap.
printf '%s\n' "$((NOW - 1000))" > "$B/cache/.usage-refresh.at"
python3 -c 'import fcntl,sys,time; f=open(sys.argv[1],"a"); fcntl.flock(f,fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(3)' "$B/cache/.usage-refresh.flock" "$HOME/lock-ready" & holder=$!
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$HOME/lock-ready" ] && break; sleep 0.1; done
SWAP_NO_REFRESH= hook refresh3 >/dev/null
sleep 0.3
assert_eq "$(wc -l < "$HOME/refresh-calls" | tr -d ' ')" 1 "live advisory lock blocks another refresh despite old stamp"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null || :
# A same-email organization mismatch independently requests a refresh.
cache 99 99
jq '.accounts["1"].organizationUuid="new-org"' "$B/sequence.json" > "$HOME/q"; mv "$HOME/q" "$B/sequence.json"
jq '.accounts["1"].email="work@example.com" | .accounts["1"].organizationUuid="old-org"' "$B/cache/usage.json" > "$HOME/u"; mv "$HOME/u" "$B/cache/usage.json"
SWAP_NO_REFRESH= hook refresh4 >/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(wc -l < "$HOME/refresh-calls" | tr -d ' ')" -ge 2 ] && break; sleep 0.1; done
assert_eq "$(wc -l < "$HOME/refresh-calls" | tr -d ' ')" 2 "organization mismatch requests a refresh"


write_seq 2
for invalid in missing malformed; do
  printf '%s\n' "$((NOW - 1000))" > "$B/cache/.usage-refresh.at"
  if [ "$invalid" = missing ]; then rm -f "$B/cache/usage.json"; else printf '{broken' > "$B/cache/usage.json"; fi
  before="$(wc -l < "$HOME/refresh-calls" | tr -d ' ')"
  assert_eq "$(route)" claude "$invalid cache cannot authorize Codex"
  SWAP_NO_REFRESH= hook "refresh-$invalid" >/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10; do [ "$(wc -l < "$HOME/refresh-calls" | tr -d ' ')" -gt "$before" ] && break; sleep 0.1; done
  assert_eq "$(wc -l < "$HOME/refresh-calls" | tr -d ' ')" "$((before + 1))" "$invalid cache triggers refresh from hook"
done
# Terminating the refresh worker must clean a TERM-resistant descendant before unlocking.
cat > "$HOME/bin/cswap" <<'STUB'
#!/usr/bin/env python3
import os, signal, subprocess, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(os.path.join(os.environ["HOME"], "long-calls"), "a") as f:
    f.write(str(os.getppid()) + "\n")
child = subprocess.Popen(["python3", "-c", "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)"])
with open(os.path.join(os.environ["HOME"], "long-child"), "w") as f:
    f.write(str(child.pid))
child.wait()
STUB
chmod +x "$HOME/bin/cswap"
printf '%s\n' "$((NOW - 1000))" > "$B/cache/.usage-refresh.at"
SWAP_NO_REFRESH= hook refresh-signal >/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do [ -s "$HOME/long-child" ] && break; sleep 0.1; done
worker="$(head -n 1 "$HOME/long-calls")"; descendant="$(cat "$HOME/long-child")"
kill -TERM "$worker"
printf '%s\n' "$((NOW - 1000))" > "$B/cache/.usage-refresh.at"
SWAP_NO_REFRESH= hook refresh-signal2 >/dev/null
sleep 0.5
assert_eq "$(wc -l < "$HOME/long-calls" | tr -d ' ')" 1 "terminated worker keeps lock during child cleanup"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do kill -0 "$descendant" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$descendant" 2>/dev/null; then fail "termination cleans resistant descendant"; kill -KILL "$descendant" 2>/dev/null || :; else pass; fi
rm -rf "$HOME"
finish
