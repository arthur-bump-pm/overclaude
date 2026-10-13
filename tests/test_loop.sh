#!/bin/bash
# swap-guard loop-guard: opt-in PostToolUseFailure hook; same call + same error 3x in a
# row → rethink note (exit 2), 6x → stop note, silent otherwise; registered by the fragment.
. "$(dirname "$0")/lib.sh"
new_home
B="$HOME/.claude-swap-backup"
# ev <session> <command> <error> [description] [is_interrupt]
ev() { jq -cn --arg s "$1" --arg c "$2" --arg e "$3" --arg d "${4:-run it}" --argjson i "${5:-false}" \
  '{session_id:$s, hook_event_name:"PostToolUseFailure", tool_name:"Bash", tool_input:{command:$c, description:$d}, error:$e, is_interrupt:$i}'; }
run() { ev "$@" | "$SG" loop-guard --hook 2>"$HOME/err"; rc=$?; }

run s1 "npm test" "Exit code 1
Error: Cannot find module 'express'"
run s1 "npm test" "Exit code 1
Error: Cannot find module 'express'"
run s1 "npm test" "Exit code 1
Error: Cannot find module 'express'"
assert_eq "$rc" "0" "off by default: silent on a third repeat"
assert_eq "$("$SG" loop-guard status | jq -r .loopGuard)" "false" "status says off"

"$SG" loop-guard on >/dev/null
E="Exit code 1
FAIL test/a.js (1.24 s) at line 17"
run s2 "npm test" "$E"
assert_eq "$rc" "0" "first failure: silent"
run s2 "npm test" "Exit code 1
FAIL   test/a.js (0.98 s) at line 18" "rerun the tests"
assert_eq "$rc" "0" "second (timings, line numbers, spacing and description differ): silent"
run s2 "npm test" "$E"
assert_eq "$rc" "2" "third identical failure → note to Claude (exit 2)"
assert_contains "$(cat "$HOME/err")" "failed the same way 3 times in a row" "the note counts the repeats"
assert_contains "$(cat "$HOME/err")" "try a different approach" "and asks for a different approach"
assert_contains "$(tail -n 1 "$B/auto.log")" '"rethink"' "and is logged"
run s2 "npm test" "$E"; run s2 "npm test" "$E"
assert_eq "$rc" "0" "fourth and fifth: silent (no nagging)"
run s2 "npm test" "$E"
assert_eq "$rc" "2" "sixth → second note"
assert_contains "$(cat "$HOME/err")" "Stop retrying it and tell the user" "which says to stop and tell the user"
run s2 "npm test" "$E"
assert_eq "$rc" "0" "seventh: silent"

run s3 "npm test" "$E"; run s3 "npm test" "$E"
run s3 "npm test" "Exit code 1
Error: something else entirely"
run s3 "npm test" "$E"
assert_eq "$rc" "0" "a different error in between resets the count"
assert_eq "$(cut -d' ' -f2 "$B/ctx/s3.loop")" "1" "count is back to 1"
run s4 "npm test" "$E"; run s4 "npm test" "$E"; run s4 "npm test --watch" "$E"
assert_eq "$rc" "0" "a different command is a different call"
run s5 "npm test" "$E"; run s5 "npm test" "$E"; run s6 "npm test" "$E"
assert_eq "$rc" "0" "counts are per session"
run s7 "npm test" "$E" x true; run s7 "npm test" "$E" x true; run s7 "npm test" "$E" x true
assert_eq "$rc" "0" "interrupts never count"
SWAP_LOOP_MAX=2 run s8 "make" "$E"; SWAP_LOOP_MAX=2 run s8 "make" "$E"
assert_eq "$rc" "2" "SWAP_LOOP_MAX changes the threshold"
# Subagents share the session id but keep their own count.
sub() { jq -cn --arg a "$1" --arg e "$2" '{session_id:"s10", agent_id:$a, tool_name:"Grep", tool_input:{pattern:"x", path:"/nope"}, error:$e}' | "$SG" loop-guard --hook 2>/dev/null; rc=$?; }
sub a1 "Path does not exist"; sub a2 "Permission denied"; sub a1 "Path does not exist"; sub a2 "Permission denied"
sub a1 "Path does not exist"
assert_eq "$rc" "2" "interleaved subagents don't reset each other's count"
sub a3 "Path does not exist"
assert_eq "$rc" "0" "and don't add to each other's count either"
run s11 "npm test" "$E"; run s11 "npm test" "$E"
read -r sg c _ < "$B/ctx/s11.loop"; printf '%s %s %s\n' "$sg" "$c" "$(( $(date +%s) - 1900 ))" > "$B/ctx/s11.loop"
run s11 "npm test" "$E"
assert_eq "$rc" "0" "a repeat more than 30 min after the last one starts over"
SWAP_LOOP_MAX=09 run s12 "make" "$E"
assert_eq "$rc" "0" "a leading-zero SWAP_LOOP_MAX doesn't break the hook"
assert_eq "$(cat "$HOME/err")" "" "and prints nothing"
run s13 "make" "$E"; chmod 000 "$B/ctx/s13.loop"
run s13 "make" "$E"
assert_eq "$rc:$(cat "$HOME/err")" "0:" "an unreadable state file: silent, exit 0"
chmod 600 "$B/ctx/s13.loop"
printf '{"session_id":"../../x","tool_name":"Bash","tool_input":{},"error":"e"}' | "$SG" loop-guard --hook 2>/dev/null
assert_eq "$([ -e "$B/x.loop" ] || [ -e "$HOME/x.loop" ] && echo leaked || echo ok)" "ok" "session id cannot escape the state dir"
printf 'not json' | "$SG" loop-guard --hook 2>/dev/null
assert_eq "$?" "0" "garbage input: silent, exit 0"
"$SG" loop-guard off >/dev/null
run s9 "npm test" "$E"; run s9 "npm test" "$E"; run s9 "npm test" "$E"
assert_eq "$rc" "0" "off again → silent"

f="$(jq -c '.hooks.PostToolUseFailure[0] | {matcher, command: .hooks[0].command}' "$REPO/settings/settings-fragment.json")"
assert_eq "$f" '{"matcher":null,"command":"~/.local/bin/swap-guard loop-guard --hook"}' "fragment registers the hook for every tool"

rm -rf "$HOME"
finish
