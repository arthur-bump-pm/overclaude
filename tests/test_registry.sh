#!/bin/bash
# Artifact registry: artifact-log hook, find/list/link, backfill from transcripts.
. "$(dirname "$0")/lib.sh"
new_home
write_seq 2
IDX="$HOME/.claude-swap-backup/artifacts/index.jsonl"

SRC="$HOME/scratch/villas.html"; mkdir -p "$HOME/scratch"; echo '<title>Villas</title>' > "$SRC"
post() { "$SG" artifact-log <<<"$1"; }
post "$(jq -cn --arg p "$SRC" '{session_id:"s1", cwd:"/w", tool_name:"Artifact",
  tool_input:{file_path:$p}, tool_response:{url:"https://claude.ai/artifact/AAA111", artifact_id:"AAA111", title:"Bali villa comparison"}}')"
assert_eq "$(wc -l < "$IDX" | tr -d ' ')" "1" "a publish adds one record"
assert_eq "$(jq -r .alias "$IDX")" "personal" "owner = the account active at publish time"
assert_eq "$(cat "$HOME/.claude-swap-backup/artifacts/src/AAA111/villas.html")" "<title>Villas</title>" "page source copied to a durable dir"

post '{"tool_name":"Artifact","tool_input":{"action":"publish","title":"Office map"},"tool_response":"Published x.html at https://claude.ai/artifact/BBB222 (Version 1)"}'
assert_eq "$(tail -n 1 "$IDX" | jq -r .artifact_id)" "BBB222" "a text tool response is parsed for the URL"

post '{"tool_name":"Artifact","tool_input":{"action":"read","url":"https://claude.ai/artifact/AAA111"},"tool_response":{"url":"https://claude.ai/artifact/AAA111"}}'
post '{"tool_name":"Artifact","tool_input":{"asset":true,"url":"https://claude.ai/artifact/AAA111"},"tool_response":{"url":"https://claude.ai/artifact/AAA111"}}'
post '{"tool_name":"Bash","tool_input":{},"tool_response":{"url":"https://claude.ai/artifact/CCC333"}}'
assert_eq "$(wc -l < "$IDX" | tr -d ' ')" "2" "reads, asset uploads and other tools are not logged"

write_seq 1
post "$(jq -cn --arg p "$SRC" '{tool_name:"Artifact", tool_input:{file_path:$p}, tool_response:{url:"https://claude.ai/artifact/AAA111", artifact_id:"AAA111", title:"Bali villa comparison"}}')"
out="$("$SG" artifacts find villa)"
assert_eq "$(printf '%s' "$out" | jq length)" "1" "find folds repeat publishes into one entry"
assert_eq "$(printf '%s' "$out" | jq -r '.[0].publishes')" "2" "publish count kept"
assert_eq "$("$SG" artifacts find office | jq -r '.[0].artifact_id')" "BBB222" "find matches the title"
assert_eq "$("$SG" artifacts list --account work | jq length)" "0" "list filters by owner"
assert_eq "$("$SG" artifacts find nothing-matches | jq length)" "0" "no match → empty list"

assert_eq "$("$SG" artifacts find villa | jq -r '.[0].owner')" "personal" "owner stays the account that CREATED it, even after another account updates it"
assert_eq "$("$SG" artifacts find villa | jq -r '.[0].lastPublishedBy')" "work" "the latest publisher is kept separately"
assert_eq "$("$SG" artifacts list --account personal | jq -r '.[0].artifact_id')" "AAA111" "list --account finds it under its creator"
printf '{"ts":1,"kind":"publ' >> "$IDX"; printf '\n' >> "$IDX"
assert_eq "$("$SG" artifacts find villa | jq length)" "1" "a torn index line does not hide the other records"
"$SG" artifacts link https://claude.ai/artifact/BBB222 https://claude.ai/artifact/DDD444 >/dev/null
assert_eq "$("$SG" artifacts find office | jq -r '.[0].republishedAs')" "DDD444" "link records the republished copy"
# Real ids: tool responses carry a UUID artifact_id while URLs end in a short slug.
post '{"tool_name":"Artifact","tool_input":{},"tool_response":{"url":"https://claude.ai/artifact/27gabQxAM3","artifact_id":"0907fe29-d3c2-4ba4-b2f5-1a0594497cb9","title":"Office rack"}}'
post '{"tool_name":"Artifact","tool_input":{},"tool_response":{"url":"https://claude.ai/artifact/9zzNewSlug","artifact_id":"11111111-2222-3333-4444-555555555555","title":"Office rack copy"}}'
"$SG" artifacts link https://claude.ai/artifact/27gabQxAM3 https://claude.ai/artifact/9zzNewSlug >/dev/null
assert_eq "$("$SG" artifacts find rack | jq -r '.[] | select(.title == "Office rack") | .republishedAs')" "https://claude.ai/artifact/9zzNewSlug" "linking by URL works when ids are UUIDs (reported as the new URL)"
assert_eq "$("$SG" artifacts find rack | jq -r '.[] | select(.title == "Office rack copy") | .republishOf')" "https://claude.ai/artifact/27gabQxAM3" "and the copy points back to the original"
"$SG" artifacts link onlyone >/dev/null 2>&1
assert_eq "$?" "1" "link needs two different ids"

# Backfill: a transcript publish from before the hook existed; owner from cswap's switch log.
T="$HOME/.claude/projects/-w"; mkdir -p "$T"
cat > "$HOME/.claude-swap-backup/claude-swap.log" <<'EOF'
2026-07-19 20:18:40,385 - INFO - Switched from account 2 to 1
2026-07-23 10:57:40,335 - INFO - Switched from account 1 to 2
EOF
ts="$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-07-20 12:00:00' +%s)"
iso="$(date -u -r "$ts" '+%Y-%m-%dT%H:%M:%S.000Z')"
{ jq -cn '{type:"assistant", message:{content:[{type:"tool_use", id:"tu1", name:"Artifact", input:{file_path:"/tmp/x/old.html"}}]}}'
  jq -cn --arg ts "$iso" '{type:"user", timestamp:$ts, sessionId:"old", cwd:"/w",
     message:{content:[{tool_use_id:"tu1", type:"tool_result"}]},
     toolUseResult:{url:"https://claude.ai/artifact/OLD999", artifact_id:"OLD999", title:"Old report", path:"/tmp/x/old.html"}}'
  jq -cn --arg ts "$iso" '{type:"user", timestamp:$ts, message:{content:[{tool_use_id:"w9", type:"tool_result"}]},
     toolUseResult:{url:"https://example.com/fetched-page", code:200}}'
} > "$T/old.jsonl"
assert_eq "$("$SG" artifacts index | jq -r .backfilled)" "1" "backfill adds the past publish"
assert_eq "$("$SG" artifacts find old | jq -r '.[0].owner')" "work" "owner inferred from the switch log (account 1 then)"
assert_eq "$("$SG" artifacts find old | jq -r '.[0].inferredOwner')" "true" "inferred owner is marked"
assert_eq "$("$SG" artifacts index | jq -r .backfilled)" "0" "backfill is idempotent"

rm -rf "$HOME"
finish
