#!/bin/bash
# swap-guard prewarm: off by default; inside the keepalive tick, one tiny message per
# idle account (no window running, week room, a long-lived token, not pinged in 5 h),
# run through `token run` (token in the environment, never argv) from an empty folder.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 2            # 1 = work (idle), 2 = personal (active)
B="$HOME/.claude-swap-backup"
NOW="$(date +%s)"
SECRET="sk-ant-oat01-PREWARMsecret"
iso() { date -u -r $(( NOW + $1 )) '+%Y-%m-%dT%H:%M:%S.000000+00:00'; }

STUB="$HOME/stubbin"; mkdir -p "$STUB"
cat > "$STUB/cswap" <<'EOF'
#!/bin/bash
[ "$1 $2" = "list --json" ] && echo '{"activeAccountNumber":2,"accounts":[{"number":1,"email":"work@example.com","usageStatus":"ok"},{"number":2,"email":"personal@example.com","active":true,"usageStatus":"ok"}]}'
EOF
cat > "$STUB/security" <<EOF
#!/bin/bash
case "\$*" in *find-generic-password*overclaude-token*work@example.com*|*find-generic-password*work@example.com*overclaude-token*) printf '%s' "$SECRET";; *) exit 44;; esac
EOF
# claude stub: records its args, folder and whether a token arrived (never the value).
cat > "$STUB/claude" <<'EOF'
#!/bin/bash
{ echo "ARGS $*"; echo "PWD $PWD"; echo "TOKEN ${CLAUDE_CODE_OAUTH_TOKEN:+set}"; } >> "$HOME/claude-calls"
[ -f "$HOME/claude-slow" ] && exec sleep 20
exit "${STUB_CLAUDE_RC:-0}"
EOF
printf '#!/bin/bash\necho "$*" >> "$HOME/notified"\n' > "$STUB/osascript"
chmod +x "$STUB"/*
export PATH="$STUB:$PATH" SWAP_GUARD_NO_LAUNCHCTL=1
echo '{"work@example.com":{"created":1,"expires":9999999999}}' > "$B/tokens.json"
usage() { # usage <work five_hour json> <work week pct> [fetched-ago]
  cat > "$B/cache/usage.json" <<EOF
{"schemaVersion":2,"accounts":{
 "1":{"fetchedAt":$(( NOW - ${3:-60} )),"lastError":null,"authDeadStrikes":0,"lastGood":{"five_hour":$1,"seven_day":{"pct":$2,"resets_at":"$(iso 300000)"}}},
 "2":{"fetchedAt":$NOW,"lastError":null,"authDeadStrikes":0,"lastGood":{"five_hour":{"pct":20,"resets_at":"$(iso 3600)"},"seven_day":{"pct":50,"resets_at":"$(iso 200000)"}}}}}
EOF
}
usage '{"pct":0}' 10

"$SG" keepalive tick >/dev/null
assert_eq "$([ -f "$HOME/claude-calls" ] && echo pinged || echo no)" "no" "off by default: the keepalive tick sends nothing"
assert_eq "$("$SG" prewarm tick)" "[]" "and prewarm tick does nothing while off"
assert_eq "$("$SG" prewarm tick --dry-run | jq -c '[.[] | .result]')" '["would-ping","skip:active"]' "--dry-run shows what it would do"

out="$("$SG" prewarm on)"
assert_eq "$(printf '%s' "$out" | jq -r .prewarm)" "true" "prewarm on"
out="$("$SG" keepalive tick)"
assert_eq "$(printf '%s' "$out" | jq -c '.prewarm')" '[{"slot":"1","label":"work","result":"ok"},{"slot":"2","label":"personal","result":"skip:active"}]' "the tick pings the idle account, never the active one"
args="$(grep '^ARGS' "$HOME/claude-calls")"
assert_contains "$args" "-p Reply with only the word: ok --model haiku" "a one-word prompt on the cheapest model"
assert_contains "$args" '--settings {"disableAllHooks":true}' "hooks off"
assert_contains "$args" "--strict-mcp-config --no-session-persistence" "no MCP servers, nothing saved"
assert_contains "$args" '--tools  --max-turns 1 --permission-prompts none' "no tools, one turn, nothing may prompt"
assert_eq "$(grep -c '^TOKEN set' "$HOME/claude-calls")" "1" "the token arrives in the environment"
assert_absent "$args$(cat "$B/keepalive.log")" "$SECRET" "never on the command line or in the log"
pwd_used="$(grep '^PWD' "$HOME/claude-calls" | cut -c5-)"
assert_contains "$pwd_used" "/.claude-swap-backup/prewarm." "run from a private folder in overclaude's state dir (no shared /tmp ancestors)"
assert_eq "$([ -d "$pwd_used" ] && echo left || echo removed)" "removed" "the empty folder is removed after"

rm -f "$HOME/claude-calls"
assert_eq "$("$SG" prewarm tick | jq -r '.[0].result')" "skip:pinged-recently" "once per 5 hours"
rm -f "$B"/prewarm-stamp-*
usage "{\"pct\":3,\"resets_at\":\"$(iso 7200)\"}" 10
assert_eq "$("$SG" prewarm tick | jq -r '.[0].result')" "skip:window-running" "a window already running is left alone"
usage '{"pct":0}' 95
assert_eq "$("$SG" prewarm tick | jq -r '.[0].result')" "skip:week-nearly-used" "no point with the week nearly used"
usage '{"pct":0}' 10 20000
assert_eq "$("$SG" prewarm tick | jq -r '.[0].result')" "skip:no-recent-usage" "old usage numbers: can't tell if a window runs"
usage '{"pct":0}' 10
printf '{"checkedAt":%s,"accounts":[{"slot":"1","email":"work@example.com","endsAt":%s}]}' "$NOW" "$(( NOW + 600 ))" > "$B/cache/logins.json"
assert_eq "$("$SG" prewarm tick | jq -r '.[0].result')" "skip:login-ending" "nor a login about to end"
rm -f "$B/cache/logins.json"
echo '{}' > "$B/tokens.json"
assert_eq "$("$SG" prewarm tick | jq -r '.[0].result')" "skip:no-token" "no long-lived token → skipped"
assert_eq "$("$SG" prewarm status | jq -r '.accounts[0].reason')" "no-token" "and status says so"
echo '{"work@example.com":{"created":1,"expires":9999999999}}' > "$B/tokens.json"
[ -f "$HOME/claude-calls" ] && fail "no message sent for skipped accounts" "$(cat "$HOME/claude-calls")" || pass

STUB_CLAUDE_RC=1 "$SG" prewarm tick > "$HOME/o.json"
assert_eq "$(jq -r '.[0].result' "$HOME/o.json")" "failed" "a failed ping is reported"
assert_eq "$("$SG" prewarm tick | jq -r '.[0].result')" "skip:pinged-recently" "and waits the same 5 hours (no retry storm)"
rm -f "$B"/prewarm-stamp-*; touch "$HOME/claude-slow"; t0="$(date +%s)"
SWAP_PREWARM_TIMEOUT=1 "$SG" prewarm tick > "$HOME/o.json"
assert_le "$(( $(date +%s) - t0 ))" 5 "a hung ping is cut off"
assert_eq "$(jq -r '.[0].result' "$HOME/o.json")" "failed" "and counts as failed"
rm -f "$HOME/claude-slow"

# A command that can't start is a failure, not "ok".
rm -f "$B"/prewarm-stamp-*
PATH="$(printf '%s' "$PATH" | sed "s|$STUB:||")" "$SG" prewarm tick > "$HOME/o.json" 2>/dev/null
assert_eq "$(jq -r '.[0].result' "$HOME/o.json")" "failed" "no claude to run → failed (never a false ok)"
# A relative $0 (run from the repo) still finds itself after the cd into the empty folder.
rm -f "$B"/prewarm-stamp-* "$HOME/claude-calls"
(cd "$REPO" && bash bin/swap-guard prewarm tick > "$HOME/o.json")
assert_eq "$(jq -r '.[0].result' "$HOME/o.json"):$(grep -c '^ARGS' "$HOME/claude-calls" 2>/dev/null)" "ok:1" "a relative path to swap-guard still sends the ping"

touch "$B/prewarm-stamp-x\"}"
assert_eq "$("$SG" prewarm status 2>&1 | jq -r '.accounts[0].reason')" "pinged-recently" "an oddly named stamp file is ignored (prewarm keeps working)"
rm -f "$B/prewarm-stamp-x\"}"

"$SG" prewarm off >/dev/null
rm -f "$B"/prewarm-stamp-* "$HOME/claude-calls"
"$SG" keepalive tick >/dev/null
assert_eq "$([ -f "$HOME/claude-calls" ] && echo pinged || echo no)" "no" "off again → nothing sent"
echo '{}' > "$B/tokens.json"; touch "$B/keepalive.off"
out="$("$SG" prewarm on)"
assert_eq "$(printf '%s' "$out" | jq -r '.warnings | length')" "2" "prewarm on warns about both: keepalive off and no tokens"

rm -rf "$HOME"
finish
