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
  printf '#!/bin/bash\n[ "$1 $2" = "list --json" ] && printf %%s %q\n' "$2" > "$h/.local/bin/cswap"
  printf '#!/bin/bash\ncase "$1" in sessions) echo %q;; keepalive) echo %q;; esac\n' \
    '[{"pid":1,"status":"busy"},{"pid":2,"status":"idle"}]' '{"loaded":true}' > "$h/.local/bin/swap-guard"
  printf '#!/bin/bash\necho "2.1.296 (Claude Code)"\n' > "$h/.local/bin/claude"
  chmod +x "$h/.local/bin/"*
}
mkhost worker1 '{"accounts":[{"email":"work@example.com","active":true,"usageStatus":"ok"},{"email":"personal@example.com","usageStatus":"relogin_required"}]}' 1.5.0
mkhost bare '{"accounts":[]}' ""
rm -f "$HOME/hosts/bare/.local/bin/swap-guard"
cat > "$STUB/ssh" <<'EOF'
#!/bin/bash
# stub: last two args before the remote command are "-- <host>"; run the probe with HOME=<fake host>
echo "$*" >> "$HOME/ssh-calls"
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift
h="$1"; shift
case "$h" in
  offline) exit 255;;
  hung)    sleep 30; exit 255;;
esac
[ -d "$HOME/hosts/$h" ] || exit 255
HOME="$HOME/hosts/$h" PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$@"
EOF
chmod +x "$STUB/ssh"
# This Mac's own probe must not reach the real cswap (or keychain).
printf '#!/bin/bash\n[ "$1 $2" = "list --json" ] && echo %q\n' '{"accounts":[{"email":"work@example.com","active":true,"usageStatus":"ok"}]}' > "$STUB/cswap"
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
jq '.hosts += [{name:"offline"},{name:"hung"}]' "$B/fleet.json" > "$B/f.tmp" && mv "$B/f.tmp" "$B/fleet.json"
t0=$(date +%s)
st="$(SWAP_FLEET_DEADLINE=3 "$SG" fleet status)"
assert_le "$(( $(date +%s) - t0 ))" "8" "a hung host does not hold the answer"
assert_eq "$(printf '%s' "$st" | jq -r '.macs[0].self')" "true" "this Mac comes first"
assert_eq "$(printf '%s' "$st" | jq '.macs | length')" "5" "one row per Mac"
w="$(printf '%s' "$st" | jq -c '.macs[] | select(.name == "worker1")')"
assert_eq "$(printf '%s' "$w" | jq -r '[.sessions, .busy] | join(",")')" "2,1" "sessions and busy count from the worker"
assert_eq "$(printf '%s' "$w" | jq -r '.dead[0]')" "personal@example.com" "a dead login on a worker is reported"
assert_eq "$(printf '%s' "$w" | jq -r .claude)" "2.1.296" "the worker's Claude Code version"
assert_eq "$(printf '%s' "$st" | jq -r '.macs[] | select(.name == "offline") | .online')" "false" "an unreachable Mac is offline"
assert_eq "$(printf '%s' "$st" | jq -r '.macs[] | select(.name == "hung") | .online')" "false" "a hung Mac is offline"
assert_eq "$(jq '.macs | length' "$B/cache/fleet.json")" "5" "status is cached for the statusline and doctor"
txt="$(SWAP_FLEET_DEADLINE=3 "$SG" fleet status --text)"
assert_contains "$txt" "worker1 (" "text view names each Mac"
assert_contains "$txt" "personal ⚠ relogin" "and flags dead logins"
assert_contains "$txt" "offline: offline" "and offline Macs"
sl="$(echo '{"model":{"display_name":"M"}}' | SWAP_NO_REFRESH=1 bash "$SL" | strip_ansi)"
assert_contains "$sl" "↳ fleet 3/5 macs · 2 sessions (1 busy)" "statusline fleet line from the cache"
assert_contains "$sl" "offline: offline, hung" "names offline Macs"
assert_contains "$sl" "⚠ relogin on worker1" "and Macs with a dead login"
assert_absent "$(echo '{"model":{"display_name":"M"}}' | SWAP_NO_REFRESH=1 SWAP_HIDE_FLEET=1 bash "$SL" | strip_ansi)" "fleet" "SWAP_HIDE_FLEET hides it"
"$SG" fleet rm hung >/dev/null; "$SG" fleet rm offline >/dev/null
assert_eq "$("$SG" fleet list)" '["bare","worker1"]' "fleet rm removes a Mac"
pkill -f "sleep 30" 2>/dev/null

"$SG" fleet rm bare >/dev/null; "$SG" fleet rm worker1 >/dev/null
assert_absent "$(echo '{"model":{"display_name":"M"}}' | SWAP_NO_REFRESH=1 bash "$SL" | strip_ansi)" "fleet" "no fleet line without registered Macs"

rm -rf "$HOME"
finish
