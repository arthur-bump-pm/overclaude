#!/bin/bash
# swap-guard budget (UserPromptSubmit hook): one note per band change, silent otherwise.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 2
FUT="$(iso_in 86400)"; PAST="$(iso_in -60)"

cache() { # cache <p5h> <pweek> <pfable> [fable-reset] [work-extra-json]
  cat > "$HOME/.claude-swap-backup/cache/usage.json" <<EOF
{"schemaVersion":2,"accounts":{
 "2":{"lastGood":{"five_hour":{"pct":$1,"resets_at":"$FUT"},"seven_day":{"pct":$2,"resets_at":"$FUT"},
      "scoped":[{"name":"Fable","pct":$3,"resets_at":"${4:-$FUT}"}]}},
 "1":{${5:-}"lastGood":{"five_hour":{"pct":5,"resets_at":"$FUT"},"seven_day":{"pct":20,"resets_at":"$FUT"},
      "scoped":[{"name":"Fable","pct":12,"resets_at":"$FUT"}]}}}}
EOF
}
hook() { printf '{"session_id":"%s","prompt":"hi"}' "${1:-s1}" | "$SG" budget --hook; }

cache 10 50 40
assert_eq "$(hook)" "" "below every band → silent"

cache 10 50 82
out="$(hook)"
assert_contains "$out" "Fable 82% used (resets" "crossing Fable 75 → note with the reset time"
assert_contains "$out" "ULTRACODE budget pressure applies" "note carries the routing rule"
assert_contains "$out" "the user can /swap work" "note suggests the account with room"
assert_eq "$(hook)" "" "same band again → silent"
assert_contains "$(hook s2)" "Fable 82%" "a different session gets its own note"

cache 10 50 93
assert_contains "$(hook)" "Fable 93%" "next band (90) → a new note"

cache 10 50 100
STUBB="$HOME/stubb"; mkdir -p "$STUBB" "$HOME/.codex/hooks"; printf '#!/bin/bash\nexit 0\n' > "$STUBB/codex"; chmod +x "$STUBB/codex"
touch "$HOME/.codex/hooks/overcodex-handoff-inject.sh"
out="$(PATH="$STUBB:$PATH" hook)"
assert_contains "$out" "Fable is exhausted" "100% → exhausted wording"
assert_absent "$out" "/handoff codex" "one model bucket exhausted → no Codex suggestion (other models still work)"

cache 10 50 100 "$PAST"
out="$(hook)"
assert_contains "$out" "Budget pressure cleared" "reset passed → pressure cleared note"
assert_eq "$(hook)" "" "after clearing → silent"

cache 100 70 20
out="$(PATH="$STUBB:$PATH" hook)"
assert_contains "$out" "out of quota until the reset" "5h at 100% → account out of quota"
assert_absent "$out" "/handoff codex" "another Claude account has room → swap there, not Codex"
cache 100 70 20 "" '"lastError":"invalid_grant","authDeadStrikes":1,'
rm -f "$HOME/.claude-swap-backup/ctx/s1.budget"
assert_contains "$(PATH="$STUBB:$PATH" hook)" "/handoff codex" "whole account out and no Claude account usable → suggest Codex"

cache 10 50 82 "" '"lastError":"invalid_grant","authDeadStrikes":1,'
rm -f "$HOME/.claude-swap-backup/ctx/s9.budget"
assert_absent "$(hook s9)" "/swap work" "a dead account is never suggested"

# Alternatives must be usable and measured: no data, disabled and API-key accounts are never suggested.
cat > "$HOME/.claude-swap-backup/sequence.json" <<'EOF2'
{"activeAccountNumber": 2, "sequence": [1, 2, 3, 4],
 "accounts": {"1": {"email": "work@example.com", "alias": "work", "disabled": true},
              "2": {"email": "personal@example.com", "alias": "personal"},
              "3": {"email": "nodata@example.com", "alias": "nodata"},
              "4": {"email": "key@example.com", "alias": "apikey", "kind": "api_key"}}}
EOF2
cache 10 50 82
rm -f "$HOME/.claude-swap-backup/ctx/s10.budget"
out="$(hook s10)"
assert_contains "$out" "Fable 82%" "pressure still reported"
assert_absent "$out" "/swap" "no swap suggestion when no other account is usable and measured"
write_seq 2
assert_eq "$("$SG" budget | jq -r .pressure)" "true" "plain 'budget' reports pressure as JSON"
assert_eq "$(printf '{"prompt":"x"}' | "$SG" budget --hook)" "" "no session id → silent"

rm -rf "$HOME"
finish
