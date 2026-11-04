#!/bin/bash
# Exercise the real hook, route decision and runner together; only Codex is stubbed.
. "$(dirname "$0")/lib.sh"
new_home
trap 'rm -rf "$TH"' EXIT
write_seq 2
mkdir -p "$HOME/bin" "$HOME/work" "$HOME/.codex/hooks"
ln -s "$SG" "$HOME/bin/swap-guard"
cat > "$HOME/bin/codex" <<'STUB'
#!/bin/bash
if [ "$1 $2" = 'login status' ]; then exit "${QA_LOGIN_RC:-0}"; fi
[ "$1" = exec ] || exit 2
printf '%s\n' "$CODEX_HOME" >> "$HOME/launches"
cat > "$HOME/received-package"
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then printf 'Completed simulated work; checks passed.\n' > "$2"; fi
  shift
done
STUB
chmod +x "$HOME/bin/codex"
export PATH="$HOME/bin:$PATH"
# No overcodex hook: automatic continuation carries its package on stdin.
cd "$HOME/work" || exit 1
RUN="$REPO/bin/overclaude-codex-continue"
NOW="$(date +%s)"; FUT="$(iso_in 86400)"
cache() {
  cat > "$HOME/.claude-swap-backup/cache/usage.json" <<JSON
{"accounts":{"1":{"fetchedAt":$NOW,"lastGood":{"seven_day":{"pct":$1,"resets_at":"$FUT"}}},"2":{"fetchedAt":$NOW,"lastGood":{"seven_day":{"pct":$2,"resets_at":"$FUT"}}}}}
JSON
}
{
  printf '<!-- handoff cwd="%s" created="%s" -->\n' "$(pwd -P)" "$NOW"
  for heading in 'Goal' 'Current state' 'Files touched' 'Work in flight' 'Next steps' 'Validation' 'Codex execution plan'; do
    printf '## %s\nFinish the specified task and retain its evidence.\n' "$heading"
  done
} > "$HOME/package.md"
cache 97 96.9
"$RUN" --package "$HOME/package.md" > "$HOME/declined" 2>&1 && fail 'remaining Claude quota blocks launch' || pass
assert_eq "$([ -e "$HOME/launches" ] && echo yes || echo no)" no 'no Codex work while Claude has room'
cache 97 97
notice="$(printf '{"session_id":"e2e","tool_name":"Bash"}' | "$SG" checkpoint --hook)"
assert_contains "$notice" '/handoff codex auto' 'real hook requests automatic handoff'
result="$("$RUN" --package "$HOME/package.md")"
assert_eq "$?" 0 'real routing and runner complete together'
assert_eq "$(jq -r .exit_code <<< "$result")" 0 'Codex completion returned'
assert_contains "$(cat "$(jq -r .final_message <<< "$result")")" 'checks passed' 'final evidence readable'
assert_contains "$(cat "$HOME/received-package")" 'Use the installed $ultracode' 'orchestration harness reaches Codex'
assert_eq "$(cat "$HOME/launches")" "$(cd "$HOME/.codex" && pwd -P)" 'selected account home pinned end to end'
assert_eq "$(stat -f %Lp "$(jq -r .output_dir <<< "$result")/package.md")" 600 'saved context is private'
QA_LOGIN_RC=1 "$RUN" --package "$HOME/package.md" > "$HOME/declined" 2>&1 && fail 'logout blocks real route' || pass
assert_eq "$(wc -l < "$HOME/launches" | tr -d ' ')" 1 'logout does not launch another continuation'
cache 97 20
"$RUN" --package "$HOME/package.md" > "$HOME/declined" 2>&1 && fail 'recovered Claude quota blocks stale handoff' || pass
assert_eq "$(wc -l < "$HOME/launches" | tr -d ' ')" 1 'route recheck prevents work after quota recovery'
finish
