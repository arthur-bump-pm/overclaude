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
        S="$HOME/.claude-swap-backup/sequence.json"
        jq --arg t "$(date +%s)$RANDOM" '.lastUpdated = $t' "$S" > "$S.t" && mv "$S.t" "$S"
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

out="$("$SG" login work 2>/dev/null)"; rc=$?
assert_eq "$rc" "0" "re-login succeeds"
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
"$SG" login --new >/dev/null 2>&1
assert_contains "$(sed -n 3p "$LOG")" "cswap add cfg=$HOME/.claude-swap-backup/login." "--new registers the throwaway profile as a new account"

rm -rf "$HOME"
finish
