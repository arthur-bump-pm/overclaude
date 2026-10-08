#!/bin/bash
# swap-guard auto tick: decision paths against a stub cswap (never switches anything).
. "$(dirname "$0")/lib.sh"
new_home
write_seq 2

STUB="$HOME/stubbin"; mkdir -p "$STUB"
cat > "$STUB/cswap" <<'EOF'
#!/bin/bash
case "$*" in
  "list --json"*)
    def='{"accounts":[{"number":1,"email":"work@example.com","usageStatus":"ok"},{"number":2,"email":"personal@example.com","usageStatus":"ok"}]}'
    printf '%s\n' "${STUB_LIST:-$def}" ;;
  *--dry-run*)    printf '%s\n' "$STUB_DRY"; exit "${STUB_DRY_RC:-0}" ;;
  "auto --once"*) echo "$*" >> "$HOME/real-called"; printf '%s\n' "$STUB_REAL"; exit "${STUB_REAL_RC:-0}" ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$STUB/cswap"
export PATH="$STUB:$PATH"

SW='{"event":"switch","trigger":"TRIG","from":{"number":2},"to":{"number":1,"email":"work@example.com"},"warnings":[],"dryRun":true}'
tick() { rm -f "$HOME/real-called"; out=$(STUB_DRY="$1" STUB_DRY_RC="$2" STUB_REAL="${3:-}" STUB_REAL_RC="${4:-0}" "$SG" auto tick --no-notify); rc=$?; }
called() { [ -f "$HOME/real-called" ] && echo yes || echo no; }

tick '{"event":"no-switch","reason":"below-threshold"}' 2
assert_eq "$rc" "2" "below threshold passes cswap's exit code"
assert_eq "$(printf '%s' "$out" | jq -r .action)" "none" "below threshold → no action"
assert_eq "$(called)" "no" "no real switch below threshold"

tick "${SW/TRIG/proactive}" 0 "${SW/TRIG/proactive}" 0
assert_eq "$(printf '%s' "$out" | jq -r .action)" "switched" "proactive + idle → switched"
assert_eq "$(called)" "yes" "real cswap auto --once called"

# A live busy session: a process whose name is "claude" + a registry file saying busy.
ln -s /bin/sleep "$HOME/claude"; "$HOME/claude" 30 & BPID=$!   # symlink: a copied system binary gets SIGKILLed by code signing
printf '{"pid":%s,"sessionId":"s1","cwd":"/x","status":"busy","kind":"interactive"}' "$BPID" > "$HOME/.claude/sessions/$BPID.json"

tick "${SW/TRIG/proactive}" 0 "${SW/TRIG/proactive}" 0
assert_eq "$(printf '%s' "$out" | jq -r .action)" "deferred" "proactive + busy → deferred"
assert_eq "$(printf '%s' "$out" | jq -r .busySessions)" "1" "busy session counted"
assert_eq "$(called)" "no" "no real switch while busy"

tick "${SW/TRIG/at-limit}" 0 "${SW/TRIG/at-limit}" 0
assert_eq "$(printf '%s' "$out" | jq -r .action)" "switched" "at-limit + busy → switched anyway"

tick "${SW/TRIG/at-limit}" 0 '{"event":"no-switch","reason":"cooldown"}' 2
assert_eq "$(printf '%s' "$out" | jq -r .reason)" "cooldown" "recheck declining is reported"
assert_eq "$rc" "2" "recheck exit code passed through"

kill "$BPID" 2>/dev/null; wait "$BPID" 2>/dev/null

STUB_LIST='{"accounts":[{"number":1,"email":"work@example.com","usageStatus":"relogin_required"}]}' \
  tick "${SW/TRIG/at-limit}" 0 "${SW/TRIG/at-limit}" 0
assert_eq "$(printf '%s' "$out" | jq -r .reason)" "relogin-required" "dead-token target skipped"
assert_eq "$(called)" "no" "no real switch onto a dead token"

tick '{"event":"all-exhausted"}' 3
assert_eq "$rc" "3" "all exhausted → exit 3"

assert_eq "$(wc -l < "$HOME/.claude-swap-backup/auto.log" | tr -d ' ')" "7" "every tick logged (7 ticks)"

# Review finding: cswap rejecting arguments (rc 2, no JSON) must be an ERROR,
# not indistinguishable from "no action".
tick "" 2
assert_eq "$(printf '%s' "$out" | jq -r .action)" "error" "no decision from cswap → error"
assert_eq "$rc" "1" "error exit code"

# Probe mode never switches, even when cswap wants to.
rm -f "$HOME/real-called"
out=$(STUB_DRY="${SW/TRIG/at-limit}" STUB_DRY_RC=0 STUB_REAL="${SW/TRIG/at-limit}" "$SG" auto tick --probe --no-notify)
assert_eq "$(printf '%s' "$out" | jq -r .action)" "probe-ok" "probe reports ok"
assert_eq "$(called)" "no" "probe never runs the real switch"

# Install: validation + XML-safe, linted plist (no launchctl in tests).
export SWAP_GUARD_NO_LAUNCHCTL=1
export STUB_DRY='{"event":"no-switch","reason":"below-threshold"}' STUB_DRY_RC=2
"$SG" auto install --threshold abc >/dev/null 2>&1
assert_eq "$?" "1" "non-numeric threshold refused"
"$SG" auto install --threshold 120 >/dev/null 2>&1
assert_eq "$?" "1" "out-of-range threshold refused"
"$SG" auto install --model '</string><string>--strategy' >/dev/null 2>&1
assert_eq "$?" "1" "XML-injecting model name refused"
r=$("$SG" auto install --interval 300 --threshold 85 --model Fable,Opus)
plist=$(printf '%s' "$r" | jq -r .plist)
plutil -lint "$plist" >/dev/null 2>&1 && pass || fail "generated plist lints" "$plist"
assert_contains "$(cat "$plist")" "<string>Fable,Opus</string>" "model arg in ProgramArguments"
assert_contains "$(cat "$plist")" "<string>/dev/null</string>" "launchd stdout discarded (tick logs itself)"
first=$(plutil -extract EnvironmentVariables.PATH raw "$plist" | cut -d: -f1)
assert_eq "$first" "$STUB" "managed cswap dir is first on the agent PATH"
assert_eq "$(called)" "no" "install never switches"

finish
