#!/bin/bash
# swap-guard route-guard (PreToolUse Agent|Workflow): un-routed subagents on Fable are denied.
. "$(dirname "$0")/lib.sh"
new_home
CTX="$HOME/.claude-swap-backup/ctx"; mkdir -p "$CTX"
relay() { printf '{"pct":10,"ts":1,"model":"%s"}' "$1" > "$CTX/s1.json"; }
agent() { jq -cn --argjson ti "$1" '{session_id:"s1", cwd:"/w", tool_name:"Agent", tool_input:$ti}' | "$SG" route-guard; }
wf()    { jq -cn --arg s "$1" '{session_id:"s1", cwd:"/w", tool_name:"Workflow", tool_input:{script:$s}}' | "$SG" route-guard; }
decision() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || echo allow; }

relay claude-fable-5-1
out="$(agent '{"prompt":"find bugs","description":"scan","subagent_type":"general-purpose"}')"
assert_eq "$(decision "$out")" "deny" "Fable session: Agent without model → denied"
assert_contains "$out" "haiku (scouting" "the reason says which model to pick"
assert_eq "$(decision "$(agent '{"prompt":"x","description":"x"}')")" "deny" "no subagent_type (general-purpose default) → denied"
assert_eq "$(agent '{"prompt":"x","description":"x","model":"sonnet"}')" "" "explicit model → allowed silently"
assert_eq "$(agent '{"prompt":"x","description":"x","model":"fable"}')" "" "explicit fable (deliberate apex) → allowed"
assert_eq "$(agent '{"prompt":"x","description":"x","subagent_type":"fork"}')" "" "fork → allowed (inherits by design)"
assert_eq "$(agent '{"prompt":"x","description":"x","subagent_type":"Explore"}')" "" "built-in type with its own defaults → allowed"

mkdir -p "$HOME/.claude/agents"
printf -- '---\nname: pinned\nmodel: haiku\n---\nbody\n' > "$HOME/.claude/agents/pinned.md"
printf -- '---\nname: loose\ndescription: d\n---\nbody\n' > "$HOME/.claude/agents/loose.md"
assert_eq "$(agent '{"prompt":"x","description":"x","subagent_type":"pinned"}')" "" "custom agent whose definition pins a model → allowed"
assert_eq "$(decision "$(agent '{"prompt":"x","description":"x","subagent_type":"loose"}')")" "deny" "custom agent without a model inherits → denied"

relay claude-sonnet-5-5
assert_eq "$(agent '{"prompt":"x","description":"x"}')" "" "Sonnet session: inheriting is cheap → allowed"
rm -f "$CTX/s1.json"
assert_eq "$(agent '{"prompt":"x","description":"x"}')" "" "unknown session model → allowed (never guess)"

relay claude-fable-5-1
GOOD="const a = await agent('scan', {model: 'haiku', label: 'scout (haiku/low)'})
const r = await agent(\`Synthesize \${x}\`, {effort: 'xhigh', label: 'synthesize (fable/xhigh)'})"
assert_eq "$(wf "$GOOD")" "" "workflow: every call routed or deliberately fable-labelled → allowed"
BAD="export const meta = {name: 'x'}
// agent('commented out') is ignored
const a = await agent('find bugs in (nested) parens', {effort: 'medium'})
const b = await agent(\"verify\", {model: 'opus'})
const c = agent('scout', { label: 'scout' })"
out="$(wf "$BAD")"
assert_eq "$(decision "$out")" "deny" "workflow with un-routed agent() calls → denied"
assert_contains "$out" "2 agent() call(s)" "counts exactly the un-routed calls (comment ignored, nested parens handled)"
assert_contains "$out" "find bugs in (nested) parens" "names the offending call"

# Parser hardening (QA/review repros): prompt text can neither create a call nor satisfy the check.
unrouted() { printf '%s' "$1" | bash -c '. "$1"; _workflow_unrouted' _ "$SG" | grep -c . | tr -d ' '; }
assert_eq "$(unrouted "agent('Tell each agent (one per file) to list exports', {model:'haiku'})")" "0" "agent( inside a prompt string is not a call"
assert_eq "$(unrouted "const cheap = {model:'haiku'}; agent('scan', cheap)")" "0" "options passed by variable are allowed (cannot see inside)"
assert_eq "$(unrouted "agent('x', {...base, label:'find'})")" "0" "a spread in the options is allowed"
assert_eq "$(unrouted "agent('x', { model })")" "0" "shorthand { model } counts"
assert_eq "$(unrouted "agent('Summarize the fable of the fox', {effort:'low'})")" "1" "fable in the PROMPT does not exempt a call"
assert_eq "$(unrouted 'agent(`Check the apex domain`, {label:"dns"})')" "1" "apex in a template prompt does not exempt it"
assert_eq "$(unrouted 'agent(`Check the model: field`)')" "1" "model: in the prompt text is not a model key"
assert_eq "$(unrouted "agent('x', {model: ''})")" "1" "an empty model is unrouted"
assert_eq "$(unrouted "agent('x', {model: undefined, effort:'low'})")" "1" "model: undefined is unrouted"
assert_eq "$(unrouted "const re = /'/; const url = 'http://example.com'; await agent('scan everything')")" "1" "a regex literal with a quote does not hide the next call"
assert_eq "$(unrouted "const re = /[\"]/; // agent('x') in a comment")" "0" "a regex literal does not un-hide a comment"
assert_eq "$(unrouted "obj.agent('x'); subagent('y')")" "0" "obj.agent( and subagent( are not the Workflow agent()"
assert_eq "$(unrouted "agent('s', {effort:'xhigh', label:'synthesize (fable/xhigh)'})")" "0" "a fable label is a deliberate top-tier stage"
big="$(for k in $(seq 1 1500); do printf "await agent('step %s', {model:'haiku', label:'s', re: /[(]/});\n" "$k"; done)"
t0=$(date +%s); n=$(unrouted "$big"); t1=$(date +%s)
assert_eq "$n" "0" "1500 routed calls with regex literals parse cleanly"
assert_le "$((t1 - t0))" "3" "and fast (well under the 10 s hook timeout)"

printf '%s' "$BAD" > "$HOME/wf.js"
out="$(jq -cn --arg p "$HOME/wf.js" '{session_id:"s1", tool_name:"Workflow", tool_input:{scriptPath:$p}}' | "$SG" route-guard)"
assert_eq "$(decision "$out")" "deny" "scriptPath is read too"
assert_eq "$(jq -cn '{session_id:"s1", tool_name:"Workflow", tool_input:{name:"saved-one"}}' | "$SG" route-guard)" "" "saved workflow by name → its author owns routing"

# The session model comes from the transcript first (works before any statusline render,
# with a custom statusline, and follows /model).
rm -f "$CTX/s1.json"
TP="$HOME/t.jsonl"; echo '{"type":"assistant","message":{"model":"claude-fable-5-1"}}' > "$TP"
out="$(jq -cn --arg tp "$TP" '{session_id:"s1", cwd:"/w", transcript_path:$tp, tool_name:"Agent", tool_input:{prompt:"x", description:"x"}}' | "$SG" route-guard)"
assert_eq "$(decision "$out")" "deny" "model read from the transcript when there is no relay"
echo '{"type":"assistant","message":{"model":"claude-sonnet-5-5"}}' >> "$TP"
out="$(jq -cn --arg tp "$TP" '{session_id:"s1", cwd:"/w", transcript_path:$tp, tool_name:"Agent", tool_input:{prompt:"x", description:"x"}}' | "$SG" route-guard)"
assert_eq "$out" "" "after /model to Sonnet the latest entry wins"
assert_eq "$(decision "$(jq -cn --arg tp "$TP" '{session_id:"s1", transcript_path:$tp, tool_name:"Task", tool_input:{prompt:"x"}}' | sed 's/sonnet-5-5/fable-5-1/' | (echo '{"type":"assistant","message":{"model":"claude-fable-5-1"}}' >> "$TP"; cat) | "$SG" route-guard)")" "deny" "the older Task tool name is guarded too"
relay claude-fable-5-1
mkdir -p "$HOME/proj/.claude/agents" "$HOME/proj/sub/dir"
printf -- '---\r\nname: crlf\r\nmodel: sonnet\r\n---\r\nbody\r\n' > "$HOME/proj/.claude/agents/crlf.md"
out="$(jq -cn --arg cwd "$HOME/proj/sub/dir" '{session_id:"s1", cwd:$cwd, tool_name:"Agent", tool_input:{prompt:"x", description:"x", subagent_type:"crlf"}}' | "$SG" route-guard)"
assert_eq "$out" "" "a project agent found from a subfolder, with CRLF line endings, that pins a model → allowed"

"$SG" route-guard off >/dev/null
assert_eq "$(agent '{"prompt":"x","description":"x"}')" "" "route-guard off → allowed"
assert_eq "$("$SG" route-guard status | jq -r .routeGuard)" "false" "status reports off"
"$SG" route-guard on >/dev/null
assert_eq "$(OVERCLAUDE_ROUTE_GUARD=off agent '{"prompt":"x","description":"x"}')" "" "env off switch works"

rm -rf "$HOME"
finish
