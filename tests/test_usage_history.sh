#!/bin/bash
# usage-history.jsonl + cache/self.json: written by the keepalive and auto ticks
# (never by a probe), a row per account on change plus an hourly heartbeat, swap
# event rows, 180-day retention trimmed monthly, and `swap-guard usage-history`.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 1

STUB="$HOME/stubbin"; mkdir -p "$STUB"
cat > "$STUB/cswap" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/cswap-calls"
case "$*" in
  "list --json"*) printf '%s\n' "$STUB_LIST" ;;
  *--dry-run*)    printf '%s\n' "$STUB_DRY"; exit "${STUB_DRY_RC:-0}" ;;
  "auto --once"*) printf '%s\n' "$STUB_REAL"; exit "${STUB_REAL_RC:-0}" ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$STUB/cswap"
printf '#!/bin/bash\necho "$*" >> "$HOME/notified"\n' > "$STUB/osascript"; chmod +x "$STUB/osascript"
export PATH="$STUB:$PATH" SWAP_GUARD_NO_LAUNCHCTL=1
B="$HOME/.claude-swap-backup"; H="$B/usage-history.jsonl"
L() { # L <work week%> <work fable%> [work status] — two accounts, work active
  export STUB_LIST="{\"accounts\":[{\"number\":1,\"email\":\"work@example.com\",\"alias\":\"work\",\"active\":true,\"usageStatus\":\"${3:-ok}\",\"usage\":{\"sevenDay\":{\"pct\":$1,\"resetsAt\":\"2030-01-01T00:00:00Z\",\"willLastToReset\":false},\"scoped\":[{\"name\":\"Fable\",\"pct\":$2}]}},{\"number\":2,\"email\":\"personal@example.com\",\"active\":false,\"usageStatus\":\"ok\",\"usage\":{\"sevenDay\":{\"pct\":10,\"willLastToReset\":true}}}]}"
}
rows() { [ -f "$H" ] && wc -l < "$H" | tr -d ' ' || echo 0; }

L 82 36
out="$("$SG" keepalive tick --no-notify)"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1" "the keepalive tick still prints one line"
assert_eq "$(printf '%s' "$out" | jq -r .action)" "tick" "and it is the tick's own"
assert_eq "$(cat "$HOME/cswap-calls")" "list --json" "still exactly one cswap call: history reuses the tick's list"
assert_eq "$(rows)" "2" "first tick: a row per account"
r="$(head -n 1 "$H")"
assert_eq "$(printf '%s' "$r" | jq -r '[.mac, .acct, .active, .w, .fable, .resetsAt, .last, .status, .sessions, .busy] | map(tostring) | join(",")')" \
  "testmac,work,true,82,36,2030-01-01T00:00:00Z,false,ok,0,0" "row fields as the plan's usage row"
assert_eq "$(sed -n 2p "$H" | jq -r '[.acct, .fable] | map(tostring) | join(",")')" "personal,null" "an account with no alias is named by its email's local part"
assert_eq "$(jq -r '[.mac, (.reportedAt | type), (.list.accounts | length)] | map(tostring) | join(",")' "$B/cache/self.json")" "testmac,number,2" "the tick leaves this Mac's own report for fleet status"

"$SG" keepalive tick --no-notify >/dev/null
assert_eq "$(rows)" "2" "nothing changed within the hour → no new rows"
L 83 36; "$SG" keepalive tick --no-notify >/dev/null
assert_eq "$(rows)" "3" "a week % change adds a row for that account only"
assert_eq "$(tail -n 1 "$H" | jq -r '"\(.acct) \(.w)"')" "work 83" "with the new number"
L 83 37; "$SG" keepalive tick --no-notify >/dev/null
L 83 37 relogin_required; "$SG" keepalive tick --no-notify >/dev/null
assert_eq "$(rows)" "5" "a Fable % change and a status change each add a row"
jq -c '.[] |= (.at -= 4000)' "$B/cache/usage-history-state.json" > "$B/s.tmp" && mv "$B/s.tmp" "$B/cache/usage-history-state.json"
"$SG" keepalive tick --no-notify >/dev/null
assert_eq "$(rows)" "7" "an hour on, every account gets a heartbeat row"
n="$(rows)"; "$SG" keepalive tick --probe >/dev/null
assert_eq "$(rows)" "$n" "a probe tick writes nothing"
SWAP_NO_USAGE_HISTORY=1 L 50 50; SWAP_NO_USAGE_HISTORY=1 "$SG" keepalive tick --no-notify >/dev/null
assert_eq "$(rows)" "$n" "SWAP_NO_USAGE_HISTORY turns it off"

# The auto tick writes it too, and a switch becomes an event row.
L 90 40
touch -t "$(date -v-10M +%Y%m%d%H%M)" "$B/cache/self.json"
SW='{"event":"switch","trigger":"proactive","from":{"number":1},"to":{"number":2,"email":"personal@example.com"},"warnings":[]}'
o="$(STUB_DRY="$SW" STUB_REAL="$SW" "$SG" auto tick --no-notify)"; rc=$?
assert_eq "$(printf '%s' "$o" | jq -r .action),$rc" "switched,0" "the auto tick's own output and exit code are unchanged"
assert_eq "$(grep -c '"ev":"swap"' "$H")" "1" "a switch adds one event row"
assert_eq "$(grep '"ev":"swap"' "$H" | jq -r '"\(.from) \(.to) \(.by) \(.trigger)"')" "work personal auto proactive" "named by alias, with who switched"
assert_eq "$(tail -n 1 "$H" | jq -r '"\(.acct) \(.w)"')" "work 90" "and the tick's usage rows follow"
n="$(rows)"
STUB_DRY='{"event":"no-switch","reason":"below-threshold"}' STUB_DRY_RC=2 "$SG" auto tick --probe --no-notify >/dev/null
assert_eq "$(rows)" "$n" "an auto probe writes nothing"
: > "$HOME/cswap-calls"; L 95 40
STUB_DRY='{"event":"no-switch","reason":"below-threshold"}' STUB_DRY_RC=2 "$SG" auto tick --no-notify >/dev/null
assert_absent "$(cat "$HOME/cswap-calls")" "list --json" "within 5 minutes of the last report the auto tick adds no list call"
assert_eq "$(rows)" "$n" "and no rows"

# A swap row waits for the history lock (the trim's copy + mv would drop it otherwise).
mkdir "$B/cache/usage-history.lock"
n="$(grep -c '"ev":"swap"' "$H")"
STUB_DRY="$SW" STUB_REAL="$SW" "$SG" auto tick --no-notify >/dev/null & TP=$!
sleep 1
assert_eq "$(grep -c '"ev":"swap"' "$H")" "$n" "while another writer holds the lock, the swap row waits"
rmdir "$B/cache/usage-history.lock"
wait "$TP"
assert_eq "$(grep -c '"ev":"swap"' "$H")" "$((n + 1))" "and is written once the lock is free"
assert_eq "$([ -d "$B/cache/usage-history.lock" ] && echo held || echo free)" "free" "the lock is released"

# Retention: 180 days, trimmed once a month.
old="$(date -u -r $(( $(date +%s) - 200 * 86400 )) +%Y-%m-%dT%H:%M:%SZ)"
assert_eq "$([ -f "$B/cache/usage-history.trimmed" ] && echo yes)" "yes" "the first write already checked retention"
printf '{"ts":"%s","mac":"testmac","acct":"work","w":1}\nnot json\n' "$old" | cat - "$H" > "$H.t" && mv "$H.t" "$H"
touch -t "$(date -v-31d +%Y%m%d%H%M)" "$B/cache/usage-history.trimmed"
L 91 40; "$SG" keepalive tick --no-notify >/dev/null
assert_absent "$(cat "$H")" "$old" "a month after the last check: rows past 180 days go"
assert_absent "$(cat "$H")" "not json" "and so does a broken line"
printf '{"ts":"%s","mac":"testmac","acct":"work","w":1}\n' "$old" >> "$H"
L 92 40; "$SG" keepalive tick --no-notify >/dev/null
assert_contains "$(cat "$H")" "$old" "trimmed this month already → left until next month"
touch -t "$(date -v-31d +%Y%m%d%H%M)" "$B/cache/usage-history.trimmed"
L 93 40; "$SG" keepalive tick --no-notify >/dev/null
assert_absent "$(cat "$H")" "$old" "a month on, it trims again"

# The read command.
j="$("$SG" usage-history)"
assert_eq "$(printf '%s' "$j" | jq -r 'type')" "array" "usage-history prints a JSON array"
assert_eq "$(printf '%s' "$j" | jq 'length')" "$(rows)" "every recent row"
printf '{"ts":"%s","mac":"other","acct":"work","w":5}\n' "$(date -u -r $(( $(date +%s) - 3 * 86400 )) +%Y-%m-%dT%H:%M:%SZ)" >> "$H"
assert_eq "$("$SG" usage-history --days 1 | jq '[.[] | select(.mac == "other")] | length')" "0" "--days leaves older rows out"
assert_eq "$("$SG" usage-history --days 7 --mac other | jq 'length')" "1" "--mac keeps one Mac's rows"
t="$("$SG" usage-history --text)"
assert_contains "$t" "testmac  work*  week 93% · Fable 40% · ok · will not last to reset" "text: one line per row"
assert_contains "$t" "swap work → personal (auto)" "and swaps"
"$SG" usage-history --days x >/dev/null 2>&1
assert_eq "$?" "2" "a bad --days is refused"
rm -f "$H"
assert_eq "$("$SG" usage-history)" "[]" "no log yet → []"
assert_contains "$("$SG" usage-history --text)" "No usage history" "and says so in text"
assert_eq "$("$SG" history --all | jq -r 'type')" "array" "the handoff history command is untouched"

rm -rf "$HOME"
finish
