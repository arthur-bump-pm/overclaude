#!/bin/bash
# swap-guard fleet status, schema 2: usage per account, login end dates as each Mac
# sees them, sessions with context %, auto-swap settings, data ages, and a Mac's own
# launchd-written report winning over an SSH read that cannot open the keychain.
# A stub ssh runs the real probe against fake per-host homes (no network).
. "$(dirname "$0")/lib.sh"
new_home
write_seq 1

STUB="$HOME/stubbin"; mkdir -p "$STUB"
NOW=$(date +%s)
iso() { date -u -r $(( NOW - $1 )) '+%Y-%m-%dT%H:%M:%SZ'; }
U() { # U <week%> <fable%> <willLast> — a cswap usage object
  printf '{"sevenDay":{"pct":%s,"resetsAt":"%s","expectedPct":50,"aheadOfPace":false,"projectedExhaustionAt":"%s","willLastToReset":%s},"scoped":[{"name":"Fable","pct":%s,"resetsAt":"%s"}]}' \
    "$1" "$(iso -86400)" "$(iso -172800)" "$3" "$2" "$(iso -86400)"
}

# worker1: the SSH read cannot open the keychain; its own report (2 min old) can.
W1="$HOME/hosts/worker1"; WB="$W1/.claude-swap-backup"
mkdir -p "$W1/.local/bin" "$WB/cache" "$WB/ctx" "$W1/Library/LaunchAgents" "$W1/proj"
printf '1.11.0' > "$WB/kit-version"
LIVE='{"activeAccountNumber":1,"accounts":[{"number":1,"email":"work@example.com","alias":"work","active":true,"usageStatus":"token_expired","usage":null,"loginExpiresAt":null},{"number":2,"email":"personal@example.com","alias":"personal","active":false,"usageStatus":"keychain_unavailable","loginExpiresAt":null},{"number":3,"email":"dead@example.com","alias":"dead","active":false,"usageStatus":"relogin_required"}]}'
SELFL="{\"accounts\":[{\"number\":1,\"email\":\"work@example.com\",\"alias\":\"work\",\"active\":true,\"usageStatus\":\"ok\",\"usage\":$(U 40 12 true),\"loginExpiresAt\":\"$(iso -864000)\",\"usageFetchedAt\":\"$(iso 150)\",\"usageAgeSeconds\":1},{\"number\":2,\"email\":\"personal@example.com\",\"alias\":\"personal\",\"active\":false,\"usageStatus\":\"ok\",\"usage\":$(U 90 70 false),\"usageFetchedAt\":\"$(iso 400)\"}]}"
printf '{"schema":1,"reportedAt":%s,"mac":"worker1","kit":"1.11.0","list":%s}\n' "$(( NOW - 120 ))" "$SELFL" > "$WB/cache/self.json"
printf '{"checkedAt":%s,"accounts":[{"slot":"2","email":"personal@example.com","endsAt":%s}]}' "$NOW" "$(( NOW + 432000 ))" > "$WB/cache/logins.json"
printf '{"pct":71,"ts":%s}\n' "$NOW" > "$WB/ctx/s1.json"
printf '{"ts":"%s","action":"none","rc":2}\n{"ts":"%s","source":"ratelimit","action":"switched","from":"2","to":"1"}\n{"ts":"%s","action":"deferred","reason":"busy","trigger":"proactive","to":"2","busySessions":2}\n{"ts":"%s","action":"deferred","reason":"busy","trigger":"proactive","to":"2","busySessions":1}\n' \
  "$(iso 1500)" "$(iso 1300)" "$(iso 1200)" "$(iso 60)" > "$WB/auto.log"
touch "$WB/instant-swap.off"
plutil -create xml1 "$W1/Library/LaunchAgents/com.overclaude.autoswap.plist"
plutil -insert ProgramArguments -json '["/x/swap-guard","auto","tick","--threshold","95"]' "$W1/Library/LaunchAgents/com.overclaude.autoswap.plist"
printf '#!/bin/bash\n[ "$1 $2" = "list --json" ] && printf %%s %q\n' "$LIVE" > "$W1/.local/bin/cswap"
printf '#!/bin/bash\ncase "$1" in sessions) echo %q;; keepalive) echo %q;; esac\n' \
  "[{\"pid\":1,\"sessionId\":\"s1\",\"cwd\":\"$W1/proj\",\"status\":\"busy\"},{\"pid\":2,\"sessionId\":\"s2\",\"cwd\":\"/elsewhere\",\"status\":\"idle\"}]" '{"loaded":true}' > "$W1/.local/bin/swap-guard"
chmod +x "$W1/.local/bin/"*

# worker2: an older kit — no self report, no login cache: the live read stands as is.
W2="$HOME/hosts/worker2"; mkdir -p "$W2/.local/bin" "$W2/.claude-swap-backup"
printf '1.10.2' > "$W2/.claude-swap-backup/kit-version"
printf '#!/bin/bash\n[ "$1 $2" = "list --json" ] && printf %%s %q\n' \
  "{\"accounts\":[{\"number\":1,\"email\":\"work@example.com\",\"alias\":\"work\",\"active\":true,\"usageStatus\":\"ok\",\"usage\":$(U 41 13 true),\"loginExpiresAt\":\"$(iso -500000)\",\"usageFetchedAt\":\"$(iso 600)\"}]}" > "$W2/.local/bin/cswap"
printf '#!/bin/bash\ncase "$1" in sessions) echo "[]";; keepalive) echo %q;; esac\n' '{"loaded":false}' > "$W2/.local/bin/swap-guard"
chmod +x "$W2/.local/bin/"*

cat > "$STUB/ssh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift
h="$1"; shift
[ -d "$HOME/hosts/$h" ] || exit 255
HOME="$HOME/hosts/$h" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash -c "$*"
EOF
# This Mac: work is active here too, with the freshest reading (30 s).
cat > "$STUB/cswap" <<EOF
#!/bin/bash
[ "\$1 \$2" = "list --json" ] && printf '%s\n' '{"accounts":[{"number":1,"email":"work@example.com","alias":"work","active":true,"usageStatus":"ok","usage":$(U 50 20 true),"loginExpiresAt":"$(iso -900000)","usageFetchedAt":"$(iso 30)"},{"number":2,"email":"personal@example.com","alias":"personal","active":false,"usageStatus":"ok","usage":$(U 90 70 false),"loginExpiresAt":"$(iso -900000)","usageFetchedAt":"$(iso 30)"}]}'
EOF
chmod +x "$STUB/ssh" "$STUB/cswap"
export PATH="$STUB:$PATH"
B="$HOME/.claude-swap-backup"
printf '[{"name":"primary","asOf":%s,"windows":[{"pct":30,"resetsAt":%s,"label":"week"}]}]\n' "$NOW" "$(( NOW + 3600 ))" > "$B/cache/codex-usage.json"
printf '{"hosts":[{"name":"worker1"},{"name":"worker2"},{"name":"gone"}]}\n' > "$B/fleet.json"

st="$(SWAP_FLEET_DEADLINE=10 "$SG" fleet status)"
assert_eq "$(printf '%s' "$st" | jq -r .schema)" "2" "status says schema 2"
assert_eq "$(printf '%s' "$st" | jq -r '[(.checkedAt | type), (.macs | length)] | join(",")')" "number,4" "checkedAt and one row per Mac, as before"
# Old keys stay (statusline, doctor and fleet swap read them).
for k in name online host kit claude overclaude sessions busy accounts dead keepalive load memGB cpus; do
  assert_eq "$(printf '%s' "$st" | jq -r --arg k "$k" '.macs[] | select(.name == "worker1") | has($k)')" "true" "old key $k kept"
done
assert_eq "$(printf '%s' "$st" | jq -r '.macs[] | select(.name == "gone") | .online')" "false" "an unreachable Mac is still just offline"
me="$(printf '%s' "$st" | jq -c '.macs[0]')"
assert_eq "$(printf '%s' "$me" | jq -r '[.self, .source, .macName] | join(",")')" "true,self,testmac" "this Mac: read in place, with its fleet name"

w="$(printf '%s' "$st" | jq -c '.macs[] | select(.name == "worker1")')"
a1="$(printf '%s' "$w" | jq -c '.accounts[] | select(.email == "work@example.com")')"
assert_eq "$(printf '%s' "$a1" | jq -r '[.status, .source, .liveStatus] | join(",")')" "ok,self-report,token_expired" "a keychain-blind SSH read gives way to the Mac's own report"
assert_eq "$(printf '%s' "$a1" | jq -r '[.sevenDay.pct, .fable.pct, .sevenDay.willLastToReset, .sevenDay.expectedPct] | join(",")')" "40,12,true,50" "week %, Fable % and pace from that report"
assert_eq "$(printf '%s' "$a1" | jq -r '[.alias, .active, .number] | join(",")')" "work,true,1" "alias and active state from the live read"
assert_eq "$(printf '%s' "$a1" | jq -r .loginExpiresAt)" "$(iso -864000)" "login end date as that Mac sees it"
age="$(printf '%s' "$a1" | jq -r .usageAgeSeconds)"
[ "$age" -ge 150 ] && [ "$age" -lt 200 ] && pass || fail "data age is worked out from the fetch time, not copied" "$age"
a2="$(printf '%s' "$w" | jq -c '.accounts[] | select(.email == "personal@example.com")')"
assert_eq "$(printf '%s' "$a2" | jq -r .loginExpiresAt)" "$(date -u -r $(( NOW + 432000 )) '+%Y-%m-%dT%H:%M:%SZ')" "no date in either read → that Mac's login cache"
assert_eq "$(printf '%s' "$w" | jq -r '.accounts[] | select(.alias == "dead") | "\(.status),\(.source)"')" "relogin_required,live" "a real verdict from the live read stands"
assert_eq "$(printf '%s' "$w" | jq -c .dead)" '["dead@example.com"]' "dead logins as before"
assert_eq "$(printf '%s' "$w" | jq -r '[.activeAlias, .source, .autoThreshold, .instantSwap] | join(",")')" "work,self,95,false" "active alias, source (its own report), auto threshold, instant swap"
sa="$(printf '%s' "$w" | jq -r .selfReportAgeSec)"
[ "$sa" -ge 120 ] && [ "$sa" -lt 170 ] && pass || fail "the self report's age" "$sa"
assert_eq "$(printf '%s' "$w" | jq -r .reportedAt)" "$(( NOW - 120 ))" "reportedAt is the report's time"
da="$(printf '%s' "$w" | jq -r .dataAgeSec)"
[ "$da" -ge 120 ] && [ "$da" -lt 170 ] && pass || fail "dataAgeSec is the report's age" "$da"
assert_le "$(( $(date +%s) - $(printf '%s' "$w" | jq -r .readAt) ))" 30 "readAt: when the SSH read ran"
assert_eq "$(printf '%s' "$w" | jq -r '[.deferred.since, .deferred.busySessions, .deferred.to] | join(",")')" "$(iso 1200),1,2" "a waiting swap: since its first deferral, other sources ignored"
assert_eq "$(printf '%s' "$w" | jq -c '[.sessionList[] | [.sessionId, .cwd, .status, .ctxPct]]')" '[["s1","~/proj","busy",71],["s2","/elsewhere","idle",null]]' "sessions with context %"

w2="$(printf '%s' "$st" | jq -c '.macs[] | select(.name == "worker2")')"
assert_eq "$(printf '%s' "$w2" | jq -r '[.accounts[0].source, .accounts[0].sevenDay.pct, .selfReportedAt, .autoThreshold, .deferred, .source] | map(tostring) | join(",")')" "live,41,null,null,null,ssh" "an older kit: the live read, nothing invented, source ssh"

u="$(printf '%s' "$st" | jq -c '.usage[] | select(.email == "work@example.com")')"
assert_eq "$(printf '%s' "$u" | jq -r '[.sevenDay.pct, .usageFrom, .room, .best, .fable.pct] | join(",")')" "50,this Mac,50,true,20" "usage per account: the freshest reading wins; room and best"
assert_eq "$(printf '%s' "$u" | jq -c .activeOn)" '["this Mac","worker1","worker2"]' "and the Macs it is active on"
assert_eq "$(printf '%s' "$st" | jq -r '.usage[] | select(.email == "personal@example.com") | [.room, (.best // false)] | join(",")')" "10,false" "an account that will not last is never best"
assert_eq "$(printf '%s' "$st" | jq -r '.usage[] | select(.kind == "codex") | [.alias, .room] | join(",")')" "codex,70" "Codex limits are listed too"
assert_eq "$(jq -r .schema "$B/cache/fleet.json")" "2" "the cache gets the new shape"

txt="$(SWAP_FLEET_DEADLINE=10 "$SG" fleet status --text)"
assert_contains "$txt" "room left: " "text view ends with room per account"
assert_contains "$txt" "work 50% (best) on this Mac/worker1/worker2" "naming the best account and its Macs"
assert_contains "$txt" "ctx 71%" "and context fill per Mac"
sl="$(echo '{"model":{"display_name":"M"}}' | SWAP_NO_REFRESH=1 bash "$SL" | strip_ansi)"
assert_contains "$sl" "↳ fleet 3/4 macs" "the statusline still reads the cache"

# best is judged per Mac, by THAT Mac's login: work's login here ends in 2 h, so it is
# not this Mac's best even though the workers' logins of it run for days.
cp "$STUB/cswap" "$STUB/cswap.keep"
perl -pe "s/\"loginExpiresAt\":\"[^\"]*\"/\"loginExpiresAt\":\"$(iso -7200)\"/" "$STUB/cswap.keep" > "$STUB/cswap"
st2="$(SWAP_FLEET_DEADLINE=10 "$SG" fleet status)"
assert_eq "$(printf '%s' "$st2" | jq -r '[.usage[] | select(.best)] | length')" "0" "no best on this Mac when its own login of the roomiest account ends within 6 h"
assert_eq "$(printf '%s' "$st2" | jq -r '[.macs[] | select(.online) | "\(.name)=\(.bestTarget)"] | join(",")')" "this Mac=null,worker1=work,worker2=work" "each Mac's bestTarget uses its own login dates"
assert_eq "$(printf '%s' "$st" | jq -r '.macs[0].bestTarget')" "work" "with a long login here, work is this Mac's bestTarget"
mv "$STUB/cswap.keep" "$STUB/cswap"

# A failure in the per-account part never blanks the answer or the cache: the old
# (schema 1) object stands.
cp "$B/cache/codex-usage.json" "$HOME/codex.keep"
printf '[{"name":"primary","windows":"broken"}]\n' > "$B/cache/codex-usage.json"
st3="$(SWAP_FLEET_DEADLINE=10 "$SG" fleet status)"; rc=$?
assert_eq "$rc,$(printf '%s' "$st3" | jq -r '[(.macs | length), (.schema // "none"), (.macs[] | select(.name == "worker1") | .sessions)] | map(tostring) | join(",")')" "0,4,none,2" "a broken usage part falls back to the old shape"
assert_eq "$(jq -r '.macs | length' "$B/cache/fleet.json")" "4" "and the cache is never emptied"
mv "$HOME/codex.keep" "$B/cache/codex-usage.json"

# fleet swap judges a worker's targets by what SSH saw, never by a self report: with
# work capped here, personal (keychain_unavailable over SSH, ok in its report) is no target.
cp "$STUB/cswap" "$STUB/cswap.keep"
sed 's/"pct":50,/"pct":100,/' "$STUB/cswap.keep" > "$STUB/cswap"
sed -i '' 's/"pct":90,"resetsAt":"[^"]*","expectedPct":50,"aheadOfPace":false,"projectedExhaustionAt":"[^"]*","willLastToReset":false/"pct":10,"willLastToReset":true/' "$STUB/cswap"
plan="$(SWAP_FLEET_DEADLINE=10 "$SG" fleet swap --dry-run | jq -r '.[] | select(.name == "worker1") | "\(.action) \(.reason // .to)"')"
assert_eq "$plan" "none no-account-with-room-there" "fleet swap never targets an account only a self report calls ok"
mv "$STUB/cswap.keep" "$STUB/cswap"

# A self report older than SELF_REPORT_MAX_AGE (3 h) is ignored: the live read stands.
jq -c --argjson t "$(( NOW - 11000 ))" '.reportedAt = $t' "$WB/cache/self.json" > "$WB/s.tmp" && mv "$WB/s.tmp" "$WB/cache/self.json"
w="$(SWAP_FLEET_DEADLINE=10 "$SG" fleet status | jq -c '.macs[] | select(.name == "worker1")')"
assert_eq "$(printf '%s' "$w" | jq -r '[(.accounts[] | select(.alias == "work") | .status, .source), .source] | join(",")')" "token_expired,live,ssh" "a stale self report is not used"

rm -rf "$HOME"
finish
