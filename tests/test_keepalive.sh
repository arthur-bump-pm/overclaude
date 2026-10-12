#!/bin/bash
# swap-guard keepalive: one usage fetch per tick, a daily alert per dead login,
# on/off with a marker install.sh respects, and a linted LaunchAgent.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 1

STUB="$HOME/stubbin"; mkdir -p "$STUB"
cat > "$STUB/cswap" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/cswap-calls"
case "$*" in
  "list --json"*)
    def='{"accounts":[{"number":1,"email":"work@example.com","alias":"work","active":true,"usageStatus":"ok"},{"number":2,"email":"personal@example.com","active":false,"usageStatus":"ok"}]}'
    printf '%s\n' "${STUB_LIST:-$def}" ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$STUB/cswap"
# osascript stub: record notifications instead of showing them.
printf '#!/bin/bash\necho "$*" >> "$HOME/notified"\n' > "$STUB/osascript"; chmod +x "$STUB/osascript"
export PATH="$STUB:$PATH" SWAP_GUARD_NO_LAUNCHCTL=1
B="$HOME/.claude-swap-backup"
DEAD='{"accounts":[{"number":1,"email":"work@example.com","alias":"work","active":true,"usageStatus":"ok"},{"number":2,"email":"personal@example.com","active":false,"usageStatus":"relogin_required"}]}'

out="$("$SG" keepalive tick)"
assert_eq "$(printf '%s' "$out" | jq -r .action)" "tick" "a tick reports itself"
assert_eq "$(printf '%s' "$out" | jq -c .dead)" "[]" "no dead logins"
assert_eq "$(cat "$HOME/cswap-calls")" "list --json" "a tick is exactly one cswap list --json (no switch, no other command)"
assert_eq "$([ -f "$HOME/notified" ] && echo yes || echo no)" "no" "healthy logins → no notification"

out="$(STUB_LIST="$DEAD" "$SG" keepalive tick)"
assert_eq "$(printf '%s' "$out" | jq -c .dead)" "[2]" "a dead login is reported"
assert_contains "$(cat "$HOME/notified")" "personal needs a new login" "and notified by name"
assert_contains "$(cat "$HOME/notified")" "swap-guard login 2" "with the command that fixes it"
assert_absent "$(cat "$HOME/notified")" "@example.com" "the notification shows no email address"
STUB_LIST="$DEAD" "$SG" keepalive tick >/dev/null
assert_eq "$(wc -l < "$HOME/notified" | tr -d ' ')" "1" "at most one alert per account per day"
touch -t "$(date -v-25H +%Y%m%d%H%M)" "$B/keepalive-alerted-2"
STUB_LIST="$DEAD" "$SG" keepalive tick >/dev/null
assert_eq "$(wc -l < "$HOME/notified" | tr -d ' ')" "2" "alerts again a day later"
"$SG" keepalive tick >/dev/null
assert_eq "$([ -f "$B/keepalive-alerted-2" ] && echo yes || echo no)" "no" "a fixed login clears its alert stamp"
STUB_LIST="$DEAD" "$SG" keepalive tick --no-notify >/dev/null
assert_eq "$(wc -l < "$HOME/notified" | tr -d ' ')" "2" "--no-notify stays quiet"
assert_eq "$(wc -l < "$B/keepalive.log" | tr -d ' ')" "6" "every tick is logged"

out="$(STUB_LIST='not json' "$SG" keepalive tick)"; rc=$?
assert_eq "$(printf '%s' "$out" | jq -r .action)" "error" "unusable cswap output → error"
assert_eq "$rc" "1" "error exit code"

# on/off: linted plist that runs `keepalive tick`, off leaves a marker.
r="$("$SG" keepalive on)"
plist="$(printf '%s' "$r" | jq -r .plist)"
plutil -lint "$plist" >/dev/null 2>&1 && pass || fail "generated plist lints" "$plist"
assert_eq "$(plutil -extract ProgramArguments.1 raw "$plist")" "keepalive" "agent runs swap-guard keepalive"
assert_eq "$(plutil -extract ProgramArguments.2 raw "$plist")" "tick" "… tick"
assert_eq "$(plutil -extract StartInterval raw "$plist")" "7200" "every 2 hours by default"
assert_eq "$(plutil -extract EnvironmentVariables.PATH raw "$plist" | cut -d: -f1)" "$STUB" "managed cswap dir first on the agent PATH"
assert_eq "$(printf '%s' "$("$SG" keepalive on --interval 10)" | jq -r .intervalSec)" "300" "interval floor is 5 minutes"
"$SG" keepalive on --interval abc >/dev/null 2>&1
assert_eq "$?" "1" "non-numeric interval refused"
"$SG" keepalive off >/dev/null
assert_eq "$([ -f "$plist" ] && echo yes || echo no)" "no" "off removes the agent"
assert_eq "$("$SG" keepalive status | jq -r .turnedOff)" "true" "off is remembered"
"$SG" keepalive on >/dev/null
assert_eq "$("$SG" keepalive status | jq -r .turnedOff)" "false" "on clears the marker"
STUB_LIST='not json' "$SG" keepalive on >/dev/null 2>&1
assert_eq "$?" "1" "a failing test tick → refuses to install"

rm -rf "$HOME"
finish
