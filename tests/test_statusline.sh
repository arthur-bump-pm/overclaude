#!/bin/bash
# Statusline: weekly-reset segment, other-accounts line, fallbacks.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 2
export SWAP_CLAUDE_JSON=/dev/null

# Account 1: reset passed + dead token + empty 5h block (the "empty field shifts
# columns" regression). Account 2 (active): healthy, resets in ~1d 6h.
cat > "$HOME/.claude-swap-backup/cache/usage.json" <<EOF
{"schemaVersion": 2, "accounts": {
  "1": {"lastError": "invalid_grant", "authDeadStrikes": 1, "fetchedAt": $(( $(date +%s) - 7200 )),
        "lastGood": {"five_hour": {},
                     "seven_day": {"pct": 85.0, "resets_at": "$(iso_in -3600)"},
                     "scoped": [{"name": "Fable", "pct": 100.0, "resets_at": "$(iso_in -3600)"}]}},
  "2": {"lastError": null, "authDeadStrikes": 0, "fetchedAt": $(date +%s),
        "lastGood": {"five_hour": {"pct": 11.0, "resets_at": "$(iso_in 3600)"},
                     "seven_day": {"pct": 41.0, "resets_at": "$(iso_in 110000)"},
                     "scoped": [{"name": "Fable", "pct": 34.0, "resets_at": "$(iso_in 110000)"}]}}}}
EOF

out=$(echo '{"model":{"display_name":"M"},"context_window":{"used_percentage":12}}' | bash "$SL" | strip_ansi)
l1=$(printf '%s\n' "$out" | sed -n 1p)
l2=$(printf '%s\n' "$out" | sed -n 2p)
l3=$(printf '%s\n' "$out" | sed -n 3p)

assert_contains "$l1" "👤 personal [2/2] ↻ " "line 1 shows active account + weekly reset"
assert_contains "$l1" "(1d 6h)" "weekly reset countdown"
assert_contains "$l2" "week [████░░░░░░] 41%" "week bar from cache"
assert_contains "$l3" "↳ work [1]" "other-account line present"
assert_absent "$l3" "5h" "no 5h window (empty block) -> 5h left out of the other-account line"
assert_contains "$l3" "↳ work [1] week 0%" "no column shift after dropping 5h"
assert_contains "$l3" "week 0%" "passed reset on inactive account shows 0%"
assert_contains "$l3" "⚠ relogin" "dead token flagged"
assert_contains "$l3" "(2h 0m old)" "staleness marker"
assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "3" "three lines with two accounts"

# Healthy other account must NOT be flagged (regression: tab-collapse shifted fetchedAt into 'dead').
write_seq 1
l3=$(echo '{}' | bash "$SL" | strip_ansi | sed -n 3p)
assert_contains "$l3" "↳ personal [2] 5h 11% · week 41% · Fable 34% ↻ " "healthy other account renders fully"
assert_absent "$l3" "relogin" "healthy account not flagged"
l1=$(echo '{}' | bash "$SL" | strip_ansi | sed -n 1p)
assert_contains "$l1" "↻ week reset — refreshing" "active account with passed reset"

# Ultra-style plan: no 5-hour window (five_hour null) -> no 5h bar on line 2.
write_seq 1
l2=$(echo '{"context_window":{"used_percentage":12}}' | bash "$SL" | strip_ansi | sed -n 2p)
assert_absent "$l2" "5h" "active account without a 5h window: 5h bar left out"
assert_contains "$l2" "ctx [█░░░░░░░░░] 12% | week " "ctx goes straight to week"
write_seq 2
l2=$(echo '{"context_window":{"used_percentage":12}}' | bash "$SL" | strip_ansi | sed -n 2p)
assert_contains "$l2" "| 5h [█░░░░░░░░░] 11% |" "account with a 5h window still shows the bar"

# Session count comes from ~/.claude/sessions/<pid>.json, live `claude` pids only:
# a stale file and a live non-claude pid are not counted.
sd="$HOME/sessreg"; mkdir -p "$sd" "$HOME/fakebin"
ln -sf /bin/sleep "$HOME/fakebin/claude"
"$HOME/fakebin/claude" 30 & c1=$!
"$HOME/fakebin/claude" 30 & c2=$!
sleep 0.01 & dead=$!; wait "$dead" 2>/dev/null    # a real, now-dead pid
for _ in 1 2 3 4 5 6 7 8 9 10; do                  # wait until both have exec'd
  case "$(ps -o comm= -p "$c1,$c2" 2>/dev/null | grep -c 'claude$')" in 2) break ;; esac
  sleep 0.1
done
for p in "$c1" "$c2" "$dead" 999999 "$$"; do echo '{}' > "$sd/$p.json"; done
l1=$(echo '{}' | SWAP_SESSIONS_DIR="$sd" bash "$SL" | strip_ansi | sed -n 1p)
assert_contains "$l1" "| 2 sessions |" "only live claude pids from the session registry are counted"
kill "$c1" "$c2" 2>/dev/null; wait "$c1" "$c2" 2>/dev/null
l1=$(echo '{}' | SWAP_SESSIONS_DIR="$sd" bash "$SL" | strip_ansi | sed -n 1p)
assert_contains "$l1" "| 1 session |" "no live sessions in the registry -> floor of 1"

# Unknown usage (no cache for the account, no rate_limits on stdin) keeps "5h n/a".
rm -f "$HOME/.claude-swap-backup/cache/usage.json"
l2=$(echo '{"context_window":{"used_percentage":12}}' | bash "$SL" | strip_ansi | sed -n 2p)
assert_contains "$l2" "| 5h [░░░░░░░░░░] n/a |" "no usage data at all: 5h shows n/a, not hidden"
l2=$(echo '{"rate_limits":{"seven_day":{"used_percentage":20}}}' | bash "$SL" | strip_ansi | sed -n 2p)
assert_absent "$l2" "5h" "stdin rate_limits without five_hour: 5h left out"

# Hide flag
n=$(echo '{}' | SWAP_HIDE_OTHERS=1 bash "$SL" | wc -l | tr -d ' ')
assert_eq "$n" "2" "SWAP_HIDE_OTHERS=1 hides other-account lines"

# No cache: stdin resets_at (epoch seconds) is the fallback for line 1
rm -f "$HOME/.claude-swap-backup/cache/usage.json"
write_seq 2
out=$(echo "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":40,\"resets_at\":$(( $(date +%s) + 91800 ))}}}" | bash "$SL" | strip_ansi)
assert_contains "$(printf '%s\n' "$out" | sed -n 1p)" "(1d 1h)" "stdin resets_at fallback"
assert_contains "$(printf '%s\n' "$out" | sed -n 3p)" "(no usage data)" "other account without cache"

# A fresh cache file and fresh active row must not hide a stale sibling.
write_seq 2
mkdir -p "$HOME/refresh-bin"
cat > "$HOME/refresh-bin/cswap" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$HOME/status-refresh-calls"
exit 1
STUB
chmod +x "$HOME/refresh-bin/cswap"
cat > "$HOME/.claude-swap-backup/cache/usage.json" <<EOF2
{"accounts":{"1":{"fetchedAt":$(( $(date +%s) - 200 )),"lastGood":{"seven_day":{"pct":98,"resets_at":"$(iso_in 86400)"}}},"2":{"fetchedAt":$(date +%s),"lastGood":{"seven_day":{"pct":99,"resets_at":"$(iso_in 86400)"}}}}}
EOF2
PATH="$HOME/refresh-bin:$PATH" SWAP_GUARD_CMD="$SG" SWAP_NO_REFRESH= bash "$SL" <<<'{}' >/dev/null
for i in 1 2 3 4 5 6 7 8 9 10; do [ -f "$HOME/status-refresh-calls" ] && break; sleep 0.1; done
assert_eq "$(cat "$HOME/status-refresh-calls" 2>/dev/null)" "list --json" "stale sibling triggers a normal refresh despite fresh cache mtime"
PATH="$HOME/refresh-bin:$PATH" SWAP_GUARD_CMD="$SG" SWAP_NO_REFRESH= bash "$SL" <<<'{}' >/dev/null
assert_eq "$(wc -l < "$HOME/status-refresh-calls" | tr -d ' ')" 1 "repeated statuslines share the refresh debounce"
finish
