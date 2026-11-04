#!/bin/bash
. "$(dirname "$0")/lib.sh"
new_home
RUN="$REPO/bin/overclaude-codex-continue"
mkdir -p "$HOME/stubs" "$HOME/codex" "$HOME/work"
export PATH="$HOME/stubs:$PATH" TEST_CODEX_HOME="$HOME/codex"
cat > "$HOME/stubs/swap-guard" <<'EOF'
#!/bin/bash
printf '{"route":"%s","eligible":%s,"codex":{"home":"%s","limitsKnown":false,"limitsFresh":false}}\n' "${TEST_ROUTE:-codex}" "${TEST_ELIGIBLE:-true}" "$TEST_CODEX_HOME"
EOF
cat > "$HOME/stubs/codex" <<'EOF'
#!/bin/bash
printf '%s\n' "$CODEX_HOME $*" >> "$HOME/calls"
cat > "$HOME/input"
while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then printf 'done\n' > "$2"; fi; shift; done
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
assert_eq "$(jq -r .state "$run_dir/state.json")" completed 'completion recorded'
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
finish
