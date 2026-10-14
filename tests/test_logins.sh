#!/bin/bash
# swap-guard logins: each account's login end date (refreshTokenExpiresAt) read from
# the keychain — live item for the active account, cswap's backup for the rest — with
# only the dates kept. Preflight refuses a login within hours of its end, the instant
# swap skips it, keepalive warns once a day from 3 days out, statusline and doctor show it.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 1

STUB="$HOME/stubbin"; KC="$HOME/kc"; mkdir -p "$STUB" "$KC"
# security stub: find-generic-password -a <acct> -s <svc> -w → the item stored in $KC/<svc>/<acct>.
cat > "$STUB/security" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/security-argv"
[ -f "$HOME/kc-hang" ] && exec sleep 20
a=""; s=""
while [ $# -gt 0 ]; do case "$1" in -a) a="$2"; shift;; -s) s="$2"; shift;; esac; shift; done
f="$HOME/kc/$s/$a"; [ -f "$f" ] || exit 44
cat "$f"
EOF
cat > "$STUB/cswap" <<'EOF'
#!/bin/bash
case "$*" in
  "list --json"*) printf '%s\n' '{"activeAccountNumber":1,"accounts":[
    {"number":1,"email":"work@example.com","alias":"work","active":true,"usageStatus":"ok"},
    {"number":2,"email":"personal@example.com","alias":"personal","active":false,"usageStatus":"ok"}]}';;
  *) exit 9;;
esac
EOF
printf '#!/bin/bash\necho "$*" >> "$HOME/notified"\n' > "$STUB/osascript"
chmod +x "$STUB/security" "$STUB/cswap" "$STUB/osascript"
export PATH="$STUB:$PATH" SWAP_GUARD_NO_LAUNCHCTL=1 USER=tester
unset CLAUDE_CONFIG_DIR
B="$HOME/.claude-swap-backup"
NOW="$(date +%s)"
SECRET="sk-ant-ort01-SECRETxyz"
item() { # item <svc> <acct> <ends-in-seconds|none> [expires-in-seconds]
  mkdir -p "$KC/$1"
  local r=""; [ "$3" = none ] || r=",\"refreshTokenExpiresAt\":$(( (NOW + $3) * 1000 ))"
  printf '{"claudeAiOauth":{"accessToken":"%s-a","refreshToken":"%s","expiresAt":%s%s},"mcpOAuth":{}}' \
    "$SECRET" "$SECRET" "$(( (NOW + ${4:-28800}) * 1000 ))" "$r" > "$KC/$1/$2"
}
item "Claude Code-credentials" tester $(( 20 * 86400 ))
item claude-swap account-1-work@example.com $(( 9 * 86400 ))       # stale backup of the active one
item claude-swap account-2-personal@example.com $(( 2 * 86400 ))

out="$("$SG" logins --refresh)"
assert_eq "$(printf '%s' "$out" | jq -r '.accounts[0] | "\(.slot) \(.source) \(.state) \(.active)"')" "1 live ok true" "active account: read from the live item, not cswap's backup"
assert_eq "$(printf '%s' "$out" | jq -r '.accounts[0].endsAt')" "$(( NOW + 20 * 86400 ))" "end date in epoch seconds"
assert_eq "$(printf '%s' "$out" | jq -r '.accounts[1] | "\(.slot) \(.label) \(.source) \(.state)"')" "2 personal backup soon" "other account: cswap's backup, 2 days left = soon"
assert_absent "$out$(cat "$B/cache/logins.json")" "SECRET" "no token in the output or the cache"
assert_absent "$(cat "$HOME/security-argv")" "SECRET" "nor on any command line"
txt="$("$SG" logins --text)"
assert_contains "$txt" "account 2 (personal): login ends" "text view"
assert_contains "$txt" "renew now: swap-guard login 2" "with the renew command for an inactive account"
assert_contains "$txt" "account 1 (work, active): login ends" "active account marked"
assert_absent "$(printf '%s' "$txt" | sed -n 1p)" "renew" "no nag 20 days out"

# --cached never reads the keychain; a cache under an hour old is used as is.
: > "$HOME/security-argv"
"$SG" logins --cached >/dev/null; "$SG" logins >/dev/null
assert_eq "$(wc -c < "$HOME/security-argv" | tr -d ' ')" "0" "a fresh cache is reused (no keychain reads)"

# Preflight: hours from the end → login-ending; past it → relogin-required.
item claude-swap account-2-personal@example.com 10800
"$SG" logins --refresh >/dev/null
pre="$("$SG" preflight 2)"
assert_eq "$(printf '%s' "$pre" | jq -r .verdict)" "login-ending" "3 h left → preflight refuses (login-ending)"
assert_contains "$(printf '%s' "$pre" | jq -r .detail)" "swap-guard login 2" "and says how to renew"
assert_eq "$(printf '%s' "$pre" | jq -r .loginEndsAt)" "$(( NOW + 10800 ))" "loginEndsAt reported"
assert_eq "$("$SG" preflight 1 | jq -r .verdict)" "ok" "20 days left → ok"
item claude-swap account-2-personal@example.com $(( 25 * 86400 ))   # renewed since the cache was written
assert_eq "$("$SG" preflight 2 | jq -r .verdict)" "ok" "before refusing on a cached date, preflight reads it again (a renewal counts at once)"
item claude-swap account-2-personal@example.com 10800
"$SG" logins --refresh >/dev/null
item claude-swap account-2-personal@example.com -3600
"$SG" logins --refresh >/dev/null
pre="$("$SG" preflight 2)"
assert_eq "$(printf '%s' "$pre" | jq -r .verdict)" "relogin-required" "past its end date → relogin-required"
assert_contains "$(printf '%s' "$pre" | jq -r .detail)" "login ended" "naming why"
assert_eq "$("$SG" logins --cached | jq -r '.accounts[1].state')" "ended" "state ended"

# Auto-swap: cswap picks the target; preflight's login-ending makes the tick hold off.
item claude-swap account-2-personal@example.com 10800
"$SG" logins --refresh >/dev/null
cat > "$STUB/cswap" <<'EOF'
#!/bin/bash
case "$*" in
  "list --json"*) printf '%s\n' '{"activeAccountNumber":1,"accounts":[
    {"number":1,"email":"work@example.com","alias":"work","active":true,"usageStatus":"ok"},
    {"number":2,"email":"personal@example.com","alias":"personal","active":false,"usageStatus":"ok"}]}';;
  "auto --once --dry-run"*) echo '{"event":"switch","trigger":"threshold","to":{"number":2,"email":"personal@example.com"}}';;
  "auto --once"*) echo "real-switch" >> "$HOME/auto-switched"; echo '{"event":"switch","to":{"number":2}}';;
  *) exit 9;;
esac
EOF
out="$("$SG" auto tick --no-notify)"
assert_eq "$(printf '%s' "$out" | jq -r '"\(.action) \(.reason)"')" "skipped login-ending" "auto-swap holds off instead of switching onto an ending login"
assert_eq "$([ -f "$HOME/auto-switched" ] && echo yes || echo no)" "no" "and never runs the real switch"
item claude-swap account-2-personal@example.com -3600

# Instant swap target picker skips it, picks it again once renewed.
LIST='{"activeAccountNumber":1,"accounts":[{"number":1,"active":true,"usageStatus":"ok","usage":{}},
  {"number":2,"active":false,"usageStatus":"ok","usage":{"fiveHour":{"pct":5},"sevenDay":{"pct":5}}}]}'
assert_eq "$( (. "$SG"; _rl_pick "$LIST" "" "$NOW") | jq -r '.number // empty')" "" "the instant swap never picks a login that is ending"
item claude-swap account-2-personal@example.com $(( 25 * 86400 ))
"$SG" logins --refresh >/dev/null
assert_eq "$( (. "$SG"; _rl_pick "$LIST" "" "$NOW") | jq -r '.number')" "2" "renewed → picked again"

# Keepalive: one notification a day per ending login, cleared once renewed.
item claude-swap account-2-personal@example.com $(( 2 * 86400 ))
out="$("$SG" keepalive tick)"
assert_eq "$(printf '%s' "$out" | jq -c .ending)" "[2]" "tick logs the ending login"
assert_contains "$(cat "$HOME/notified")" "personal's login ends in 1d" "a notification with time left"
assert_contains "$(cat "$HOME/notified")" "swap-guard login 2" "and the renew command"
"$SG" keepalive tick >/dev/null
assert_eq "$(wc -l < "$HOME/notified" | tr -d ' ')" "1" "only once a day"
item claude-swap account-2-personal@example.com $(( 25 * 86400 ))
"$SG" keepalive tick >/dev/null
assert_eq "$([ -f "$B/keepalive-ending-alerted-2" ] && echo kept || echo cleared)" "cleared" "renewed → the alert stamp clears"
item "Claude Code-credentials" tester 7200
rm -f "$HOME/notified"; "$SG" keepalive tick >/dev/null
assert_contains "$(cat "$HOME/notified")" "/login in Claude Code with the same account, then: cswap add" "the active account's renew is /login + cswap add"

# No deadline cases → unknown, never a false alarm.
item "Claude Code-credentials" tester none
item claude-swap account-2-personal@example.com 3600 $(( 30 * 86400 ))
out="$("$SG" logins --refresh)"
assert_eq "$(printf '%s' "$out" | jq -r '.accounts[0] | "\(.source) \(.state)"')" "live unknown" "an item without the field → unknown"
assert_eq "$(printf '%s' "$out" | jq -r '.accounts[1].state')" "unknown" "an access token outliving the date by days → no real deadline (Claude Code's rule)"
CLAUDE_CONFIG_DIR="$HOME/other" "$SG" logins --refresh > "$HOME/o.json"
assert_eq "$(jq -r '.accounts[0].source' "$HOME/o.json")" "backup" "custom CLAUDE_CONFIG_DIR → the live item isn't the default one; use the backup"

# A keychain read that hangs is cut off.
touch "$HOME/kc-hang"; t0="$(date +%s)"
SWAP_KEYCHAIN_TIMEOUT=1 "$SG" logins --refresh > "$HOME/o.json"
assert_le "$(( $(date +%s) - t0 ))" 6 "a hanging keychain read times out"
assert_eq "$(jq -r '.accounts[0] | "\(.source) \(.endsAt)"' "$HOME/o.json")" "previous $(( NOW + 9 * 86400 ))" "and keeps an account's last known date instead of forgetting it"
assert_eq "$(jq -r '.accounts[1] | "\(.source) \(.state)"' "$HOME/o.json")" "none unknown" "one with no known date stays unknown"
rm -f "$B/cache/logins.json"
SWAP_KEYCHAIN_TIMEOUT=1 "$SG" logins --refresh > "$HOME/o.json"
assert_eq "$(jq -r '[.accounts[].state] | unique | join(",")' "$HOME/o.json")" "unknown" "with nothing known before, it reads as unknown"
rm -f "$HOME/kc-hang"

# A control character in an alias (hand-edited sequence.json) can't shift fields into arithmetic.
cp "$B/sequence.json" "$HOME/seq.bak"
jq --arg a "$(printf 'x\037true\037now[$(touch %s)]' "$HOME/pwned")" '.accounts["2"].alias = $a' "$HOME/seq.bak" > "$B/sequence.json"
item claude-swap account-2-personal@example.com $(( 2 * 86400 ))
"$SG" logins --refresh --text >/dev/null 2>&1; "$SG" keepalive tick --no-notify >/dev/null 2>&1
printf '{"checkedAt":%s,"accounts":[{"slot":"2","label":"x\u001ftrue\u001fnow[$(touch %s)]","active":false,"endsAt":%s}]}' "$NOW" "$HOME/pwned" "$(( NOW + 3600 ))" > "$B/cache/logins.json"
"$SG" logins --cached --text >/dev/null 2>&1
bash "$REPO/doctor.sh" >/dev/null 2>&1
assert_eq "$([ -e "$HOME/pwned" ] && echo ran || echo no)" "no" "a crafted alias never runs as code (logins, keepalive, doctor)"
cp "$HOME/seq.bak" "$B/sequence.json"

# Statusline: active ended → line 1; other ending → its line.
cat > "$B/cache/logins.json" <<EOF
{"checkedAt":$NOW,"accounts":[{"slot":"1","endsAt":$(( NOW - 60 ))},{"slot":"2","endsAt":$(( NOW + 100000 ))}]}
EOF
sl="$(echo '{"model":{"display_name":"M"}}' | SWAP_CLAUDE_JSON=/dev/null bash "$SL" | strip_ansi)"
assert_contains "$(printf '%s\n' "$sl" | sed -n 1p)" "⚠ login ended" "statusline line 1: the active login ended"
assert_contains "$(printf '%s\n' "$sl" | grep personal)" "⚠ login ends 1d 3h" "other account's line: ends in about a day"
cat > "$B/cache/logins.json" <<EOF
{"checkedAt":$NOW,"accounts":[{"slot":"1","endsAt":$(( NOW + 9 * 86400 ))},{"slot":"2","endsAt":null}]}
EOF
sl="$(echo '{"model":{"display_name":"M"}}' | SWAP_CLAUDE_JSON=/dev/null bash "$SL" | strip_ansi)"
assert_absent "$sl" "login end" "nothing shown more than 3 days out or without a date"

# Doctor lists every account's end date and warns inside 3 days.
mkdir -p "$HOME/.local/bin"; ln -s "$SG" "$HOME/.local/bin/swap-guard"
item "Claude Code-credentials" tester $(( 20 * 86400 ))
item claude-swap account-2-personal@example.com $(( 2 * 86400 ))
doc="$(bash "$REPO/doctor.sh" 2>&1)"
assert_contains "$doc" "[ok]   account 1 (work): login ends" "doctor: a healthy end date"
assert_contains "$doc" "[warn] account 2 (personal): login ends" "doctor: warns inside 3 days"
assert_contains "$doc" "fix: swap-guard login 2" "with the fix"
assert_absent "$doc" "SECRET" "doctor never prints a token"

rm -rf "$HOME"
finish
