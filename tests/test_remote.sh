#!/bin/bash
# swap-guard remote: start (claude --bg --remote-control, tmux fallback), untrusted
# folder / missing folder / login errors, goal text that must arrive byte-exact,
# list / logs / stop (name → id), attach without a terminal. A stub ssh runs the
# remote side locally against fake per-host homes; no network or real SSH.
. "$(dirname "$0")/lib.sh"
new_home

STUB="$HOME/stubbin"; mkdir -p "$STUB"
mkhost() { # mkhost <name> [mode: ok|untrusted|nobg|nologin]
  local h="$HOME/hosts/$1"; mkdir -p "$h/.local/bin" "$h/proj"
  printf '%s' "${2:-ok}" > "$h/mode"
  cat > "$h/.local/bin/claude" <<'EOF'
#!/bin/bash
mode="$(cat "$HOME/mode")"
case "$1" in
  agents) echo '[{"id":"1a2b3c4d","name":"w1-fix-auth","kind":"background","state":"working","cwd":"/x"},
                 {"id":"5e6f7a8b","name":"w1-docs","kind":"background","state":"idle"},
                 {"id":"99999999","name":"w1-fix-auth-2","kind":"background","state":"idle"},
                 {"pid":1,"kind":"interactive","name":"local"}]'; exit 0;;
  stop) echo "$2" >> "$HOME/stopped"; exit 0;;
  logs) echo "log of $2"; exit 0;;
  attach) exit 0;;
esac
printf '%s\n' "$PWD" > "$HOME/cwd"
printf '%s\n' "$@" > "$HOME/args"
case "$mode" in
  untrusted) echo "Workspace not trusted. Run \`claude\` in $PWD once and accept the trust prompt, then retry."; exit 1;;
  nobg)      echo "error: unknown option '--bg'"; exit 1;;
  nologin)   echo "Remote Control requires a claude.ai login. Run /login."; exit 1;;
esac
echo "Started in the background: 1a2b3c4d"
EOF
  cat > "$h/.local/bin/tmux" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$HOME/tmux-args"
EOF
  chmod +x "$h/.local/bin/"*
}
mkhost w1; mkhost w2 untrusted; mkhost w3 nobg; mkhost w4 nologin
mkhost noclaude; printf '#!/bin/bash\necho "zsh: command not found: claude"\n' > "$HOME/hosts/noclaude/.local/bin/claude"
mkhost evil; cat > "$HOME/hosts/evil/.local/bin/claude" <<'EOF'
#!/bin/bash
case "$1" in
  agents) printf '[{"id":"x'"'"'; touch $HOME/pwned; echo '"'"'","name":"evil","kind":"background","state":"\u001b]0;TITLE\u0007\u001b[31mred"},
                   {"id":"aaaaaaaa","name":"twin","kind":"background"},{"id":"bbbbbbbb","name":"twin","kind":"background"}]';;
  stop) echo "$2" >> "$HOME/stopped";;
esac
EOF
cat > "$STUB/ssh" <<'EOF'
#!/bin/bash
echo "$*" >> "$HOME/ssh-calls"
while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done; shift
h="$1"; shift
[ "$h" = hung ] && { sleep 30; exit 255; }
[ -d "$HOME/hosts/$h" ] || exit 255
[ "$*" = "bash -s" ] || cat > /dev/null
cd "$HOME/hosts/$h" && HOME="$HOME/hosts/$h" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash -c "$*"
EOF
chmod +x "$STUB/ssh"
export PATH="$STUB:$PATH"
H="$(cd "$HOME/hosts" && pwd -P)"

GOAL="fix the 'auth' bug; rm -rf \$HOME \`x\` \"now\" — ok"
out="$("$SG" remote start w1 --dir proj -- "$GOAL")"
assert_eq "$(printf '%s' "$out" | jq -r .started)" "true" "start on a healthy worker"
assert_eq "$(printf '%s' "$out" | jq -r .mode)" "bg" "uses claude --bg"
assert_eq "$(tail -n 1 "$H/w1/args")" "Task: $GOAL" "the goal arrives byte-exact (quotes, \$, backticks, unicode) as the prompt"
assert_eq "$(sed -n 1,5p "$H/w1/args" | tr '\n' ' ')" "--bg -n w1-fix-the-auth-bug-rm-rf-H --remote-control w1-fix-the-auth-bug-rm-rf-H " "named after the Mac and the goal, for Remote Control and the agent list"
assert_eq "$(cat "$H/w1/cwd")" "$H/w1/proj" "runs in --dir (relative to the worker's home)"
assert_contains "$(printf '%s' "$out" | jq -r .next)" "claude.ai/code" "says where to drive it"
assert_eq "$([ -e "$HOME/pwned" ] || [ -e "$H/w1/pwned" ] && echo bad || echo ok)" "ok" "nothing in the goal ran as a command"

"$SG" remote start w1 --name my.job_1 >/dev/null
assert_eq "$(sed -n 3p "$H/w1/args")" "my.job_1" "--name sets the session name"
assert_eq "$(wc -l < "$H/w1/args" | tr -d ' ')" "5" "no goal → no prompt argument"
assert_eq "$(cat "$H/w1/cwd")" "$H/w1" "default folder is the worker's home"
"$SG" remote start w1 --dir '~/proj' >/dev/null
assert_eq "$(cat "$H/w1/cwd")" "$H/w1/proj" "~/ is the worker's home"
out="$("$SG" remote start w1 --name 'bad name;x')"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .error)" "2:bad-name" "unsafe --name refused"
out="$("$SG" remote start '-oProxyCommand=x')"; rc=$?
assert_eq "$rc" "2" "a host that looks like an ssh option is refused"

out="$("$SG" remote start w2 --dir proj fix it)"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .error)" "1:untrusted" "untrusted folder → its own error"
assert_contains "$(printf '%s' "$out" | jq -r .fix)" "accept the trust prompt" "with the fix"
assert_contains "$(printf '%s' "$out" | jq -r .fix)" "$H/w2/proj" "naming the folder"
out="$("$SG" remote start w1 --dir nowhere x)"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "no-dir" "missing folder → no-dir"
out="$("$SG" remote start w3 --dir proj fix it)"
assert_eq "$(printf '%s' "$out" | jq -r .mode)" "tmux" "Claude Code without --bg → tmux"
assert_eq "$(sed -n 1,5p "$H/w3/tmux-args" | tr '\n' ' ')" "new-session -d -s w3-fix-it -c " "tmux session named like the Remote Control session"
assert_eq "$(tail -n 1 "$H/w3/tmux-args")" "Task: fix it" "tmux runs claude with the goal as one argument"
assert_contains "$(printf '%s' "$out" | jq -r .next)" "tmux attach -t w3-fix-it" "and says how to attach"
out="$("$SG" remote start w4 x)"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "failed" "login problem → failed"
assert_contains "$(printf '%s' "$out" | jq -r .detail)" "requires a claude.ai login" "with Claude Code's own message"
assert_contains "$(printf '%s' "$out" | jq -r .fix)" "/login" "and the setup-token caveat"
out="$("$SG" remote start offline x)"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .error)" "1:unreachable" "unreachable Mac"

out="$("$SG" remote list w1)"
assert_eq "$(printf '%s' "$out" | jq -c '[.[].id]')" '["1a2b3c4d","5e6f7a8b","99999999"]' "list shows background sessions only"
assert_contains "$("$SG" remote list w1 --text)" "1a2b3c4d  w1-fix-auth  working" "text list"
assert_eq "$("$SG" remote logs w1 w1-docs)" "log of w1-docs" "logs pass the name through"
out="$("$SG" remote stop w1 w1-docs)"
assert_eq "$(printf '%s' "$out" | jq -r .stopped):$(tail -n 1 "$H/w1/stopped")" "true:5e6f7a8b" "stop resolves a name to its id"
"$SG" remote stop w1 w1-fix-auth >/dev/null
assert_eq "$(tail -n 1 "$H/w1/stopped")" "1a2b3c4d" "an exact name wins over a longer one containing it"
out="$("$SG" remote stop w1 fix)"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .error)" "1:ambiguous" "a part matching two sessions is ambiguous"
assert_eq "$(printf '%s' "$out" | jq -c .ids)" '["1a2b3c4d","99999999"]' "and lists their ids"
out="$("$SG" remote stop w1 nothing-like-it)"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .error)" "1:no-such-session" "no match → no-such-session"
"$SG" remote stop w1 deadbeef >/dev/null
assert_eq "$(tail -n 1 "$H/w1/stopped")" "deadbeef" "an 8-hex id is used as is"
out="$("$SG" remote stop w1 "x';touch pwned")"; rc=$?
assert_eq "$rc" "2" "unsafe session ref refused"
out="$("$SG" remote attach w1 w1-docs </dev/null)"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .command)" "1:ssh -t w1 'export PATH=\"\$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:\$PATH\"; claude attach w1-docs'" "attach without a terminal prints a command that finds claude (non-login ssh shell)"

# Audit cases: option-looking and subcommand-looking goals, non-ASCII goals, hung or
# odd workers, hostile worker output.
"$SG" remote start w1 -- "--dangerously-skip-permissions" >/dev/null
assert_eq "$(tail -n 1 "$H/w1/args")" "Task: --dangerously-skip-permissions" "a goal starting with - is never an option"
"$SG" remote start w1 update >/dev/null
assert_eq "$(tail -n 1 "$H/w1/args")" "Task: update" "a one-word goal is never a subcommand"
n1="$("$SG" remote start w1 "인증 버그 고쳐줘" | jq -r .name)"; sleep 1
n2="$("$SG" remote start w1 "다른 작업" | jq -r .name)"
assert_contains "$n1" "w1-" "a goal with no ASCII words still gets a name"
assert_eq "$([ "$n1" != "$n2" ] && [ "$n1" != "w1" ] && echo distinct)" "distinct" "and two of them get different names"
assert_eq "$(tail -n 1 "$H/w1/args")" "Task: 다른 작업" "with the goal intact"
out="$("$SG" remote start .x fix)"
assert_eq "$(printf '%s' "$out" | jq -r .name | cut -c1-7)" "remote-" "a host with no usable name part still gives a valid name"
out="$("$SG" remote start w1 --name 20261013)"; rc=$?
assert_eq "$rc:$(printf '%s' "$out" | jq -r .error)" "2:bad-name" "a name that looks like a session id is refused"
"$SG" remote start w3 --name my.job fix >/dev/null
assert_eq "$(sed -n 4p "$H/w3/tmux-args")" "my_job" "tmux session names lose dots"
t0=$(date +%s); out="$(SWAP_REMOTE_DEADLINE=2 "$SG" remote start hung fix)"; t1=$(date +%s)
assert_eq "$(printf '%s' "$out" | jq -r .error)" "timeout" "a hung worker hits the deadline"
assert_contains "$(printf '%s' "$out" | jq -r .fix)" "remote list hung" "and says to check before retrying"
assert_le "$((t1 - t0))" "6" "without waiting for it"
t0=$(date +%s); out="$(SWAP_REMOTE_DEADLINE=2 "$SG" remote list hung)"; t1=$(date +%s)
assert_eq "$(printf '%s' "$out" | jq -r .error):$([ $((t1 - t0)) -le 6 ] && echo fast)" "timeout:fast" "list has a deadline too"
mkdir -p "$HOME/tmp"
TMPDIR="$HOME/tmp" SWAP_REMOTE_DEADLINE=20 "$SG" remote start hung fix >/dev/null & kp=$!
sleep 1.5; kill -TERM "$kp"; wait "$kp" 2>/dev/null; sleep 0.5
assert_eq "$(ls "$HOME/tmp" | wc -l | tr -d ' ')" "0" "killed mid-call: no temp files (goal script) left behind"
out="$("$SG" remote list noclaude)"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "bad-answer" "a non-JSON answer is not called unreachable"
out="$("$SG" remote list evil --text)"
assert_eq "$(printf '%s' "$out" | LC_ALL=C grep -c "$(printf '\033')")" "0" "control characters from a worker never reach the terminal"
"$SG" remote stop evil evil >/dev/null
assert_eq "$([ -e "$H/evil/pwned" ] && echo bad || echo ok)" "ok" "a malformed id from the worker is never sent back in a command"
out="$("$SG" remote stop evil twin)"
assert_eq "$(printf '%s' "$out" | jq -r .error)" "ambiguous" "two sessions with the same exact name are ambiguous"

rm -rf "$HOME"
finish
