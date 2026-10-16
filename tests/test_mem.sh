#!/bin/bash
# swap-guard mem: memory levels, the cache the statusline and hooks read, the session
# notes (checkpoint hook), the agent gate, orphan cleanup, the watcher tick and agent.
. "$(dirname "$0")/lib.sh"
new_home
B="$HOME/.claude-swap-backup"
STUB="$HOME/.stub-mem"; mkdir -p "$STUB"
# System numbers come from files the stubs read; set_mem <free%> <pressure 1|2|4> <swap used MB>
set_mem() { printf '%s\n' "$1" > "$STUB/free"; printf '%s\n' "$2" > "$STUB/lvl"; printf '%s\n' "$3" > "$STUB/swap"; }
cat > "$STUB/sysctl" <<EOF
#!/bin/bash
case "\$2" in
  hw.memsize) echo 25769803776;;
  kern.memorystatus_vm_pressure_level) cat "$STUB/lvl";;
  vm.swapusage) echo "total = 8192.00M  used = \$(cat "$STUB/swap").00M  free = 1.00M  (encrypted)";;
  *) exit 1;;
esac
EOF
cat > "$STUB/memory_pressure" <<EOF
#!/bin/bash
echo "The system has 25769803776 (1572864 pages with a page size of 16384)."
echo "System-wide memory free percentage: \$(cat "$STUB/free")%"
EOF
cat > "$STUB/vm_stat" <<'EOF'
#!/bin/bash
echo "Mach Virtual Memory Statistics: (page size of 16384 bytes)"
echo "Pages occupied by compressor:                 131072."
EOF
printf '#!/bin/bash\necho "PID    MEM"\n' > "$STUB/top"
printf '#!/bin/bash\n[ "$1" = list ] && echo "PID	Status	Label"\nexit 0\n' > "$STUB/launchctl"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/notes"\n' "$HOME" > "$STUB/osascript"
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"
export SWAP_GUARD_NO_LAUNCHCTL=1
# The whole file looks at no real process as an orphan: only the orphan tests widen
# this, to their own tagged processes.
NOMATCH="ocmem-nomatch-$$-$RANDOM"
export SWAP_MEM_TEST_ONLY="$NOMATCH"

lvl() { "$SG" mem | jq -r '.level'; }

# --- levels -----------------------------------------------------------------
set_mem 55 1 1000
snap="$("$SG" mem)"
assert_eq "$(printf '%s' "$snap" | jq -r .level)" "ok" "plenty free, little swap: ok"
assert_eq "$(printf '%s' "$snap" | jq -c '[.ramMB, .freePct, .usedPct, .swapUsedMB, .swapTotalMB, .compressedMB, .pressure]')" \
  '[24576,55,45,1000,8192,2048,"normal"]' "the system numbers are parsed"
assert_contains "$(head -c 60 "$B/cache/mem.json")" '"level":"ok"' "the cache starts with at + level (hooks read it without jq)"
set_mem 15 1 1000; assert_eq "$(lvl)" "warn" "free under 20%: warn"
set_mem 55 2 1000; assert_eq "$(lvl)" "warn" "kernel pressure warn: warn"
set_mem 55 1 7000; assert_eq "$(lvl)" "ok" "swap alone is not pressure (macOS keeps swap for hours)"
set_mem 55 2 7000; assert_contains "$("$SG" mem | jq -r '.reasons | join(";")')" "6.8 GB of swap in use" "…but counts while memory is tight"
set_mem 8 1 1000;  assert_eq "$(lvl)" "critical" "free under 10%: critical"
set_mem 55 4 1000; assert_eq "$(lvl)" "critical" "kernel pressure critical: critical"
set_mem 55 1 13000; assert_eq "$(lvl)" "ok" "even half of RAM in swap, with memory free: ok"
set_mem 15 1 13000
snap="$("$SG" mem)"
assert_eq "$(printf '%s' "$snap" | jq -r .level)" "critical" "tight memory and swap over half of RAM: critical"
assert_contains "$(printf '%s' "$snap" | jq -r '.reasons[0]')" "12.7 GB of swap in use" "the reason names the swap"
assert_eq "$(SWAP_MEM_WARN_FREE=60 SWAP_MEM_CRIT_FREE=50 "$SG" mem | jq -r .level)" "critical" "thresholds can be set"

# --- session notes (checkpoint PostToolUse hook) ----------------------------
hook() { if [ -n "${2:-}" ]; then printf '{"session_id":"%s","agent_id":"%s","tool_name":"Bash"}' "$1" "$2"
         else printf '{"session_id":"%s","tool_name":"Bash"}' "$1"; fi | "$SG" checkpoint --hook; }
set_mem 55 1 1000; "$SG" mem >/dev/null
assert_eq "$(hook s1)" "" "memory ok: silent"
set_mem 15 1 1000; "$SG" mem >/dev/null
ctx="$(hook s1 | jq -r .hookSpecificOutput.additionalContext)"
assert_contains "$ctx" "memory on this Mac is getting tight (only 15% of memory is free" "warn: a note naming why"
assert_contains "$ctx" "at most 2 subagents" "warn: keep fan-out small"
assert_eq "$(hook s1)" "" "once per session, not on every tool call"
assert_contains "$(hook s1 a7 | jq -r .hookSpecificOutput.additionalContext)" "You are a subagent" "a subagent gets its own short note"
assert_contains "$(printf '{ "session_id" : "s1", "agent_id": "a8", "tool_name": "Bash" }' | "$SG" checkpoint --hook | jq -r .hookSpecificOutput.additionalContext)" "You are a subagent" "ids are read from spaced JSON too"
assert_contains "$(printf '{"session_id":"s1","agent_id":7,"tool_name":"Bash"}' | "$SG" checkpoint --hook | jq -r .hookSpecificOutput.additionalContext)" "You are a subagent" "…and a non-string id falls back to jq"
assert_contains "$(printf '{"session_id":"m1","tool_name":"x","tool_input":{"agent_id":"w1","session_id":"o1"}}' | "$SG" checkpoint --hook | jq -r .hookSpecificOutput.additionalContext)" "Keep fan-out small" "ids inside a tool's input are ignored: a main session stays a main session"
assert_eq "$([ -f "$B/ctx/m1.mem" ] && [ ! -f "$B/ctx/m1.w1.mem" ] && [ ! -f "$B/ctx/o1.mem" ] && echo right)" "right" "…and its note is recorded under its own id"
assert_contains "$(printf '{"session_id":"m2","tool_name":"x","tool_input":{},"agent_id":"a9"}' | "$SG" checkpoint --hook | jq -r .hookSpecificOutput.additionalContext)" "You are a subagent" "a top-level agent_id after the payload still counts"
set_mem 8 1 1000; "$SG" mem >/dev/null
ctx="$(hook s1 | jq -r .hookSpecificOutput.additionalContext)"
assert_contains "$ctx" "critically low on memory" "warn → critical notes the same session again"
assert_contains "$ctx" "do not start subagents, workflows, parallel test runs or builds" "critical: hold back"
assert_contains "$(tail -n 1 "$B/mem.log")" '"action":"nudged"' "notes are logged"
# A stale sample (the watcher died) says nothing about now.
jq -c '.at = 1000' "$B/cache/mem.json" > "$B/m" && mv "$B/m" "$B/cache/mem.json"
assert_eq "$(hook s2)" "" "a stale sample: silent"
"$SG" mem >/dev/null
"$SG" mem nudge off >/dev/null
assert_eq "$(hook s3)" "" "nudge off: silent"
"$SG" mem nudge on >/dev/null
assert_contains "$(hook s3)" "critically low" "nudge on again"
# With the account near its limit too, both notes come in one message.
write_seq 1
NOW="$(date +%s)"
cat > "$B/cache/usage.json" <<EOF
{"schemaVersion":2,"accounts":{"1":{"fetchedAt":$NOW,"lastGood":{"five_hour":{"pct":20,"resets_at":"$(iso_in 7200)"},
 "seven_day":{"pct":97,"resets_at":"$(iso_in 200000)"},"scoped":[]}}}}
EOF
ctx="$(hook s4 | jq -r .hookSpecificOutput.additionalContext)"
assert_contains "$ctx" "account work is at week 97%" "checkpoint note still works"
assert_contains "$ctx" "critically low on memory" "…and the memory note rides along"
"$SG" checkpoint off >/dev/null
assert_contains "$(hook s5)" "critically low on memory" "checkpoint off does not silence memory"
"$SG" checkpoint on >/dev/null

# --- agent gate (PreToolUse) ------------------------------------------------
gate() { printf '{"session_id":"g","tool_name":"%s","tool_input":{}}' "${1:-Agent}" | "$SG" mem --gate; }
set_mem 8 1 1000; "$SG" mem >/dev/null
out="$(gate Workflow)"
assert_eq "$(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecision)" "deny" "critical: a new workflow is refused"
assert_contains "$(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecisionReason)" "swap-guard mem gate off" "…saying how to turn it off"
assert_eq "$(OVERCLAUDE_MEM_GATE=off gate)" "" "OVERCLAUDE_MEM_GATE=off lets it through"
"$SG" mem gate off >/dev/null; assert_eq "$(gate)" "" "gate off lets it through"
"$SG" mem gate on >/dev/null
set_mem 15 1 1000; "$SG" mem >/dev/null
assert_eq "$(gate)" "" "warn: agents are not refused"

# --- orphans: found, attributed, cleaned -------------------------------------
# Real processes, all carrying $TAG; SWAP_MEM_TEST_ONLY makes swap-guard look at
# nothing else, so the developer's own processes are never candidates.
TAG="ocmemtest$$x$RANDOM"
mkdir -p "$HOME/bin"
printf '#!/bin/bash\nsleep 300 &\nwait\n' > "$HOME/bin/$TAG-idle"
cp "$HOME/bin/$TAG-idle" "$HOME/bin/$TAG-bg"; cp "$HOME/bin/$TAG-idle" "$HOME/bin/$TAG-pipe"
printf '#!/bin/bash\nexec python3 -c "import socket,time; s=socket.socket(); s.bind((\\"127.0.0.1\\",0)); s.listen(1); time.sleep(300)" %s\n' "$TAG" > "$HOME/bin/$TAG-srv"
# A background Claude session (claude --bg / -p) whose argv mentions mcp, and an npx-style
# wrapper with a session under it: neither may ever be treated as an orphan.
printf '#!/bin/bash\nsleep 300 &\nwait\n' > "$HOME/bin/claude"
printf '#!/bin/bash\n"%s/bin/claude" --strict-mcp-config --print %s &\nwait\n' "$HOME" "$TAG" > "$HOME/bin/$TAG-wrap"
chmod +x "$HOME/bin/"*
trap 'pkill -f "$TAG" 2>/dev/null' EXIT
# -idle: stdin and stdout are pipes whose other ends are gone (a stdio helper whose
# session died). -bg: stdin /dev/null, like a live session's own `cmd &`. -pipe: a
# session's `producer | cmd > file &` (dead stdin, stdout a file). -srv: on a port.
( : | "$HOME/bin/$TAG-idle" 2>/dev/null | : & )
( : | "$HOME/bin/$TAG-pipe" > "$HOME/pipe.out" 2>&1 & )
( "$HOME/bin/$TAG-bg" >/dev/null 2>&1 </dev/null & )
( "$HOME/bin/$TAG-srv" >/dev/null 2>&1 </dev/null & )
( : | "$HOME/bin/claude" --mcp-config cfg.json --print "$TAG" >/dev/null 2>&1 & )
( "$HOME/bin/$TAG-wrap" >/dev/null 2>&1 </dev/null & )
sleep 1.5
pid_of() { ps -axwwo pid=,ppid=,command= | awk -v pat="$1" -v pp="${2:-}" 'index($0, pat) && (pp == "" || $2 == pp) { print $1; exit }'; }
idle_pid="$(pid_of "$HOME/bin/$TAG-idle" 1)"; idle_child="$(pgrep -P "$idle_pid" | head -n 1)"
bg_pid="$(pid_of "$HOME/bin/$TAG-bg" 1)"; pipe_pid="$(pid_of "$HOME/bin/$TAG-pipe" 1)"
srv_pid="$(pid_of "Python -c import socket" 1)"; [ -n "$srv_pid" ] || srv_pid="$(pid_of "time.sleep(300) $TAG" 1)"
cl_pid="$(pid_of "--mcp-config cfg.json --print $TAG" 1)"
wrap_pid="$(pid_of "$HOME/bin/$TAG-wrap" 1)"; wrapped="$(pgrep -P "$wrap_pid" | head -n 1)"
printf '{"pid":%s,"sessionId":"bg1","cwd":"%s","status":"busy"}\n' "$cl_pid" "$HOME" > "$HOME/.claude/sessions/$cl_pid.json"
printf '{"pid":%s,"sessionId":"bg2","cwd":"%s","status":"busy"}\n' "$wrapped" "$HOME" > "$HOME/.claude/sessions/$wrapped.json"
for v in idle_pid idle_child bg_pid pipe_pid srv_pid cl_pid wrap_pid wrapped; do
  case "$(eval "printf '%s' \"\$$v\"")" in ''|*[!0-9]*) fail "test setup: $v not found";; *) pass;; esac
done
export SWAP_MEM_TEST_ONLY="$TAG" SWAP_MEM_ORPHAN_MIN=0
snap="$("$SG" mem)"
orph() { printf '%s' "$snap" | jq -c --argjson p "${1:-0}" '[.orphans[] | select(.pid == $p)][0]'; }
assert_eq "$(orph "$idle_pid" | jq -c '[.auto, .sessionGone]')" "[true,true]" "an idle helper whose session's pipe is gone is auto-cleanable"
assert_eq "$(orph "$idle_pid" | jq -r '.pids | length')" "2" "its child process belongs to it"
assert_eq "$(orph "$idle_pid" | jq -r '.pids[0]')" "$idle_pid" "the orphan itself comes first"
assert_eq "$(orph "$bg_pid" | jq -c '[.auto, .sessionGone]')" "[false,false]" "stdin /dev/null (a live session's cmd &): never auto-cleaned"
assert_eq "$(orph "$pipe_pid" | jq -c '[.auto, .sessionGone]')" "[false,false]" "dead stdin but stdout to a file (producer | cmd > file &): never auto-cleaned"
assert_eq "$(orph "$srv_pid" | jq -r '.auto')" "false" "an orphan listening on a port is never auto-cleaned"
assert_eq "$(orph "$srv_pid" | jq -r '.ports | length')" "1" "…and its port is shown"
assert_eq "$(orph "$cl_pid")" "null" "a background Claude session is never an orphan"
assert_eq "$(printf '%s' "$snap" | jq --argjson p "$cl_pid" 'any(.sessions[]; .pid == $p)')" "true" "…it is listed as a session"
assert_eq "$(orph "$wrap_pid")" "null" "a wrapper with a live session under it is never an orphan"
assert_eq "$(SWAP_MEM_ORPHAN_MIN=3600 "$SG" mem | jq --argjson p "${idle_pid:-0}" '[.orphans[] | select(.pid == $p)][0].auto')" "false" "a young orphan is left alone"
txt="$("$SG" mem --text)"
assert_contains "$txt" "Orphaned helper processes" "the report lists orphans"
assert_contains "$txt" "listening on :" "…with the listening one marked"
assert_contains "$txt" "may still belong to a live session" "…and the unprovable one"
# Not killed while memory is fine: the tick only cleans when tight.
set_mem 55 1 1000; : > "$HOME/notes"
"$SG" mem tick >/dev/null
assert_eq "$(kill -0 "$idle_pid" 2>/dev/null && echo alive)" "alive" "memory ok: orphans are left running"
out="$("$SG" mem clean --dry-run)"
assert_eq "$(printf '%s' "$out" | jq -c '[.dryRun, [.cleaned[].pid]]')" "[true,[$idle_pid]]" "clean --dry-run lists only the provable one"
assert_eq "$(kill -0 "$idle_pid" 2>/dev/null && echo alive)" "alive" "…and kills nothing"
assert_contains "$("$SG" mem clean --pid 1)" "is not an orphaned helper process" "clean --pid refuses anything else"
assert_contains "$("$SG" mem clean --pid "$cl_pid")" "is not an orphaned helper process" "…including a session"
assert_contains "$("$SG" mem clean --dryrun)" "unknown argument: --dryrun" "a mistyped option is refused, not a real clean"
assert_contains "$("$SG" mem clean "$idle_pid")" "unknown argument" "a bare pid is refused"
assert_eq "$(kill -0 "$idle_pid" 2>/dev/null && echo alive)" "alive" "…and nothing was killed"
assert_eq "$("$SG" mem clean --dry-run --pid="$bg_pid" --pid "$srv_pid" | jq -c '[.cleaned[].pid] | sort')" "$(printf '[%s,%s]' "$bg_pid" "$srv_pid" | jq -c 'sort')" "--pid can name several (and --pid=N works)"
# The pid-reuse guard: a process that started at another time is never killed.
( . "$SG"; _mem_kill "$idle_pid:12345" ) ; rc=$?
assert_eq "$rc:$(kill -0 "$idle_pid" 2>/dev/null && echo alive)" "1:alive" "a pid whose start time changed is not killed"
# Tight memory: the tick cleans the provable orphan (and its child), nothing else, and says so.
"$SG" mem autoclean off >/dev/null
set_mem 15 1 1000
"$SG" mem tick >/dev/null
assert_eq "$(kill -0 "$idle_pid" 2>/dev/null && echo alive)" "alive" "autoclean off: nothing is killed"
"$SG" mem autoclean on >/dev/null
rm -f "$B/cache/mem.state"; : > "$HOME/notes"
out="$("$SG" mem tick)"
sleep 0.5
assert_eq "$(kill -0 "$idle_pid" 2>/dev/null && echo alive || echo gone)" "gone" "tight memory: the provable orphan is cleaned"
assert_eq "$(kill -0 "$idle_child" 2>/dev/null && echo alive || echo gone)" "gone" "…with its child"
assert_eq "$(kill -0 "$bg_pid" 2>/dev/null && kill -0 "$pipe_pid" 2>/dev/null && kill -0 "$srv_pid" 2>/dev/null && kill -0 "$cl_pid" 2>/dev/null && kill -0 "$wrapped" 2>/dev/null && echo alive)" "alive" "…and nothing else: background job, server, sessions"
assert_eq "$(printf '%s' "$out" | jq -r '.cleaned[0]')" "$idle_pid" "the tick reports what it cleaned"
assert_contains "$(cat "$HOME/notes")" "Memory warn" "a notification when memory gets tight"
assert_contains "$(cat "$HOME/notes")" "orphaned process" "…saying what was freed"
assert_contains "$(grep cleaned "$B/mem.log")" "$idle_pid" "cleanups are logged"
out="$("$SG" mem clean --pid "$srv_pid")"
sleep 0.5
assert_eq "$(kill -0 "$srv_pid" 2>/dev/null && echo alive || echo gone)" "gone" "clean --pid stops a listed orphan on request"
export SWAP_MEM_TEST_ONLY="$NOMATCH"; unset SWAP_MEM_ORPHAN_MIN
rm -f "$HOME/.claude/sessions/"*.json
pkill -f "$TAG" 2>/dev/null

# --- notifications: on the way up, again while critical, once on recovery ---
: > "$HOME/notes"
"$SG" mem tick >/dev/null
assert_eq "$(cat "$HOME/notes")" "" "still warn: no repeat"
set_mem 8 1 1000; "$SG" mem tick >/dev/null
assert_contains "$(cat "$HOME/notes")" "Memory critical" "warn → critical notifies"
: > "$HOME/notes"; "$SG" mem tick >/dev/null
assert_eq "$(cat "$HOME/notes")" "" "critical again within 15 min: quiet"
printf '2 1000\n' > "$B/cache/mem.state"; "$SG" mem tick >/dev/null
assert_contains "$(cat "$HOME/notes")" "Memory critical" "still critical 15 min later: reminded"
: > "$HOME/notes"; set_mem 55 1 1000; "$SG" mem tick >/dev/null
assert_eq "$(cat "$HOME/notes")" "" "just back to ok: no all-clear yet"
read -r nr na _ < "$B/cache/mem.state"; printf '%s %s %s\n' "$nr" "$na" "$(( $(date +%s) - 400 ))" > "$B/cache/mem.state"
"$SG" mem tick >/dev/null
assert_contains "$(cat "$HOME/notes")" "back to normal" "ok for 5 minutes: one all-clear"
# Flapping around a line notifies once, not on every crossing.
"$SG" mem autoclean off >/dev/null; rm -f "$B/cache/mem.state"; : > "$HOME/notes"
for f in 9 11 9 11 9 11 9 11; do set_mem "$f" 1 1000; "$SG" mem tick >/dev/null; done
assert_eq "$(grep -c 'Memory critical' "$HOME/notes")" "1" "critical/warn flapping: one notification"
rm -f "$B/cache/mem.state"; : > "$HOME/notes"
for f in 19 21 19 21 19 21; do set_mem "$f" 1 1000; "$SG" mem tick >/dev/null; done
assert_eq "$(grep -c 'Memory' "$HOME/notes")" "1" "warn/ok flapping: one notification"
"$SG" mem autoclean on >/dev/null; set_mem 55 1 1000
assert_eq "$("$SG" mem tick --no-notify | jq -r .level)" "ok" "--no-notify still ticks"

# --- the watcher agent --------------------------------------------------------
out="$("$SG" mem watch on)"
plist="$HOME/Library/LaunchAgents/com.overclaude.memwatch.plist"
assert_eq "$(printf '%s' "$out" | jq -r .generated)" "true" "watch on writes the agent"
assert_contains "$(cat "$plist")" "<string>mem</string>" "…running swap-guard mem"
assert_contains "$(cat "$plist")" "<integer>60</integer>" "…every minute"
out="$("$SG" mem watch off)"
assert_eq "$([ -f "$plist" ] && echo yes || echo no):$([ -f "$B/memwatch.off" ] && echo off)" "no:off" "watch off removes it and is remembered"
assert_eq "$("$SG" mem watch status | jq -c '[.turnedOff, .autoClean, .agentGate, .sessionNotes]')" '[true,true,true,true]' "watch status"
assert_contains "$("$SG" mem bogus 2>&1)" "usage: swap-guard mem" "unknown option: usage"

# --- statusline -----------------------------------------------------------------
sl() { printf '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"%s"}}' "$HOME" | SWAP_NO_REFRESH=1 bash "$SL" | sed -n 2p | strip_ansi; }
set_mem 55 1 3700; "$SG" mem >/dev/null
assert_contains "$(sl)" "mem 45% · swap 3.6G" "statusline: memory in use and swap"
set_mem 55 1 500; "$SG" mem >/dev/null
assert_absent "$(sl)" "swap" "swap under 1 GB is not shown"
set_mem 15 1 500; "$SG" mem >/dev/null
assert_contains "$(sl)" "⚠ mem 85%" "warn: flagged"
set_mem 5 1 500; "$SG" mem >/dev/null
assert_contains "$(sl)" "⚠ mem 95% critical" "critical: flagged"
assert_absent "$(SWAP_HIDE_MEM=1 sl)" "mem " "SWAP_HIDE_MEM hides it"
touch -t "$(date -r $(( $(date +%s) - 900 )) +%Y%m%d%H%M.%S)" "$B/cache/mem.json"
assert_absent "$(sl)" "mem " "a sample older than 10 min is not shown"

rm -rf "$HOME"
finish
