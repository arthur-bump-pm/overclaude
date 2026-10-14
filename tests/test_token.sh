#!/bin/bash
# swap-guard token: setup-token output is passed through with the token masked,
# the token reaches the keychain via stdin only, and run/list/rm work.
# Stub claude + security: the real keychain and network are never touched.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 1
command -v python3 >/dev/null 2>&1 || { echo "test_token.sh: SKIPPED (no python3)"; exit 0; }

STUB="$HOME/stubbin"; mkdir -p "$STUB"
TOK="sk-ant-oat01-$(printf 'Ab9_-%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)xyz"
TOK2="sk-ant-oat01-$(printf 'Zz8_-%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20)xyz"
# A fake claude. setup-token prints the token the ways a terminal renderer might:
# split across writes, styled mid-token (ANSI), hard-wrapped, or repainted. `-p`
# is logged: verification must be a direct API request, never a claude run.
cat > "$STUB/claude" <<EOF
#!/bin/bash
if [ "\$1" = -p ]; then touch "\$HOME/claude-p-called"; exit 0; fi
[ "\$1" = setup-token ] || exit 9
nap() { perl -e 'select(undef,undef,undef,0.2)'; }
T="$TOK"
echo "Browser didn't open? Use the url below to sign in:"
echo "https://claude.ai/oauth/authorize?code=true&state=abc123"
nap
case "\${STUB_MODE:-split}" in
  none)    echo "Sign-in cancelled"; exit 1;;
  two)     echo "token: \$T"; echo "token: $TOK2"; exit 0;;
  bad)     echo "token: sk-ant-oat01-NOTREALNOTREALNOTREAL123"; exit 0;;
  split)   printf 'Your OAuth token (valid for 1 year): sk-ant-o'; nap
           printf '%s' "\${T#sk-ant-o}" | cut -c1-20 | tr -d '\n'; nap
           printf '%s\n' "\${T#sk-ant-o}" | cut -c21-;;
  ansi)    printf 'Token: \033[1m%s\033[22m\033[32m%s\033[0m\n' "\$(printf %s "\$T" | cut -c1-30)" "\$(printf %s "\$T" | cut -c31-)";;
  wrap)    printf 'Token:\r\n%s\r\r\n\033[2K%s\r\n' "\$(printf %s "\$T" | cut -c1-40)" "\$(printf %s "\$T" | cut -c41-)";;
  tailtext) printf 'Token: %s done\n' "\$T";;
  badwrap) printf 'Token:\r\n%s\r\r\n%s\r\n' "\$(printf %s "\$T" | cut -c1-40)" "\$(printf %s "\$T" | cut -c41- | tr 'A' 'Q')";;
  repaint) printf 'Token: %s' "\$(printf %s "\$T" | cut -c1-50)"; nap; printf '\033[1G\033[KToken: %s\n' "\$T";;
esac
printf 'Use it with: export CLAUDE_CODE_OAUTH_TOKEN=<token>\n'
echo "Store this token securely. Done"
echo "Store this token securely."
EOF
chmod +x "$STUB/claude"
cat > "$STUB/security" <<'EOF'
#!/bin/bash
all="$*"; echo "$all" >> "$HOME/security-argv"
a=""; s=""; while [ $# -gt 0 ]; do case "$1" in -a) a="$2"; shift;; -s) s="$2"; shift;; esac; shift; done
f="$HOME/keychain-$s-$a"
case "$all" in
  *add-generic-password*)    IFS= read -r p1; IFS= read -r p2; [ "$p1" = "$p2" ] || exit 1; printf '%s' "$p1" > "$f";;
  *find-generic-password*)   [ -f "$f" ] && cat "$f" || exit 44;;
  *delete-generic-password*) [ -f "$HOME/kc-locked" ] && exit 51; rm -f "$f";;
esac
EOF
chmod +x "$STUB/security"
export PATH="$STUB:$PATH" SWAP_TOKEN_TEST=1 SWAP_TOKEN_NO_PROBE=1 SWAP_TOKEN_TEST_VALID="$TOK"
B="$HOME/.claude-swap-backup"

out="$("$SG" token add work < /dev/null 2>&1)"
assert_contains "$out" '"saved":true' "token add saves the token"
assert_contains "$out" "https://claude.ai/oauth/authorize?code=true&state=abc123" "the sign-in URL is shown"
assert_absent "$out" "Ab9_-Ab9_" "no part of the token reaches the screen"
assert_absent "$out" "sk-ant-" "not even its prefix"
assert_absent "$out" "Store this token securely" "setup-token's own output is never passed through"
assert_eq "$(cat "$HOME/keychain-overclaude-token-work@example.com")" "$TOK" "the keychain holds the whole token, under the slot's email"
assert_absent "$(cat "$HOME/security-argv")" "Ab9_" "the token is never on a command line (ps can't see it)"
assert_eq "$(jq -r '."work@example.com".expires - ."work@example.com".created' "$B/tokens.json")" "31536000" "expiry recorded (one year)"
assert_absent "$(cat "$B/tokens.json")" "Ab9_" "tokens.json holds no secret"
assert_eq "$(ls "$B" | grep -c '^token\.')" "0" "no temp files left behind"

# Renderer cases from review: styled mid-token, hard-wrapped, repainted.
for mode in ansi wrap repaint tailtext; do
  rm -f "$HOME/keychain-overclaude-token-personal@example.com"
  out="$(STUB_MODE=$mode "$SG" token add personal < /dev/null 2>&1)"
  assert_absent "$out" "Ab9_" "$mode: nothing of the token on screen"
  assert_eq "$(cat "$HOME/keychain-overclaude-token-personal@example.com" 2>/dev/null)" "$TOK" "$mode: the exact full token is stored"
done
rm -f "$HOME/keychain-overclaude-token-personal@example.com"
out="$(STUB_MODE=bad "$SG" token add personal < /dev/null 2>&1)"
assert_contains "$out" '"error":"token-did-not-work"' "a token that fails a test request is refused"
assert_eq "$([ -f "$HOME/keychain-overclaude-token-personal@example.com" ] && echo yes || echo no)" "no" "and never stored"
assert_absent "$out" "NOTREAL" "and its text is hidden in the error tail"
out="$(STUB_MODE=badwrap "$SG" token add personal < /dev/null 2>&1)"
assert_contains "$out" '"error":"token-did-not-work"' "a wrapped token the API rejects is refused"
assert_absent "$out" "9_-Qb9_" "and neither half of it is printed in the error tail"
assert_absent "$out" "Ab9_" "(first half either)"

assert_eq "$([ -f "$HOME/claude-p-called" ] && echo yes || echo no)" "no" "verification never runs claude (settings/hooks can't vouch)"

l="$("$SG" token list)"
assert_eq "$(printf '%s' "$l" | jq -r '.[0].account')" "work@example.com" "token list names the account"
assert_le "364" "$(printf '%s' "$l" | jq -r '.[0].daysLeft')" "and shows the days left"
assert_absent "$l" "Ab9_" "list never shows the token"

assert_eq "$("$SG" token run 1 -- /bin/sh -c 'printf %s "$CLAUDE_CODE_OAUTH_TOKEN"')" "$TOK" "token run hands the token to the command's environment"
"$SG" token run personal -- /usr/bin/true 2>/dev/null
assert_eq "$?" "1" "token run without a token refuses"
"$SG" token run work 2>/dev/null
assert_eq "$?" "2" "token run without a command refuses"

out="$(STUB_MODE=none "$SG" token add personal < /dev/null 2>&1)"
assert_contains "$out" '"error":"no-token"' "cancelled sign-in → no-token"
assert_eq "$([ -f "$HOME/keychain-overclaude-token-personal@example.com" ] && echo yes || echo no)" "no" "and nothing saved"
out="$(STUB_MODE=two "$SG" token add personal < /dev/null 2>&1)"
assert_contains "$out" '"error":"several-tokens"' "two different tokens → refuse"
assert_absent "$out" "Zz8_" "and neither is shown"
assert_contains "$out" "[hidden]" "the error tail masks token-like text"
assert_eq "$([ -f "$HOME/keychain-overclaude-token-personal@example.com" ] && echo yes || echo no)" "no" "and nothing saved"
"$SG" token add 'bad name;rm' < /dev/null >/dev/null 2>&1
assert_eq "$?" "1" "an unusable account name is refused"

touch "$HOME/kc-locked"
o="$("$SG" token rm work)"; rc=$?
assert_eq "$rc:$(printf '%s' "$o" | jq -r .error)" "1:delete-failed" "a delete the keychain refuses is reported, not claimed"
assert_contains "$("$SG" token list)" "work@example.com" "and the token stays listed (never orphaned)"
rm -f "$HOME/kc-locked"
"$SG" token rm work >/dev/null
assert_eq "$([ -f "$HOME/keychain-overclaude-token-work@example.com" ] && echo yes || echo no)" "no" "token rm deletes the keychain item"
assert_absent "$("$SG" token list)" "work@example.com" "and the metadata"

rm -rf "$HOME"
finish
