#!/bin/bash
# swap-guard login: the live account's token is captured first and never overwritten.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 2   # 1=work (dead), 2=personal (live)

STUB="$HOME/stubbin"; mkdir -p "$STUB"; LOG="$HOME/calls"
cat > "$STUB/cswap" <<'EOF'
#!/bin/bash
case "$1" in
  list) [ -n "${STUB_LIST_FAIL:-}" ] && exit 1
        echo '{"activeAccountNumber":2,"accounts":[{"number":1,"active":false},{"number":2,"active":true}]}' ;;
  add)  echo "cswap $* cfg=${CLAUDE_CONFIG_DIR:-default}" >> "$HOME/calls"
        [ -z "${CLAUDE_CONFIG_DIR:-}" ] && exit "${STUB_CAPTURE_RC:-0}"
        # Like real cswap: an org change asks y/N; with no terminal it prints Cancelled, exits 0.
        if [ -n "${STUB_CANCEL:-}" ]; then echo "Overwrite slot? [y/N] Cancelled"; exit 0; fi
        if [ -n "${STUB_ASK:-}" ]; then   # like cswap: ask, cancel unless a terminal answers y
          printf 'Overwrite slot? [y/N] '; read -r ans 2>/dev/null || ans=""
          [ "$ans" = y ] || { echo Cancelled; exit 0; }
        fi
        S="$HOME/.claude-swap-backup/sequence.json"
        case " $* " in *" --slot "*) f='.' ;; *) f='.accounts["3"] = {"email":"new@example.com"}' ;; esac
        jq --arg t "$(date +%s)$RANDOM" "$f | .lastUpdated = \$t" "$S" > "$S.t" && mv "$S.t" "$S"
        exit 0 ;;
esac
EOF
cat > "$STUB/claude" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "auth login")  echo "claude auth login ${*:3} cfg=${CLAUDE_CONFIG_DIR:-default}" >> "$HOME/calls" ;;
  "auth status") printf '{"loggedIn":true,"email":"%s"}\n' "${STUB_AS:-work@example.com}" ;;
esac
EOF
cat > "$STUB/security" <<'EOF'
#!/bin/bash
echo "security $*" >> "$HOME/calls"
EOF
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

echo '{"checkedAt":1,"accounts":[{"slot":"1","endsAt":5},{"slot":"2","endsAt":9}]}' > "$HOME/.claude-swap-backup/cache/logins.json"
out="$("$SG" login work 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "re-login succeeds"
assert_eq "$(jq -c '[.accounts[].slot]' "$HOME/.claude-swap-backup/cache/logins.json")" '["2"]' "a new sign-in drops that account's cached end date (only that one)"
assert_eq "$(printf '%s' "$out" | jq -r .liveUntouched)" "true" "result says the live login was untouched"
assert_eq "$(sed -n 1p "$LOG")" "cswap add cfg=default" "step 1: the live account's token is captured first"
assert_contains "$(sed -n 2p "$LOG")" "claude auth login --email work@example.com cfg=$HOME/.claude-swap-backup/login." "step 2: sign-in happens in a throwaway profile"
assert_contains "$(sed -n 3p "$LOG")" "cswap add --slot 1 cfg=$HOME/.claude-swap-backup/login." "step 3: the throwaway profile is registered into the slot"
assert_eq "$(sed -n 4p "$LOG")" "cswap add cfg=default" "step 4: cswap is re-anchored on the live account"
tmpdir="$(sed -n 2p "$LOG" | sed 's/.*cfg=//')"
want="Claude Code-credentials-$(printf '%s' "$tmpdir" | shasum -a 256 | cut -c1-8)"
assert_eq "$(sed -n 5p "$LOG")" "security delete-generic-password -s $want" "the throwaway keychain item is deleted"
assert_eq "$([ -d "$tmpdir" ] && echo exists || echo gone)" "gone" "the throwaway profile dir is deleted"
assert_absent "$(cat "$LOG")" "auth login --email work@example.com cfg=default" "the default profile is never signed into"

: > "$LOG"
out="$(STUB_AS=someone@example.com "$SG" login work 2>/dev/null)"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "wrong-account" "signing in as the wrong account is refused"
assert_absent "$(cat "$LOG")" "--slot" "nothing is registered after a wrong sign-in"

: > "$LOG"
out="$(STUB_CAPTURE_RC=1 "$SG" login work 2>/dev/null)"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "capture-failed" "a failed capture stops everything"
assert_absent "$(cat "$LOG")" "auth login" "no sign-in after a failed capture"

: > "$LOG"
out="$(STUB_CANCEL=1 "$SG" login work 2>/dev/null)"; rc=$?
assert_eq "$(printf '%s' "$out" | jq -r .error)" "cswap-add-cancelled" "a cancelled cswap add is reported, never success"
assert_eq "$rc" "1" "cancelled add exits 1"

: > "$LOG"
out="$(STUB_LIST_FAIL=1 "$SG" login work 2>/dev/null)"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "cswap-list-failed" "no live-account info → stop before anything changes"
assert_eq "$(cat "$LOG")" "" "nothing ran after cswap list failed"

jq '.accounts["3"] = {"email":"work@example.com","alias":"work2"}' "$HOME/.claude-swap-backup/sequence.json" > "$HOME/s.t" &&
  mv "$HOME/s.t" "$HOME/.claude-swap-backup/sequence.json"
assert_eq "$("$SG" login work@example.com 2>/dev/null | jq -r .error)" "ambiguous-target" "one email in two slots → ask for the slot number"
write_seq 2

out="$("$SG" login personal 2>/dev/null)"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "target-is-live" "re-logging the live account itself is redirected"
assert_eq "$("$SG" login nobody 2>/dev/null | jq -r .error)" "unknown-target" "unknown account refused"

: > "$LOG"
out="$(STUB_AS=new@example.com "$SG" login --new 2>/dev/null)"
assert_eq "$(printf '%s' "$out" | jq -r .slot)" "3" "--new reports the slot cswap assigned"
out="$(STUB_CANCEL=1 "$SG" login --new 2>/dev/null)"
assert_contains "$(printf '%s' "$out" | jq -r .detail)" "swap-guard login --new" "a cancelled --new names the right retry command"
write_seq 2

# In a real terminal cswap's y/N reaches the user (QA H2): answering y registers the slot.
if command -v expect >/dev/null 2>&1; then
  out="$(STUB_ASK=1 expect -c "set timeout 20; spawn -noecho $SG login work; expect {\[y/N\]} { send \"y\\r\" }; expect eof" 2>/dev/null |
         tr -d '\r' | sed $'s/\x1b\\[[0-9;]*m//g' | grep '^{' | tail -n 1)"
  assert_eq "$(printf '%s' "$out" | jq -r '.loggedIn // .error')" "work@example.com" "terminal run: the y/N confirmation is answerable"
  out="$(STUB_ASK=1 "$SG" login work 2>/dev/null < /dev/null)"
  assert_eq "$(printf '%s' "$out" | jq -r .error)" "cswap-add-cancelled" "no terminal: the confirmation cancels and says so"
fi

: > "$LOG"
"$SG" login --new >/dev/null 2>&1
assert_contains "$(sed -n 3p "$LOG")" "cswap add cfg=$HOME/.claude-swap-backup/login." "--new registers the throwaway profile as a new account"

# Chrome profile: the sign-in page opens in the profile for that account.
mkdir -p "$HOME/Applications/Google Chrome.app" "$HOME/Library/Application Support/Google/Chrome"
export SWAP_CHROME_APPS="$HOME/Applications/Google Chrome.app"
cat > "$HOME/Library/Application Support/Google/Chrome/Local State" <<'EOF'
{"profile":{"info_cache":{"Default":{"name":"Home","user_name":"someone@example.com"},
  "Profile 2":{"name":"Work stuff","user_name":"WORK@example.com"},"Profile 3":{"name":"Spare","user_name":""}}}}
EOF
cat > "$STUB/claude" <<'EOF'
#!/bin/bash
case "$1 $2" in
  "auth login")  echo "claude auth login ${*:3} cfg=${CLAUDE_CONFIG_DIR:-default}" >> "$HOME/calls"
                 if [ -n "${BROWSER:-}" ]; then cat "$BROWSER" > "$HOME/opener"; ls -l "$BROWSER" | cut -c1-10 > "$HOME/opener-mode"; else echo none > "$HOME/opener"; fi ;;
  "auth status") printf '{"loggedIn":true,"email":"%s"}\n' "${STUB_AS:-work@example.com}" ;;
esac
EOF
chmod +x "$STUB/claude"
out="$("$SG" login work 2>"$HOME/err")"
assert_contains "$(cat "$HOME/opener")" "--profile-directory=Profile\ 2" "the profile signed in to the same address (case-insensitive)"
assert_contains "$(cat "$HOME/opener")" 'open -na "Google Chrome"' "opened in Chrome"
assert_eq "$(cat "$HOME/opener-mode")" "-rwx------" "the opener is private"
assert_contains "$(cat "$HOME/err")" 'Chrome profile "Work stuff" (same address)' "and says which profile"
"$SG" browser set work Spare >/dev/null
assert_eq "$(jq -c . "$HOME/.claude-swap-backup/browser-profiles.json")" '{"work@example.com":"Profile 3"}' "browser set saves only the profile folder"
"$SG" login work >/dev/null 2>"$HOME/err"
assert_contains "$(cat "$HOME/opener")" "--profile-directory=Profile\ 3" "a saved choice wins"
assert_contains "$(cat "$HOME/err")" "(saved)" "and is named as saved"
"$SG" login work --profile Home >/dev/null 2>&1
assert_contains "$(cat "$HOME/opener")" "--profile-directory=Default" "--profile picks one for this run"
lst="$("$SG" browser list)"
assert_contains "$(printf '%s\n' "$lst" | grep '^Profile 3')" "used for work" "browser list shows which account uses which profile"
assert_contains "$(printf '%s\n' "$lst" | grep '^Profile 3')" "(not signed in)" "and profiles not signed in"
"$SG" browser clear work >/dev/null
assert_eq "$(jq -c . "$HOME/.claude-swap-backup/browser-profiles.json")" '{}' "browser clear forgets it"
"$SG" browser set work Nope >/dev/null 2>&1; assert_eq "$?" "1" "an unknown profile is refused"
"$SG" browser set wrok Spare >/dev/null 2>&1; assert_eq "$?" "1" "a misspelled account is refused, not saved"
"$SG" login work --profile=Spare >/dev/null 2>&1
assert_contains "$(cat "$HOME/opener")" "--profile-directory=Profile\ 3" "--profile=NAME works too"
SWAP_NO_CHROME_PROFILE=1 "$SG" login work >/dev/null 2>&1
assert_eq "$(cat "$HOME/opener")" "none" "SWAP_NO_CHROME_PROFILE=1 → the default browser"
rm -rf "$HOME/Applications/Google Chrome.app"
"$SG" login work >/dev/null 2>&1
assert_eq "$(cat "$HOME/opener")" "none" "no Chrome installed → the default browser, as before"
assert_absent "$(cat "$HOME/.claude-swap-backup/"*.log 2>/dev/null)" "someone@example.com" "Chrome's addresses are never logged"

rm -rf "$HOME"
finish
