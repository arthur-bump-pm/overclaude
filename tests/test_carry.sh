#!/bin/bash
# Artifacts after an account change: a session is told (once) which artifacts IT
# published stay behind on the old account; `artifacts carry` lists them with saved
# sources. Other sessions' artifacts, ones already on this account and ones already
# copied are left out. Nothing is copied by the kit itself.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 1                 # work (1) active
B="$HOME/.claude-swap-backup"; I="$B/artifacts"; mkdir -p "$I/src/a1"
echo '<h1>chart</h1>' > "$I/src/a1/chart.html"
pub() { # pub <id> <session> <account-email> <slot> <title> [saved] [path]
  jq -cn --arg id "$1" --arg s "$2" --arg e "$3" --arg n "$4" --arg t "$5" --arg sv "${6:-}" --arg p "${7:-}" \
    '{ts: 100, kind: "publish", artifact_id: $id, url: ("https://claude.ai/code/artifact/" + $id), title: $t,
      path: (if $p == "" then null else $p end), account: $e, slot: $n, alias: null, sessionId: $s,
      saved: (if $sv == "" then null else $sv end)}' >> "$I/index.jsonl"
}
pub a1 S1 work@example.com 1 "Chart test" "$I/src/a1/chart.html"
pub a2 S1 work@example.com 1 "Villa picks" "" "$HOME/gone.html"
pub a3 S2 work@example.com 1 "Other session's page"
pub a4 S1 personal@example.com 2 "Already on personal"
pub a5 S1 work@example.com 1 "Copied before"
jq -cn '{ts:100, kind:"publish", artifact_id:"a7", url:"https://claude.ai/code/artifact/a7", title:"Owner unknown", account:null, sessionId:"S1"}' >> "$I/index.jsonl"
echo '{"kind":"link","from":"a5","to":"a6","ts":101}' >> "$I/index.jsonl"

prompt() { printf '{"session_id":"%s","prompt":"hi"}' "$1" | "$SG" budget --hook 2>/dev/null; }

# First prompt only remembers the account; no switch yet, nothing said.
out="$(prompt S1)"
assert_absent "$out" "moved from" "no note before any switch"
assert_eq "$(cat "$B/ctx/S1.acct")" "1" "the session's account is remembered"

write_seq 2                 # switched to personal (any way: /swap, auto, terminal)
out="$(prompt S1)"
assert_contains "$out" "this session moved from work to personal" "the next prompt says the account changed"
assert_contains "$out" "2 artifact(s) this session published belong to work" "counting only this session's artifacts still owned by work"
assert_contains "$out" "Chart test (https://claude.ai/code/artifact/a1)" "with titles and old links"
assert_absent "$out" "Other session" "never another session's artifacts"
assert_absent "$out" "Already on personal" "nor ones already on this account"
assert_absent "$out" "Copied before" "nor ones already copied"
assert_absent "$out" "Owner unknown" "nor ones whose owner was never recorded"
assert_contains "$out" "Do not copy them now" "copy only when needed"
assert_contains "$out" "swap-guard artifacts link" "and how to record the copy"
assert_absent "$(prompt S1)" "moved from" "said once, not on every prompt"
echo 1 > "$B/ctx/S3.acct"   # S3 was on work too, and published nothing
assert_absent "$(prompt S3)" "moved from" "a session with no artifacts is told nothing"

c="$("$SG" artifacts carry --session S1)"
assert_eq "$(printf '%s' "$c" | jq -r .account)" "personal" "carry: the account they'd be copied to"
assert_eq "$(printf '%s' "$c" | jq -r '[.artifacts[].url | sub(".*/"; "")] | join(",")')" "a1,a2" "carry lists exactly this session's left-behind artifacts"
assert_eq "$(printf '%s' "$c" | jq -r '.artifacts[] | select(.url | endswith("a1")) | .source')" "$I/src/a1/chart.html" "with the source saved at its last publish"
assert_contains "$(printf '%s' "$c" | jq -r '.artifacts[] | select(.url | endswith("a2")) | .note')" "no saved source" "and says when there's none"
"$SG" artifacts link "https://claude.ai/code/artifact/a1" "https://claude.ai/code/artifact/b1" >/dev/null
assert_eq "$("$SG" artifacts carry --session S1 | jq -r '[.artifacts[].url | sub(".*/"; "")] | join(",")')" "a2" "once copied and linked, it drops off the list"
assert_eq "$("$SG" artifacts carry 2>/dev/null | jq -r .error)" "no-session" "outside a session without --session → a clear error"

# Back on work: personal's artifact (a4) is now the one left behind.
write_seq 1
out="$(prompt S1)"
assert_contains "$out" "moved from personal to work" "switching back is noticed too"
assert_contains "$out" "Already on personal" "and now the personal-owned one stays behind"

# Three accounts: an artifact owned by a third account is named with its real owner.
jq '.accounts["3"] = {"email":"side@example.com","alias":"side"} | .sequence = [1,2,3]' "$B/sequence.json" > "$HOME/s" && mv "$HOME/s" "$B/sequence.json"
pub a8 S1 side@example.com 3 "Side project"
jq '.activeAccountNumber = 2' "$B/sequence.json" > "$HOME/s" && mv "$HOME/s" "$B/sequence.json"
out="$(prompt S1)"
assert_contains "$out" "belong to side, work and" "each owner is named (not all blamed on the account just left)"

rm -rf "$HOME"
finish
