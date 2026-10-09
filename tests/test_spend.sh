#!/bin/bash
# swap-guard spend: API-price value of usage, de-duplicated, attributed to accounts, vs plan cost.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 2
ST="$HOME/.claude-swap-backup"; NOW=$(date +%s); D=86400
mkdir -p "$ST/configs"
echo '{"oauthAccount":{"organizationRateLimitTier":"default_claude_max_20x"}}' > "$ST/configs/.claude-config-1-work@example.com.json"
echo '{"oauthAccount":{"organizationRateLimitTier":"default_claude_max_5x"}}'  > "$ST/configs/.claude-config-2-personal@example.com.json"
loc() { date -r "$1" '+%Y-%m-%d %H:%M:%S'; }
iso() { date -u -r "$1" '+%Y-%m-%dT%H:%M:%S.000Z'; }
{ echo "$(loc $((NOW - 4 * D))),100 - INFO - Switched from account 2 to 1"
  echo "$(loc $((NOW - 5 * D / 2))),100 - INFO - Switched from account 1 to 2"; } > "$ST/claude-swap.log"

T="$HOME/.claude/projects/-w"; mkdir -p "$T/s1/subagents"
msg() { # msg <id> <epoch> <model> <in> <cw5> <cw1h> <cr> <out> [speed]
  jq -cn --arg id "$1" --arg ts "$(iso "$2")" --arg m "$3" --argjson i "$4" --argjson c5 "$5" --argjson c1 "$6" --argjson cr "$7" --argjson o "$8" --arg sp "${9:-standard}" \
    '{type:"assistant", timestamp:$ts, sessionId:"s1", message:{id:$id, model:$m,
      usage:{input_tokens:$i, cache_creation_input_tokens:($c5+$c1), cache_read_input_tokens:$cr, output_tokens:$o,
             cache_creation:{ephemeral_5m_input_tokens:$c5, ephemeral_1h_input_tokens:$c1}, speed:$sp}}}'
}
{ msg A $((NOW - 3 * D)) claude-opus-5-5 1000000 0 0 0 1000000          # work:  $4 in + $20 out
  msg A $((NOW - 3 * D)) claude-opus-5-5 1000000 0 0 0 1000000          # same id again (streaming) → once
  msg B $((NOW - 2 * D)) claude-fable-5-1 0 0 1000000 1000000 0         # personal: $20 1h-write + $0.25 read
  msg Z $((NOW - 9 * D)) claude-fable-5-1 1000000 0 0 0 0               # outside the 7-day window
  msg S $((NOW - D)) "<synthetic>" 5 0 0 0 5                            # not a real model call
  msg U $((NOW - D)) gpt-x 1000 0 0 0 1000                              # no price known
} > "$T/s1.jsonl"
msg C $((NOW - D)) claude-haiku-5-5 200000 0 0 0 0 > "$T/s1/subagents/a1.jsonl"   # >100K prompt → $0.50/M = $0.10

o="$("$SG" spend --days 7)"
assert_eq "$(printf '%s' "$o" | jq -r '.usd * 100 | round')" "4435" "total = 4 + 20 + 20 + 0.25 + 0.10 (dedupe, window, tiers)"
assert_eq "$(printf '%s' "$o" | jq -r '.messages')" "3" "synthetic, unpriced and out-of-window messages are not counted"
assert_eq "$(printf '%s' "$o" | jq -r '.byAccount[] | select(.slot=="1") | .usd * 100 | round')" "2400" "usage before the switch → work"
assert_eq "$(printf '%s' "$o" | jq -r '.byAccount[] | select(.slot=="2") | .usd * 100 | round')" "2035" "usage after the switch → personal"
assert_eq "$(printf '%s' "$o" | jq -r '.byAccount[] | select(.slot=="1") | .planUsd')" "46.15" "Max 20x = \$200/month → \$46.15 per 7 days"
assert_eq "$(printf '%s' "$o" | jq -r '.byAccount[] | select(.slot=="2") | .planUsd')" "23.08" "Max 5x = \$100/month → \$23.08 per 7 days"
assert_eq "$(printf '%s' "$o" | jq -r '.ratio')" "0.6" "ratio = value / plan cost"
assert_eq "$(printf '%s' "$o" | jq -r '.planUsd')" "69.23" "plan cost counts every registered account"
assert_eq "$(printf '%s' "$o" | jq -r '.unpricedModels[0].model')" "gpt-x" "unpriced models are listed, not guessed"
assert_eq "$(printf '%s' "$o" | jq -r '.byModel[0].model')" "claude-opus-5-5" "byModel sorted by cost"
assert_eq "$(printf '%s' "$o" | jq -r '.byDay | length')" "3" "per-day breakdown"
assert_eq "$(jq -r '.usd * 100 | round' "$ST/cache/spend.json")" "4435" "result cached for the statusline"

printf '{"type":"assistant","message":{"id":"T","model":"claude-opus-5-5","usage":{"output_tok' >> "$T/s1.jsonl"; echo '"output_tokens"' >> "$T/s1.jsonl"
assert_eq "$("$SG" spend | jq -r '.usd * 100 | round')" "4435" "a torn line is skipped, the rest of the transcript still counts"
echo '{"1": "."}' > "$ST/plans.json"
"$SG" spend >/dev/null
assert_eq "$(jq -r '.usd * 100 | round' "$ST/cache/spend.json")" "4435" "a bad plans.json value never empties the cached result"
echo '{"2": 50}' > "$ST/plans.json"
assert_eq "$("$SG" spend | jq -r '.byAccount[] | select(.slot=="2") | .planUsd')" "11.54" "plans.json overrides a plan price"

msg F $((NOW - 600)) claude-opus-5-5 0 0 0 0 1000000 fast >> "$T/s1.jsonl"
assert_eq "$("$SG" spend | jq -r '.usd * 100 | round')" "8435" "a changed transcript is re-extracted; fast mode priced at \$40/M out"

out="$(echo '{"model":{"display_name":"M"},"context_window":{"used_percentage":1}}' | SWAP_NO_REFRESH=1 bash "$SL" | strip_ansi)"
assert_contains "$out" "💵 \$84/7d" "statusline shows the 7-day API value"
assert_absent "$(echo '{"model":{"display_name":"M"}}' | SWAP_NO_REFRESH=1 SWAP_HIDE_SPEND=1 bash "$SL" | strip_ansi)" "💵" "SWAP_HIDE_SPEND hides it"

rm -rf "$HOME"
finish
