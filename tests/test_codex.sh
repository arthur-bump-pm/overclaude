#!/bin/bash
# Codex integration: usage from rollout logs, statusline line, readiness, handoff path, review wrapper.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 2
NOW=$(date +%s)
roll() { # roll <codex-home> <json-rate_limits>
  local d="$1/sessions/2026/10/09"; mkdir -p "$d"
  { echo '{"type":"session_meta","payload":{}}'
    printf '{"timestamp":"2026-10-09T07:00:30.216Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":%s}}\n' "$2"
  } > "$d/rollout-2026-10-09T15-00-00-abc.jsonl"
}
roll "$HOME/.codex" "{\"primary\":{\"used_percent\":18.0,\"window_minutes\":10080,\"resets_at\":$((NOW + 200000))},\"secondary\":{\"used_percent\":40.0,\"window_minutes\":300,\"resets_at\":$((NOW + 3600))},\"plan_type\":\"pro\",\"rate_limit_reached_type\":null}"
mkdir -p "$HOME/.codex-accounts"
roll "$HOME/.codex-accounts/work" "{\"primary\":{\"used_percent\":100.0,\"window_minutes\":10080,\"resets_at\":$((NOW + 90000))},\"secondary\":null,\"plan_type\":\"plus\",\"rate_limit_reached_type\":\"primary\"}"

u="$("$SG" codex-usage --refresh)"
assert_eq "$(printf '%s' "$u" | jq length)" "2" "one entry per Codex home with recent sessions"
assert_eq "$(printf '%s' "$u" | jq -r '.[] | select(.name=="primary") | [.windows[].label] | join(",")')" "week,5h" "window labels from window_minutes"
assert_eq "$(printf '%s' "$u" | jq -r '.[] | select(.name=="primary") | .active')" "true" "primary is active without a marker"

out="$(echo '{"model":{"display_name":"M"},"context_window":{"used_percentage":1}}' | SWAP_NO_REFRESH=1 bash "$SL" | strip_ansi)"
assert_contains "$out" "↳ codex week 18% · 5h 40%" "statusline shows the primary Codex home"
assert_contains "$out" "↳ codex:work week 100%" "and every other Codex account"
assert_contains "$out" "⚠ limit reached" "a reached limit is flagged"
assert_absent "$(echo '{"model":{"display_name":"M"}}' | SWAP_NO_REFRESH=1 SWAP_HIDE_CODEX=1 bash "$SL" | strip_ansi)" "codex" "SWAP_HIDE_CODEX hides it"

# Review fixes: newest log without limits is skipped; a home with only a 5h window
# doesn't hide the others; an inherited CODEX_HOME is not trusted.
d="$HOME/.codex/sessions/2026/10/09"; echo '{"type":"session_meta","payload":{}}' > "$d/rollout-2026-10-09T23-59-59-new.jsonl"
touch "$d/rollout-2026-10-09T23-59-59-new.jsonl"
assert_eq "$("$SG" codex-usage --refresh | jq -r '.[] | select(.name=="primary") | .windows[0].pct | floor')" "18" "a newer log with no limits yet is skipped"
roll "$HOME/.codex-accounts/fiveonly" "{\"primary\":{\"used_percent\":7.0,\"window_minutes\":300,\"resets_at\":$((NOW + 3000))},\"secondary\":null}"
"$SG" codex-usage --refresh >/dev/null
out="$(echo '{"model":{"display_name":"M"}}' | SWAP_NO_REFRESH=1 bash "$SL" | strip_ansi)"
assert_contains "$out" "↳ codex:fiveonly 5h 7%" "a Codex home with only a 5h window renders"
assert_contains "$out" "↳ codex week 18%" "and does not hide the other homes"
rm -rf "$HOME/.codex-accounts/fiveonly"; "$SG" codex-usage --refresh >/dev/null

echo work > "$HOME/.codex-accounts/.active"
assert_eq "$(CODEX_HOME="$HOME/.codex" "$SG" path codex-handoff --cwd /tmp/x | grep -c codex-accounts/work)" "1" "an inherited CODEX_HOME is ignored; codex-swap's marker wins"
assert_eq "$("$SG" path codex-handoff --cwd /tmp/x)" "$HOME/.codex-accounts/work/overcodex/handoff-pending-$(printf '%s' /tmp/x | shasum -a 256 | cut -c1-12).md" \
  "codex-handoff path follows the active Codex account (overcodex's hash convention)"

STUB="$HOME/stubbin"; mkdir -p "$STUB"
cat > "$STUB/codex" <<'EOF'
#!/bin/bash
# stub: record args + CODEX_HOME; write the -o file; optional slow mode for the timeout test
echo "CODEX_HOME=$CODEX_HOME $*" >> "$HOME/codex-calls"
[ -n "${STUB_SLOW:-}" ] && { sleep 5 & wait; }
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
stdin=""; [ -t 0 ] || stdin="$(cat)"
printf '%s\n' "${STUB_REPLY:-BUG: add() subtracts}${stdin:+ (saw stdin)}" > "$out"
EOF
chmod +x "$STUB/codex"; export PATH="$STUB:$PATH"

r="$("$SG" codex-ready)"
assert_eq "$(printf '%s' "$r" | jq -r .ready)" "false" "not ready: overcodex hook missing in that home"
mkdir -p "$HOME/.codex-accounts/work/hooks"; touch "$HOME/.codex-accounts/work/hooks/overcodex-handoff-inject.sh"
assert_contains "$("$SG" codex-ready | jq -r .detail)" "at its week limit" "not ready: that Codex account is exhausted"
echo primary > "$HOME/.codex-accounts/.active"; mkdir -p "$HOME/.codex/hooks"; touch "$HOME/.codex/hooks/overcodex-handoff-inject.sh"
assert_eq "$("$SG" codex-ready | jq -r .ready)" "true" "ready: CLI + hook + room"
p="$("$SG" path codex-handoff)"; echo x > "$p"
assert_eq "$("$SG" codex-ready | jq -r '.pending.path')" "$p" "codex-ready reports a pending Codex package (overwrite guard)"
rm -f "$p"

o="$("$SG" codex-review --dir "$HOME" --effort low "Is add correct?")"
assert_eq "$(printf '%s' "$o" | jq -r .message)" "BUG: add() subtracts" "codex-review returns Codex's final message"
c="$(tail -n 1 "$HOME/codex-calls")"
assert_contains "$c" "exec -s read-only --ephemeral" "runs read-only and ephemeral"
assert_contains "$c" "model_reasoning_effort=\"low\"" "passes effort as a config override"
assert_contains "$c" "CODEX_HOME=$HOME/.codex " "on the active Codex account"
o="$(printf 'diff --git a b' | "$SG" codex-review --stdin --dir "$HOME" "Check this diff")"
assert_contains "$(printf '%s' "$o" | jq -r .message)" "(saw stdin)" "--stdin pipes input to Codex"
o="$("$SG" codex-review --dir "$HOME" "no stdin read" < /dev/null)"
assert_absent "$(printf '%s' "$o" | jq -r .message)" "(saw stdin)" "without --stdin nothing is read from stdin"
o="$(STUB_REPLY='{"verdict":"REFUTE","confidence":0.8,"evidence":"x"}' "$SG" codex-review --dir "$HOME" "j")"
assert_eq "$(printf '%s' "$o" | jq -r .json.verdict)" "REFUTE" "JSON answers are parsed into .json"
o="$(STUB_SLOW=1 "$SG" codex-review --timeout 1 --dir "$HOME" "slow")"
assert_eq "$(printf '%s' "$o" | jq -r .error)" "timeout" "a hung Codex run times out"
sleep 1
assert_eq "$(pgrep -f "$STUB/codex" | wc -l | tr -d ' ')" "0" "and leaves no Codex process behind (whole process group killed)"
"$SG" codex-review --dir "$HOME" "--dangerously-bypass-approvals-and-sandbox" >/dev/null
assert_contains "$(tail -n 1 "$HOME/codex-calls")" "-s read-only --ephemeral --skip-git-repo-check --color never -C $HOME -o" "flags come first"
assert_contains "$(tail -n 1 "$HOME/codex-calls")" " -- --dangerously-bypass" "a prompt starting with - is passed after --, never as a flag"
assert_eq "$("$SG" codex-review --timeout 0 "x" | jq -r .error)" "bad-timeout" "--timeout 0 (no timeout) is refused"
assert_eq "$("$SG" codex-review --effort extreme "x" | jq -r .error)" "bad-effort" "unknown effort refused"

rm -rf "$HOME"
finish
