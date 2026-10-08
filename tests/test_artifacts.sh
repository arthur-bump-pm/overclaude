#!/bin/bash
# swap-guard artifacts: transcript → manifest + durable source copies.
. "$(dirname "$0")/lib.sh"
new_home
CWD=/tmp/overclaude-art-proj
FLAT="$(printf '%s' "$CWD" | sed 's/[^A-Za-z0-9]/-/g')"
TD="$HOME/.claude/projects/$FLAT"; mkdir -p "$TD/sid1/subagents" "$HOME/src"
echo '<h1>page</h1>' > "$HOME/src/page.html"; echo 'body{}' > "$HOME/src/s.css"
echo '<p>sub</p>' > "$HOME/src/sub.html"

cat > "$TD/sid1.jsonl" <<EOF
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Artifact","input":{"file_path":"$HOME/src/page.html","files":{"css/s.css":"$HOME/src/s.css"}}}]}}
{"type":"user","timestamp":"2026-10-08T01:00:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]},"toolUseResult":{"url":"https://claude.ai/code/artifact/aaa-1","artifact_id":"aaa-1","title":"Page v1","path":"$HOME/src/page.html","audience":"owner"}}
{"type":"user","timestamp":"2026-10-08T02:00:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2"}]},"toolUseResult":{"url":"https://claude.ai/code/artifact/aaa-1","artifact_id":"aaa-1","title":"Page v2","path":"$HOME/src/page.html"}}
{"type":"user","timestamp":"2026-10-08T03:00:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"t3"}]},"toolUseResult":{"url":"https://claude.ai/code/artifact/gone-2","artifact_id":"gone-2","title":"Lost","path":"/nonexistent/x.html"}}
EOF
cat > "$TD/sid1/subagents/agent-1.jsonl" <<EOF
{"type":"user","timestamp":"2026-10-08T04:00:00Z","message":{"content":[{"type":"tool_result","tool_use_id":"t9"}]},"toolUseResult":{"url":"https://claude.ai/code/artifact/sub-3","artifact_id":"sub-3","title":"From subagent","path":"$HOME/src/sub.html"}}
EOF

m=$("$SG" artifacts --session sid1 --cwd "$CWD")
assert_eq "$(printf '%s' "$m" | jq '.artifacts | length')" "3" "one record per artifact (deduped), subagents included"
assert_eq "$(printf '%s' "$m" | jq -r '.artifacts[] | select(.artifact_id=="aaa-1") | .title')" "Page v2" "last touch wins"
saved=$(printf '%s' "$m" | jq -r '.artifacts[] | select(.artifact_id=="aaa-1") | .saved')
[ -f "$saved" ] && pass || fail "page source copied" "$saved"
css=$(printf '%s' "$m" | jq -r '.artifacts[] | select(.artifact_id=="aaa-1") | .savedFiles["css/s.css"]')
[ -f "$css" ] && pass || fail "supporting file copied under its published path" "$css"
assert_eq "$(printf '%s' "$m" | jq -r '.artifacts[] | select(.artifact_id=="gone-2") | .saved')" "null" "missing source → saved null"
[ -f "$(printf '%s' "$m" | jq -r .manifest)" ] && pass || fail "manifest written"
assert_eq "$("$SG" artifacts --session ../x --cwd "$CWD" | jq -r .error)" "no-session-id" "path-traversal session id rejected"

finish
