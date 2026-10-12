#!/bin/bash
# swap-guard fleet: add/rm/list, parallel status with offline and hung hosts, the
# cache the statusline reads. A stub ssh runs the probe locally against fake
# per-host homes, so no network or real SSH is involved.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 1

STUB="$HOME/stubbin"; mkdir -p "$STUB"
# Fake Macs: each host gets a home with its own fake cswap/swap-guard/claude.
mkhost() { # mkhost <name> <accounts-json> <kit-version|"">
  local h="$HOME/hosts/$1"; mkdir -p "$h/.local/bin" "$h/.claude-swap-backup"
  [ -n "$3" ] && printf '%s' "$3" > "$h/.claude-swap-backup/kit-version"
  printf '#!/bin/bash\n[ "$1 $2" = "list --json" ] && printf %%s %q\n[ "$1" = switch ] && { echo "$2" >> "$HOME/switched"; echo "{\\"switched\\":true}"; }\n' "$2" > "$h/.local/bin/cswap"
  # canned sessions/keepalive; `fleet follow` is the real swap-guard (in this fake home)
  printf '#!/bin/bash\ncase "$1" in sessions) echo %q;; keepalive) echo %q;; fleet) exec %q "$@";; esac\n' \
    '[{"pid":1,"status":"busy"},{"pid":2,"status":"idle"}]' '{"loaded":true}' "$SG" > "$h/.local/bin/swap-guard"
  printf '#!/bin/bash\necho "2.1.296 (Claude Code)"\n' > "$h/.local/bin/claude"
  chmod +x "$h/.local/bin/"*
}
mkhost worker1 '{"activeAccountNumber":1,"accounts":[{"number":1,"email":"work@example.com","active":true,"usageStatus":"ok"},{"number":2,"email":"personal@example.com","usageStatus":"relogin_required"},{"number":3,"email":"extra@example.com","usageStatus":"ok"},{"number":4,"email":"spare@example.com","usageStatus":"ok"},{"number":5,"email":"quar@example.com","usageStatus":"quarantined"}]}' 1.5.0
mkhost worker2 '{"activeAccountNumber":1,"accounts":[{"number":1,"email":"work@example.com","active":true,"usageStatus":"ok"},{"number":2,"email":"personal@example.com","usageStatus":"relogin_required"},{"number":3,"email":"extra@example.com","usageStatus":"ok"},{"number":4,"email":"spare@example.com","usageStatus":"ok"},{"number":5,"email":"quar@example.com","usageStatus":"quarantined"}]}' 1.5.0
mkhost bare '{"accounts":[]}' ""
rm -f "$HOME/hosts/bare/.local/bin/swap-guard"
cat > "$STUB/ssh" <<'EOF'
#!/bin/bash
# stub: last two args before the remote command are "-- <host>"; run the probe with HOME=<fake host>
echo "$*" >> "$HOME/ssh-calls"
# Like OpenSSH, forward (consume) stdin for anything but the probe, which reads it.
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift
h="$1"; shift
case "$h" in
  offline) exit 255;;
  hung)    sleep 30; exit 255;;
  partial) printf 'host\tp\nkit\t1.5.0\n'; sleep 30; exit 255;;
esac
[ -d "$HOME/hosts/$h" ] || exit 255
[ "$*" = "bash -s" ] || cat > /dev/null
HOME="$HOME/hosts/$h" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash -c "$*"
EOF
chmod +x "$STUB/ssh"
# This Mac's own probe must not reach the real cswap (or keychain).
cat > "$STUB/cswap" <<'EOF'
#!/bin/bash
def='{"accounts":[{"email":"work@example.com","active":true,"usageStatus":"ok"}]}'
[ "$1 $2" = "list --json" ] && printf '%s\n' "${STUB_HUB:-$def}"
EOF
chmod +x "$STUB/cswap"
export PATH="$STUB:$PATH"
B="$HOME/.claude-swap-backup"

out="$("$SG" fleet add worker1 2>"$HOME/err")"
assert_eq "$(printf '%s' "$out" | jq -r .added)" "worker1" "fleet add records a reachable Mac"
assert_eq "$(printf '%s' "$out" | jq -r .kit)" "1.5.0" "and reports its overclaude version"
assert_contains "$(cat "$HOME/ssh-calls")" "BatchMode=yes" "SSH never prompts for a password"
"$SG" fleet add offline >/dev/null 2>"$HOME/err"
assert_eq "$?" "1" "an unreachable Mac is refused"
assert_contains "$(cat "$HOME/err")" "ssh-copy-id offline" "with how to enable SSH there"
"$SG" fleet add '-oProxyCommand=evil' >/dev/null 2>&1
assert_eq "$?" "2" "a host name that looks like an ssh option is refused"
"$SG" fleet add bare >/dev/null 2>"$HOME/err"
assert_contains "$(cat "$HOME/err")" "overclaude is not installed there" "a Mac without the kit is flagged"
assert_contains "$(cat "$HOME/err")" "No accounts are logged in" "and one with no accounts"
"$SG" fleet add worker1 >/dev/null 2>&1
assert_eq "$("$SG" fleet list)" '["bare","worker1"]' "re-adding does not duplicate"
assert_absent "$(cat "$B/fleet.json")" "@example.com" "fleet.json holds host names only"

# status: this Mac + workers in parallel; an offline and a hung host don't block.
jq '.hosts += [{name:"offline"},{name:"hung"},{name:"partial"}]' "$B/fleet.json" > "$B/f.tmp" && mv "$B/f.tmp" "$B/fleet.json"
t0=$(date +%s)
st="$(SWAP_FLEET_DEADLINE=3 "$SG" fleet status)"
assert_le "$(( $(date +%s) - t0 ))" "8" "a hung host does not hold the answer"
assert_eq "$(printf '%s' "$st" | jq -r '.macs[0].self')" "true" "this Mac comes first"
assert_eq "$(printf '%s' "$st" | jq '.macs | length')" "6" "one row per Mac"
assert_eq "$(printf '%s' "$st" | jq -r '.macs[] | select(.name == "partial") | .online')" "false" "half an answer (killed at the deadline) counts as offline"
w="$(printf '%s' "$st" | jq -c '.macs[] | select(.name == "worker1")')"
assert_eq "$(printf '%s' "$w" | jq -r '[.sessions, .busy] | join(",")')" "2,1" "sessions and busy count from the worker"
assert_eq "$(printf '%s' "$w" | jq -r '.dead[0]')" "personal@example.com" "a dead login on a worker is reported"
assert_eq "$(printf '%s' "$w" | jq -r .claude)" "2.1.296" "the worker's Claude Code version"
assert_eq "$(printf '%s' "$st" | jq -r '.macs[] | select(.name == "offline") | .online')" "false" "an unreachable Mac is offline"
assert_eq "$(printf '%s' "$st" | jq -r '.macs[] | select(.name == "hung") | .online')" "false" "a hung Mac is offline"
assert_eq "$(jq '.macs | length' "$B/cache/fleet.json")" "6" "status is cached for the statusline and doctor"
txt="$(SWAP_FLEET_DEADLINE=3 "$SG" fleet status --text)"
assert_contains "$txt" "worker1 (" "text view names each Mac"
assert_contains "$txt" "personal ⚠ relogin" "and flags dead logins"
assert_contains "$txt" "offline: offline" "and offline Macs"
sl="$(echo '{"model":{"display_name":"M"}}' | SWAP_NO_REFRESH=1 bash "$SL" | strip_ansi)"
assert_contains "$sl" "↳ fleet 3/6 macs · 2 sessions (1 busy)" "statusline fleet line from the cache"
assert_contains "$sl" "offline: offline, hung, partial" "names offline Macs"
assert_contains "$sl" "⚠ relogin on worker1" "and Macs with a dead login"
assert_absent "$(echo '{"model":{"display_name":"M"}}' | SWAP_NO_REFRESH=1 SWAP_HIDE_FLEET=1 bash "$SL" | strip_ansi)" "fleet" "SWAP_HIDE_FLEET hides it"
"$SG" fleet rm hung >/dev/null; "$SG" fleet rm offline >/dev/null; "$SG" fleet rm partial >/dev/null
assert_eq "$("$SG" fleet list)" '["bare","worker1"]' "fleet rm removes a Mac"
assert_eq "$(pgrep -f "sleep 30" | wc -l | tr -d ' ')" "0" "the deadline leaves no stray processes"
assert_eq "$(pgrep -f "sleep 3$" | wc -l | tr -d ' ')" "0" "and neither does the watchdog"
pkill -f "sleep 30" 2>/dev/null
"$SG" fleet add worker2 >/dev/null 2>&1

# fleet swap: worker1 and worker2 are on work (1), which the hub sees capped. extra (3)
# and spare (4) have equal room; extra's week resets sooner → extra. personal is dead
# there and quar is quarantined there → never, though the hub shows them empty.
u() { printf '{"number":%s,"email":"%s@example.com","usageStatus":"ok"%s,"usage":{"fiveHour":{"pct":%s},"sevenDay":{"pct":%s,"resetsAt":"%s"}}}' "$1" "$2" "${6:-}" "$3" "$4" "$5"; }
SOON="$(date -u -v+1d +%Y-%m-%dT%H:%M:%S+00:00)"; LATE="$(date -u -v+5d +%Y-%m-%dT%H:%M:%S+00:00)"
hub() { export STUB_HUB="{\"activeAccountNumber\":2,\"accounts\":[$(u 1 work 100 50 "$LATE"),$(u 2 personal 0 0 "$LATE"),$(u 3 extra 20 30 "$SOON" "$1"),$(u 4 spare 20 30 "$LATE"),$(u 5 quar 0 0 "$LATE")]}"; }
plan() { SWAP_FLEET_DEADLINE=5 "$SG" fleet swap "$@" | jq -r '.[] | select(.name == "worker1") | "\(.action) \(.to // .reason)"'; }
hub ""
assert_eq "$(plan --dry-run)" "would-switch extra@example.com" "a capped worker would move to the roomiest usable account there (soonest reset breaks the tie)"
assert_eq "$(SWAP_FLEET_DEADLINE=5 "$SG" fleet swap --dry-run | jq -r '.[] | select(.name == "bare") | .reason')" "no-active-account" "a Mac with no login is skipped"
assert_eq "$([ -f "$HOME/hosts/worker1/switched" ] && echo yes || echo no)" "no" "dry run switches nothing"
hub ',"disabled":true'
assert_eq "$(plan --dry-run)" "would-switch spare@example.com" "an account disabled on this Mac is never a target"
hub ""
printf '[{"slot":"3","model":"","until":%s}]' "$(( $(date +%s) + 3600 ))" > "$B/ratelimit-capped.json"
assert_eq "$(plan --dry-run)" "would-switch spare@example.com" "an account this Mac recorded as capped is never a target"
rm -f "$B/ratelimit-capped.json"
assert_eq "$(plan --from personal@example.com)" "skip not-on-that-account" "--from only moves Macs on that account"
p="$(SWAP_FLEET_DEADLINE=5 "$SG" fleet swap --from work@example.com)"
assert_eq "$(printf '%s' "$p" | jq -r '[.[] | select(.action == "switched") | .name] | join(",")')" "worker1,worker2" "every worker on the capped account is switched (ssh never eats the list)"
assert_eq "$(cat "$HOME/hosts/worker1/switched")" "3" "each with its own cswap, to that account's slot there"
assert_eq "$(jq -r '"\(.source) \(.from)->\(.to)"' "$HOME/hosts/worker1/.claude-swap-backup/ratelimit-last.json")" "fleet 1->3" "the worker records the swap, so its own rate-limit hook reuses it"
assert_eq "$(jq -r '.[0].slot' "$HOME/hosts/worker1/.claude-swap-backup/ratelimit-capped.json")" "1" "and records the account it left as capped there"
o="$(HOME="$HOME/hosts/worker1" PATH="$HOME/hosts/worker1/.local/bin:$PATH" "$SG" fleet follow --from personal@example.com --to extra@example.com)"
assert_eq "$(printf '%s' "$o" | jq -r .reason)" "not-on-that-account" "follow switches only a Mac still on the capped account"
o="$(HOME="$HOME/hosts/worker1" "$SG" fleet follow --from "-x" --to extra@example.com)"
assert_eq "$(printf '%s' "$o" | jq -r .reason)" "bad-arguments" "follow refuses option-like names"
export STUB_HUB="{\"accounts\":[$(u 1 work 100 50 "$LATE"),$(u 3 extra 100 30 "$SOON"),$(u 4 spare 20 100 "$LATE")]}"
assert_eq "$(plan --dry-run)" "none no-account-with-room-there" "no room anywhere → nothing to switch to"
unset STUB_HUB

"$SG" fleet rm bare >/dev/null; "$SG" fleet rm worker1 >/dev/null; "$SG" fleet rm worker2 >/dev/null
assert_absent "$(echo '{"model":{"display_name":"M"}}' | SWAP_NO_REFRESH=1 bash "$SL" | strip_ansi)" "fleet" "no fleet line without registered Macs"

rm -rf "$HOME"
finish
