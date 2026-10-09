#!/bin/bash
# doctor.sh account classification: unaliased accounts, dead vs transient tokens.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 1
STUB="$HOME/stubbin"; mkdir -p "$STUB"
cat > "$STUB/cswap" <<'EOF'
#!/bin/bash
case "$1" in
  --version) echo "claude-swap 0.26.0" ;;
  list) echo '{"activeAccountNumber":1,"accounts":[
    {"number":1,"alias":"work","email":"work@example.com","active":true,"usageStatus":"token_expired"},
    {"number":2,"email":"personal@example.com","active":false,"usageStatus":"relogin_required"}]}' ;;
esac
EOF
chmod +x "$STUB/cswap"
export PATH="$STUB:$PATH" SWAP_GUARD_NO_LAUNCHCTL=1
out="$(bash "$REPO/doctor.sh" 2>&1)"
assert_contains "$out" "[warn] account 2 (personal): token dead (relogin_required)" "an account without an alias still shows its dead token"
assert_contains "$out" "swap-guard login 2" "with the safe re-login as the fix"
assert_contains "$out" "[ok]   account 1 (work): token_expired" "token_expired is transient, not dead"
pre="$("$SG" preflight 1)"
assert_eq "$(printf '%s' "$pre" | jq -r .verdict)" "ok" "preflight agrees: token_expired is not relogin-required"
rm -rf "$HOME"
finish
