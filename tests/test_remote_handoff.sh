#!/bin/bash
# swap-guard remote handoff: the outbox package travels inside the one SSH call that
# starts the session, lands where the worker's handoff-inject loads it for that
# folder (header rewritten to the worker's folder and clock), plus a lasting copy the
# task points at. Refuses a fresh package already pending there; cleans up when the
# launch fails. Stub ssh runs the remote side locally against fake per-host homes.
. "$(dirname "$0")/lib.sh"
new_home

STUB="$HOME/stubbin"; mkdir -p "$STUB"
mkhost() { # mkhost <name> [mode: ok|untrusted]
  local h="$HOME/hosts/$1"; mkdir -p "$h/.local/bin" "$h/proj" "$h/.claude"
  printf '%s' "${2:-ok}" > "$h/mode"
  cat > "$h/.local/bin/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$PWD" > "$HOME/cwd"
printf '%s\n' "$@" > "$HOME/args"
umask > "$HOME/umask"
[ -f "$HOME/slow" ] && sleep 4
[ "$(cat "$HOME/mode")" = untrusted ] && { echo "Workspace not trusted."; exit 1; }
echo "Started in the background: 1a2b3c4d"
EOF
  chmod +x "$h/.local/bin/claude"
}
mkhost w1; mkhost w2; mkhost w3 untrusted
# w1 has the kit (swap-guard on PATH, the inject hook registered); w2 has neither.
ln -s "$SG" "$HOME/hosts/w1/.local/bin/swap-guard"
echo '{"hooks":{"SessionStart":[{"hooks":[{"command":"bash ~/.claude/hooks/handoff-inject.sh"}]}]}}' > "$HOME/hosts/w1/.claude/settings.json"
cat > "$STUB/ssh" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift
h="$1"; shift
[ -d "$HOME/hosts/$h" ] || exit 255
cd "$HOME/hosts/$h" && HOME="$HOME/hosts/$h" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash -c "$*"
EOF
chmod +x "$STUB/ssh"
export PATH="$STUB:$PATH"
H="$(cd "$HOME/hosts" && pwd -P)"
mkdir -p "$HOME/proj"
CWD="$HOME/proj"

out="$("$SG" remote handoff w1 --cwd "$CWD")"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .error)" "1:no-package" "no outbox package → no-package, nothing sent"
assert_eq "$([ -e "$H/w1/args" ] && echo ran || echo no)" "no" "and no session started"

OB="$("$SG" path remote-handoff --cwd "$CWD")"
assert_eq "$OB" "$HOME/.claude-swap-backup/handoff-outbox-$(printf '%s' "$CWD" | shasum -a 256 | cut -c1-12).md" "path remote-handoff: per-folder outbox"
assert_absent "$OB" "handoff-pending" "never the path this Mac's own hook loads"

printf 'no header\n# Handoff — x\n' > "$OB"
out="$("$SG" remote handoff w1 --cwd "$CWD")"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "malformed-header" "a package without the header line is refused"

BODY="# Handoff — Fix the auth bug
## Goal
Ship it. Tricky text: \$HOME \`x\` \"q\" 'single' — 한국어
## Next steps
- run tests"
{ printf '<!-- handoff cwd="%s" created="%s" -->\n' "$CWD" "$(( $(date +%s) - 4000 ))"; printf '%s\n' "$BODY"; } > "$OB"
out="$("$SG" remote handoff w1 --cwd "$CWD")"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "stale-package" "an outbox over an hour old is a leftover: refused"
NOW="$(date +%s)"
{ printf '<!-- handoff cwd="%s" created="123%s" -->\n' "$CWD" "" | sed "s/123/$NOW/"; printf '%s\n' "$BODY"; } > "$OB"
out="$("$SG" remote handoff w1 --cwd "$CWD")"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .started)" "0:true" "handoff to a worker with the kit"
N="$(printf '%s' "$out" | jq -r .name)"
assert_eq "$N" "w1-Fix-the-auth-bug" "named after the Mac and the package title"
assert_eq "$(cat "$H/w1/cwd")" "$H/w1/proj" "runs in the same folder relative to home"
assert_eq "$(printf '%s' "$out" | jq -r .injector)" "true" "reports that the worker's hook will load it"
P1="$H/w1/.claude-swap-backup/handoff-pending-$(printf '%s' "$H/w1/proj" | shasum -a 256 | cut -c1-12).md"
assert_eq "$([ -f "$P1" ] && echo yes)" "yes" "package is pending for that folder on the worker"
hdr="$(head -n 1 "$P1")"
assert_contains "$hdr" "cwd=\"$H/w1/proj\"" "header rewritten to the worker's folder"
assert_eq "$(stat -f %Lp "$P1")" "600" "pending package is private"
assert_eq "$(cat "$H/w1/umask")" "0022" "the session itself keeps the normal umask"
assert_eq "$([ -e "$OB" ] && echo left || echo gone)" "gone" "after a successful start the outbox is removed"
assert_eq "$(tail -n +2 "$P1")" "$BODY" "body arrives byte-exact"
C="$(printf '%s' "$out" | jq -r .package)"
assert_contains "$(cd "${C%/*}" && pwd -P)/${C##*/}" "$H/w1/.claude-swap-backup/handoff-remote/$N-" "a lasting copy on the worker, named per run"
assert_eq "$(tail -n 1 "$H/w1/args")" "Task: Continue from the handoff package from another Mac. If it is not already in your context, read it first: $C" "the task points at the copy"
assert_eq "$(stat -f %Lp "$C")" "600" "the copy is private to the worker's user"

inj="$(printf '{"cwd":"%s"}' "$H/w1/proj" | HOME="$H/w1" bash "$INJ")"
assert_contains "$inj" "## Handoff from previous session" "the worker's handoff-inject loads it"
assert_contains "$inj" "한국어" "with the whole body"

wob() { { printf '<!-- handoff cwd="%s" created="%s" -->\n' "$1" "$(date +%s)"; printf '%s\n' "$2"; } > "$("$SG" path remote-handoff --cwd "$1")"; }
wob "$CWD" "$BODY"
"$SG" remote handoff w1 --cwd "$CWD" --name second >/dev/null
wob "$CWD" "$BODY
- one more line"
out="$("$SG" remote handoff w1 --cwd "$CWD" --name third)"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .error)" "1:pending-exists" "a fresh package already pending there is not replaced"
assert_contains "$(printf '%s' "$out" | jq -r .fix)" "--force" "and says how to replace it"
assert_eq "$(sed -n 3p "$H/w1/args")" "second" "and no second session started"
out="$("$SG" remote handoff w1 --cwd "$CWD" --name third --force)"
assert_eq "$(printf '%s' "$out" | jq -r .started)" "true" "--force replaces it"
assert_eq "$(find "$H/w1/.claude-swap-backup/handoff-archive" -name '*-replaced.md' | wc -l | tr -d ' ')" "1" "the replaced one is archived, not lost"
# A retry of the same package after a timeout replaces itself without --force.
touch "$H/w1/slow"; wob "$CWD" "$BODY
- retried"
out="$(SWAP_REMOTE_DEADLINE=2 "$SG" remote handoff w1 --cwd "$CWD" --name fourth --force)"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "timeout" "a slow worker hits the deadline"
assert_eq "$([ -e "$("$SG" path remote-handoff --cwd "$CWD")" ] && echo kept)" "kept" "the outbox stays for the retry"
rm -f "$H/w1/slow"; sleep 3
out="$("$SG" remote handoff w1 --cwd "$CWD" --name fourth)"
assert_eq "$(printf '%s' "$out" | jq -r .started)" "true" "the retry with the same package is not refused as pending-exists"
out="$("$SG" remote start w1 --dir proj -- fix --force thing)"
assert_eq "$(tail -n 1 "$H/w1/args")" "Task: fix --force thing" "plain remote start keeps --force in the goal"

wob "$CWD" "$BODY"
out="$("$SG" remote handoff w2 --cwd "$CWD")"
assert_eq "$(printf '%s' "$out" | jq -r .injector)" "false" "worker without the kit: says the hook won't load it"
P2="$H/w2/.claude-swap-backup/handoff-pending-$(printf '%s' "$H/w2/proj" | shasum -a 256 | cut -c1-12).md"
assert_eq "$([ -f "$P2" ] && echo yes)" "yes" "the fallback hash matches swap-guard's"
assert_contains "$(tail -n 1 "$H/w2/args")" "read it first: $(printf '%s' "$out" | jq -r .package)" "and the task still points at the copy"

wob "$CWD" "$BODY"
out="$("$SG" remote handoff w3 --cwd "$CWD")"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .error)" "1:untrusted" "launch fails (untrusted folder)"
assert_eq "$(find "$H/w3/.claude-swap-backup" -name 'handoff-pending-*' | wc -l | tr -d ' ')" "0" "nothing left pending for an unrelated session there"

out="$("$SG" remote handoff w1 --cwd "$CWD" --dir nope)"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "no-dir" "--dir that doesn't exist there → no-dir"
CWD2="/nonexistent-oc-rh-$$"
wob "$CWD2" "$BODY"
out="$("$SG" remote handoff w2 --cwd "$CWD2")"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "no-dir" "a folder outside home is used as-is (absent there → no-dir)"
head -c 70000 /dev/zero | tr '\0' x >> "$OB"
out="$("$SG" remote handoff w1 --cwd "$CWD" --force)"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "too-big" "an oversized package is refused"
out="$("$SG" remote handoff 'bad;host' --cwd "$CWD")"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .error)" "2:usage" "a bad Mac name is refused"

rm -rf "$HOME"
finish
