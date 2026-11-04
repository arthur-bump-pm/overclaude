#!/bin/bash
. "$(dirname "$0")/lib.sh"
new_home
RUN="$REPO/bin/overclaude-codex-continue"
mkdir -p "$HOME/stubs" "$HOME/codex" "$HOME/work"
export PATH="$HOME/stubs:$PATH" TEST_CODEX_HOME="$HOME/codex" OVERCLAUDE_CODEX_HOME="$HOME/codex"
cat > "$HOME/stubs/swap-guard" <<'EOF'
#!/bin/bash
if [ -n "${TEST_READER_FAIL:-}" ] && [ -s "$HOME/reader.err" ]; then
  run_dir="$(sed -n 's/^Continuation output: //p' "$HOME/reader.err" | head -1)"
  [ -n "$run_dir" ] && mkdir "$run_dir/events.log"
fi
if [ -n "${TEST_EMPTY_ROUTE:-}" ]; then printf '{"route":"claude","eligible":false,"codex":{}}\n'; exit; fi
printf '{"route":"%s","eligible":%s,"codex":{"home":"%s","limitsKnown":false,"limitsFresh":false}}\n' "${TEST_ROUTE:-codex}" "${TEST_ELIGIBLE:-true}" "$TEST_CODEX_HOME"
EOF
# This suite exercises the unpinned fallback; never discover a live installed probe.
cat > "$HOME/stubs/overclaude-codex-probe" <<'EOF'
#!/bin/bash
exit 1
EOF
cat > "$HOME/stubs/ps" <<'EOF'
#!/bin/bash
[ "$4" = 99999999 ] && exit 1
printf 'Mon Nov  2 12:00:00 2026\n'
EOF
cat > "$HOME/stubs/codex" <<'EOF'
#!/bin/bash
printf '%s\n' "$CODEX_HOME $*" >> "$HOME/calls"
if [ -n "${TEST_NO_READ:-}" ]; then
  echo "$$" > "$HOME/nonreading-pid"
  sleep 30 & wait
  exit
fi
cat > "$HOME/input"
if [ -n "${TEST_DEEP_JSON:-}" ]; then
  python3 -c 'import sys; sys.stdout.write("[" * 1500 + "]" * 1500 + "\n" + "x" * 2100000 + "\n")'
fi
printf '%s\n' '{"type":"thread.started","thread_id":"01234567-89ab-4cde-8fab-0123456789ab"}' 'not json' '{"type":'
[ -n "${TEST_NO_REPORT:-}" ] && exit 0
while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then printf 'done\n' > "$2"; fi; shift; done
if [ -n "${TEST_PIPE_DESCENDANT:-}" ]; then
  sleep 30 & echo "$!" > "$HOME/pipe-descendant-pid"
  exit 0
fi
if [ -n "${TEST_DESCENDANT:-}" ]; then
  /bin/bash -c 'trap "" TERM HUP; echo "$$" > "$HOME/descendant-pid"; exec sleep 30' &
  wait
fi
if [ -n "${TEST_IGNORE_TERM:-}" ]; then
  trap '' TERM HUP
  echo "$$" > "$HOME/child-pid"
  sleep 30 & wait
fi
[ -n "${TEST_HOLD:-}" ] && sleep 3
exit "${TEST_EXIT:-0}"
EOF
chmod +x "$HOME/stubs/"*
cd "$HOME/work" || exit 1
make_package() {
  { printf '<!-- handoff cwd="%s" created="%s" -->\n' "$(pwd -P)" "${1:-$(date +%s)}"
    for h in 'Goal' 'Current state' 'Files touched' 'Work in flight' 'Next steps' 'Validation' 'Codex execution plan'; do printf '## %s\nReal details.\n' "$h"; done
  } > "$HOME/package.md"
}
make_package
cat > "$HOME/codex/models_cache.json" <<'EOF'
{"models":[null,{}, {"slug":"gpt-6.1-sol","supported_reasoning_levels":null},{"slug":"gpt-6.1-sol","supported_reasoning_levels":[{"effort":"high"}]},{"slug":"gpt-6-astra","supported_reasoning_levels":[{"effort":"xhigh"}]}]}
EOF
out="$($RUN --package "$HOME/package.md" --dry-run)"
assert_eq "$(printf '%s' "$out" | jq -r .model)" 'gpt-6.1-sol' 'standard model selected'
assert_eq "$(printf '%s' "$out" | jq -r .limitsKnown)" false 'route limit status exposed'
assert_contains "$(printf '%s' "$out" | jq -r .uncertainty)" 'unknown or stale' 'uncertainty exposed'
assert_eq "$("$RUN" --package "$HOME/package.md" --complexity complex --dry-run | jq -r .model)" 'gpt-6-astra' 'complex model selected'
[ ! -e "$HOME/calls" ] && pass || fail 'dry run does not launch'
out="$($RUN --package "$HOME/package.md")"
assert_eq "$(printf '%s' "$out" | jq -r .exit_code)" 0 'successful launch'
assert_contains "$(cat "$HOME/calls")" "$(cd "$HOME/codex" && pwd -P) exec -s workspace-write" 'pinned home and sandbox'
assert_contains "$(cat "$HOME/input")" 'Codex execution plan' 'package passed on stdin'
run_dir="$(printf '%s' "$out" | jq -r .output_dir)"
assert_eq "$(jq -r .state "$run_dir/state.json")" finished 'completion recorded'
status="$($RUN status --run "$run_dir" --json)"
assert_eq "$(printf '%s' "$status" | jq -r .thread_id)" '01234567-89ab-4cde-8fab-0123456789ab' 'thread id captured from events'
assert_eq "$(printf '%s' "$status" | jq -r .goal_verified)" false 'successful process does not establish goal completion'
assert_eq "$(printf '%s' "$status" | jq -r .final_message_present)" true 'final output recorded'
assert_eq "$(TEST_EMPTY_ROUTE=1 "$RUN" status --json | jq -r .cwd)" "$(pwd -P)" 'status works with ineligible empty route'
"$RUN" status --run "$HOME" --json >/dev/null 2>&1 && fail 'status rejects arbitrary path' || pass
TEST_NO_REPORT=1 "$RUN" --package "$HOME/package.md" > "$HOME/no-report" 2>/dev/null
no_report="$(jq -r .output_dir "$HOME/no-report")"
assert_eq "$(jq -r .final_message_present "$no_report/manifest.json")" false 'missing report disclosed'
assert_eq "$(jq -r .state "$no_report/manifest.json")" finished 'zero exit recorded without claiming verification'
python3 - "$no_report/manifest.json" <<'PYCODE'
import json, sys
path = sys.argv[1]
with open(path) as f: data = json.load(f)
data.update(state='running', runner_pid=99999999, runner_process_start='old')
with open(path, 'w') as f: json.dump(data, f)
PYCODE
assert_contains "$("$RUN" status --run "$no_report" --json | jq -r .process_observation)" 'not observed' 'abruptly stopped runner disclosed'
assert_eq "$(printf '%s' "$out" | jq -r .final_message)" "$run_dir/last-message.md" 'final message path exposed'
TEST_ROUTE=claude "$RUN" --package "$HOME/package.md" --dry-run >/dev/null 2>&1 && fail 'declined route' || pass
make_package "$(( $(date +%s) - 601 ))"
"$RUN" --package "$HOME/package.md" --dry-run >/dev/null 2>&1 && fail 'stale rejected' || pass
make_package
sed '1s/cwd="[^"]*"/cwd="\/wrong"/' "$HOME/package.md" > "$HOME/bad.md"
"$RUN" --package "$HOME/bad.md" --dry-run >/dev/null 2>&1 && fail 'wrong header rejected' || pass
sed '/Real details\./d' "$HOME/package.md" > "$HOME/bad.md"
"$RUN" --package "$HOME/bad.md" --dry-run >/dev/null 2>&1 && fail 'empty sections rejected' || pass
awk '/^## Files touched$|^## Work in flight$/{print; getline; print "None"; next} {print}' "$HOME/package.md" > "$HOME/none.md"
"$RUN" --package "$HOME/none.md" --dry-run >/dev/null 2>&1 && pass || fail 'None accepted in optional sections'
awk '/^## Goal$/{print; getline; print "None"; next} {print}' "$HOME/package.md" > "$HOME/none-bad.md"
"$RUN" --package "$HOME/none-bad.md" --dry-run >/dev/null 2>&1 && fail 'None rejected for goal' || pass
# FIFOs must be rejected promptly rather than blocking while opened.
mkfifo "$HOME/package.fifo"
"$RUN" --package "$HOME/package.fifo" --dry-run >/dev/null 2>&1 & fifo_pid=$!
(sleep 3; kill -KILL "$fifo_pid" 2>/dev/null) & watchdog=$!
wait "$fifo_pid"; fifo_code=$?
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
[ "$fifo_code" -eq 1 ] && pass || fail 'package FIFO rejected without hanging'
ln -s "$HOME/package.md" "$HOME/link.md"
"$RUN" --package "$HOME/link.md" --dry-run >/dev/null 2>&1 && fail 'symlink rejected' || pass
mv "$HOME/codex/models_cache.json" "$HOME/cache"
out="$($RUN --package "$HOME/package.md" --dry-run)"
assert_eq "$(printf '%s' "$out" | jq -r .model)" null 'missing catalog uses default'
assert_contains "$(printf '%s' "$out" | jq -r .model_reason)" 'configured Codex default' 'fallback explained'
digest="$(printf '%s' "$(pwd -P)" | shasum -a 256 | cut -c1-12)"
mkdir -p "$HOME/codex/overcodex"
printf pending > "$HOME/codex/overcodex/handoff-pending-$digest.md"
"$RUN" --package "$HOME/package.md" --dry-run >/dev/null 2>&1 && fail 'pending conflict' || pass
rm "$HOME/codex/overcodex/handoff-pending-$digest.md"
mkfifo "$HOME/codex/overcodex/handoff-pending-$digest.md"
"$RUN" --package "$HOME/package.md" --dry-run >/dev/null 2>&1 & fifo_pid=$!
(sleep 3; kill -KILL "$fifo_pid" 2>/dev/null) & watchdog=$!
wait "$fifo_pid"; fifo_code=$?
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
[ "$fifo_code" -eq 1 ] && pass || fail 'pending FIFO rejected without hanging'
rm "$HOME/codex/overcodex/handoff-pending-$digest.md"
ln -s "$HOME/package.md" "$HOME/codex/overcodex/handoff-pending-$digest.md"
"$RUN" --package "$HOME/package.md" --dry-run >/dev/null 2>&1 && fail 'pending symlink rejected' || pass
rm "$HOME/codex/overcodex/handoff-pending-$digest.md"
TEST_HOLD=1 "$RUN" --package "$HOME/package.md" > "$HOME/first" 2> "$HOME/first.err" & pid=$!
for unused in 1 2 3 4 5 6 7 8 9 10; do [ -s "$HOME/input" ] && [ "$(wc -l < "$HOME/calls")" -ge 2 ] && break; sleep 0.2; done
for unused in 1 2 3 4 5 6 7 8 9 10; do [ -s "$HOME/first.err" ] && break; sleep 0.2; done
first_dir="$(sed -n 's/^Continuation output: //p' "$HOME/first.err" | head -1)"
for unused in 1 2 3 4 5 6 7 8 9 10; do [ "$(jq -r .thread_id "$first_dir/manifest.json" 2>/dev/null)" = '01234567-89ab-4cde-8fab-0123456789ab' ] && break; sleep 0.2; done
assert_eq "$("$RUN" status --run "$first_dir" --json | jq -r .state)" running 'status reports running while child active'
assert_contains "$("$RUN" status --run "$first_dir" --json | jq -r .process_observation)" 'identity matches' 'running identity verified'
assert_eq "$(jq -r .thread_id "$first_dir/manifest.json")" '01234567-89ab-4cde-8fab-0123456789ab' 'thread persisted before child exits'
mkdir -p "$HOME/other-codex"
TEST_CODEX_HOME="$HOME/other-codex" "$RUN" --package "$HOME/package.md" >/dev/null 2>&1 && fail 'duplicate lock rejected across homes' || pass
wait "$pid" || fail 'first concurrent run succeeds'
TEST_EXIT=7 "$RUN" --package "$HOME/package.md" > "$HOME/failure" 2> "$HOME/failure.err"; code=$?
assert_eq "$code" 7 'child exit preserved'
failed_dir="$(jq -r .output_dir "$HOME/failure")"
assert_eq "$(jq -r .state "$failed_dir/state.json")" failed 'failure recorded'
[ -s "$failed_dir/package.md" ] && pass || fail 'failed package preserved'
assert_contains "$(cat "$HOME/failure.err")" 'codex resume' 'resume guidance'
TEST_IGNORE_TERM=1 "$RUN" --package "$HOME/package.md" > "$HOME/interrupted" 2> "$HOME/interrupted.err" & pid=$!
for unused in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -s "$HOME/child-pid" ] && break; sleep 0.2; done
child_pid="$(cat "$HOME/child-pid")"
kill -TERM "$pid"
wait "$pid"; code=$?
assert_eq "$code" 143 'SIGTERM reported'
interrupted_dir="$(sed -n 's/^Continuation output: //p' "$HOME/interrupted.err" | head -1)"
assert_eq "$(jq -r .state "$interrupted_dir/manifest.json")" interrupted 'interruption recorded'
kill -0 "$child_pid" 2>/dev/null && fail 'ignoring child terminated' || pass
assert_contains "$(cat "$HOME/interrupted.err")" 'Continuation output:' 'run path printed before launch'
"$RUN" --package "$HOME/package.md" >/dev/null 2>&1 && pass || fail 'lock released after termination'
TEST_DESCENDANT=1 "$RUN" --package "$HOME/package.md" > "$HOME/descendant-run" 2> "$HOME/descendant.err" & pid=$!
for unused in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -s "$HOME/descendant-pid" ] && break; sleep 0.2; done
descendant_pid="$(cat "$HOME/descendant-pid")"
kill -TERM "$pid"
wait "$pid"; code=$?
assert_eq "$code" 143 'SIGTERM reported when leader exits'
kill -0 "$descendant_pid" 2>/dev/null && fail 'TERM-resistant descendant terminated' || pass
"$RUN" --package "$HOME/package.md" >/dev/null 2>&1 && pass || fail 'lock released after descendant cleanup'
TEST_DEEP_JSON=1 "$RUN" --package "$HOME/package.md" > "$HOME/deep.out" 2> "$HOME/deep.err" & pid=$!
(sleep 6; kill -KILL "$pid" 2>/dev/null) & watchdog=$!
wait "$pid"; code=$?
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
assert_eq "$code" 0 'deep malformed JSON and oversized event do not block'
deep_dir="$(jq -r .output_dir "$HOME/deep.out")"
assert_eq "$(jq -r .thread_id "$deep_dir/manifest.json")" '01234567-89ab-4cde-8fab-0123456789ab' 'events parsed after oversized and malformed data'
TEST_PIPE_DESCENDANT=1 "$RUN" --package "$HOME/package.md" > "$HOME/pipe-run" 2> "$HOME/pipe.err" & pid=$!
(sleep 5; kill -KILL "$pid" 2>/dev/null) & watchdog=$!
wait "$pid"; code=$?
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
assert_eq "$code" 0 'leader exit with held pipes completes promptly'
pipe_pid="$(cat "$HOME/pipe-descendant-pid")"
kill -0 "$pipe_pid" 2>/dev/null && fail 'pipe-holding descendant terminated' || pass
TEST_READER_FAIL=1 "$RUN" --package "$HOME/package.md" > "$HOME/reader.out" 2> "$HOME/reader.err"; code=$?
assert_eq "$code" 1 'reader failure propagated'
assert_contains "$(cat "$HOME/reader.err")" 'log reader failed' 'reader failure disclosed'
# A maximum-sized prompt must not block failure handling if Codex never reads stdin.
python3 - "$HOME/package.md" "$HOME/large.md" <<'PYCODE'
import sys
source = open(sys.argv[1]).read()
with open(sys.argv[2], 'w') as f:
    f.write(source + 'x' * (15900 - len(source.encode())))
PYCODE
TEST_NO_READ=1 TEST_READER_FAIL=1 "$RUN" --package "$HOME/large.md" > "$HOME/reader.out" 2> "$HOME/reader.err" & pid=$!
(sleep 6; kill -KILL "$pid" 2>/dev/null) & watchdog=$!
wait "$pid"; code=$?
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
assert_eq "$code" 1 'nonreading child does not block reader failure'
assert_contains "$(cat "$HOME/reader.err")" 'log reader failed' 'nonreading child reader failure disclosed'
rm -f "$HOME/nonreading-pid"
TEST_NO_READ=1 "$RUN" --package "$HOME/large.md" > "$HOME/nonreading.out" 2> "$HOME/nonreading.err" & pid=$!
for unused in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [ -s "$HOME/nonreading-pid" ] && break; sleep 0.2; done
kill -TERM "$pid"
(sleep 6; kill -KILL "$pid" 2>/dev/null) & watchdog=$!
wait "$pid"; code=$?
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
assert_eq "$code" 143 'nonreading child does not block signal cleanup'
nonreading_pid="$(cat "$HOME/nonreading-pid")"
kill -0 "$nonreading_pid" 2>/dev/null && fail 'nonreading child terminated' || pass
finish
