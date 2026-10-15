#!/bin/bash
# swap-guard checkpoint (PostToolUse): once the active account crosses its line
# (5h 90%, week 95%, a per-model limit 90%), each agent is told once to wrap up and
# save progress; silent otherwise. Subagents get their own, shorter note.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 1
B="$HOME/.claude-swap-backup"
NOW="$(date +%s)"
iso() { date -u -r $(( NOW + $1 )) '+%Y-%m-%dT%H:%M:%S.000000+00:00'; }
usage() { # usage <5h> <week> <fable> [week-reset-in]
  cat > "$B/cache/usage.json" <<EOF
{"schemaVersion":2,"accounts":{"1":{"fetchedAt":$NOW,"lastGood":{
  "five_hour":{"pct":$1,"resets_at":"$(iso 7200)"},
  "seven_day":{"pct":$2,"resets_at":"$(iso "${4:-200000}")"},
  "scoped":[{"name":"Fable","pct":$3,"resets_at":"$(iso 200000)"}]}}}}
EOF
  T=$(( ${T:-0} + 2 )); touch -t "$(date -r $(( NOW + T )) +%Y%m%d%H%M.%S)" "$B/cache/usage.json"   # a new mtime each time
}
hook() { # hook <session> [agent]
  if [ -n "${2:-}" ]; then printf '{"session_id":"%s","agent_id":"%s","tool_name":"Bash"}' "$1" "$2"
  else printf '{"session_id":"%s","tool_name":"Bash"}' "$1"; fi | "$SG" checkpoint --hook
}

usage 40 60 30
assert_eq "$(hook s1)" "" "far from every limit: silent"
usage 40 96 30
out="$(hook s1)"
assert_eq "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" "PostToolUse" "past the week line: a PostToolUse note"
ctx="$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)"
assert_contains "$ctx" "account work is at week 96%" "naming the account and window"
assert_contains "$ctx" "finish the step you are on, save progress" "telling it to wrap up and save"
assert_contains "$ctx" "do not start a new batch of subagents" "and not to start big new work"
assert_eq "$(hook s1)" "" "once per session, not on every tool call"
assert_contains "$(hook s2 | jq -r .hookSpecificOutput.additionalContext)" "week 96%" "each session gets its own note"
sub="$(hook s1 agent7 | jq -r .hookSpecificOutput.additionalContext)"
assert_contains "$sub" "You are a subagent: finish the task you are on and return your result now" "a subagent gets the short version"
assert_eq "$(hook s1 agent7)" "" "also once"
assert_contains "$(tail -n 1 "$B/auto.log")" '"source":"checkpoint"' "nudges are logged"

usage 91 60 30
assert_contains "$(hook s3 | jq -r .hookSpecificOutput.additionalContext)" "5h 91%" "the 5-hour line is 90%"
usage 40 60 92
assert_contains "$(hook s4 | jq -r .hookSpecificOutput.additionalContext)" "Fable 92%" "a per-model limit at 90%"
usage 40 94 30
assert_eq "$(hook s5)" "" "94% of the week is below its line"
usage 40 99 30 -60
assert_eq "$(hook s5)" "" "a window whose reset already passed doesn't count"

# A new window (a new reset time) can nudge the same session again.
usage 40 96 30 300000
assert_contains "$(hook s1 | jq -r .hookSpecificOutput.additionalContext)" "week 96%" "a new week window nudges again"

# The band is computed once per usage-cache change, not per tool call.
usage 40 96 30
hook s9 >/dev/null
st="$(cat "$B/cache/checkpoint.state")"
hook s10 >/dev/null
assert_eq "$(cat "$B/cache/checkpoint.state")" "$st" "an unchanged cache file → the stored band is reused (no jq)"
cp "$B/cache/usage.json" "$HOME/u" && sed 's/"pct":96/"pct":10/' "$HOME/u" > "$B/cache/usage.json.new" && mv "$B/cache/usage.json.new" "$B/cache/usage.json"
assert_eq "$(hook s11)" "" "a rewritten cache (cswap's atomic replace) is read again, even within the same second"

usage 40 96 30
"$SG" checkpoint off >/dev/null
assert_eq "$(hook s20)" "" "checkpoint off → silent"
assert_eq "$("$SG" checkpoint status | jq -r .checkpoint)" "false" "status says off"
"$SG" checkpoint on >/dev/null
assert_eq "$(CLAUDE_CODE_OAUTH_TOKEN=x hook s21)" "" "a token job (another account) is never nudged"
assert_contains "$(hook s21)" "week 96%" "on again → nudges"
assert_eq "$(printf '{"tool_name":"Bash"}' | "$SG" checkpoint --hook)" "" "no session id → silent"
jq --arg a "$(printf 'x\033[31m|y')" '.accounts["1"].alias = $a' "$B/sequence.json" > "$HOME/s" && mv "$HOME/s" "$B/sequence.json"
usage 40 97 30
assert_contains "$(hook s22 | jq -r .hookSpecificOutput.additionalContext)" "account x[31my is at week 97%" "control characters and the field separator are stripped from the label"

usage 40 98 30
chmod 555 "$B/ctx"
hook s30 >/dev/null 2>&1
assert_eq "$(hook s30 2>/dev/null)" "" "an unwritable state dir → silent, never a note on every call"
chmod 755 "$B/ctx"

rm -rf "$HOME"
finish
