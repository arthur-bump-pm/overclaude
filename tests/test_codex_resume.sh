#!/bin/bash
. "$(dirname "$0")/lib.sh"
new_home
RUN="$REPO/bin/overclaude-codex-continue"
mkdir -p "$HOME/stubs" "$HOME/codex" "$HOME/work"
export PATH="$HOME/stubs:$PATH" TEST_CODEX_HOME="$HOME/codex" OVERCLAUDE_CODEX_HOME="$HOME/codex"
cat > "$HOME/stubs/swap-guard" <<'EOF'
#!/bin/bash
printf '{"route":"codex","eligible":true,"codex":{"home":"%s"}}\n' "$TEST_CODEX_HOME"
EOF
cat > "$HOME/stubs/codex" <<'EOF'
#!/bin/bash
if [ "$3" = app-server ]; then exec python3 "$HOME/stubs/probe-fake.py"; fi
[ "$1 $2" = 'login status' ] && exit "${TEST_LOGIN_EXIT:-0}"
printf '%s\n' "$CODEX_HOME $*" >> "$HOME/calls"
cat > "$HOME/input"
printf '%s\n' '{"type":"thread.started","thread_id":"01234567-89ab-4cde-8fab-0123456789ab"}'
while [ "$#" -gt 0 ]; do if [ "$1" = -o ]; then printf done > "$2"; fi; shift; done
EOF
chmod +x "$HOME/stubs/"*
printf 'profile = "qa"\n' > "$HOME/codex/config.toml"
printf 'model = "configured-model"\n' > "$HOME/codex/qa.config.toml"
mkfifo "$HOME/codex/auth.json"
cd "$HOME/work" || exit 1
{ printf '<!-- handoff cwd="%s" created="%s" -->\n' "$(pwd -P)" "$(date +%s)"
  for h in 'Goal' 'Current state' 'Files touched' 'Work in flight' 'Next steps' 'Validation' 'Codex execution plan'; do printf '## %s\nDetails.\n' "$h"; done
} > "$HOME/package.md"
CODEX_API_KEY=synthetic "$RUN" --package "$HOME/package.md" > "$HOME/result" 2> "$HOME/result.err" & pid=$!
(sleep 6; kill -KILL "$pid" 2>/dev/null) & watchdog=$!
wait "$pid"; code=$?
kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
assert_eq "$code" 0 'configured home continues without reading credentials'
source_run="$(jq -r .output_dir "$HOME/result")"
assert_eq "$(jq -r .identity_pin "$source_run/manifest.json")" null 'unverified identity is not pinned'
assert_contains "$(jq -r .resume_unavailable_reason "$source_run/manifest.json")" 'not verified' 'resume limitation recorded'
assert_absent "$(cat "$HOME/calls")" 'cli_auth_credentials_store' 'ordinary launch retains existing auth settings'
"$RUN" resume --run "$source_run" --dry-run >/dev/null 2> "$HOME/resume.err" && fail 'unverified resume rejected' || pass
assert_contains "$(cat "$HOME/resume.err")" 'unavailable' 'resume refusal explains unavailable verification'
# Supported v2 probe fixture: use synthetic JWT claims and safe policy only.
rm "$HOME/codex/auth.json"
python3 - "$HOME/codex/auth.json" <<'PY'
import base64,json,sys
b=base64.urlsafe_b64encode(json.dumps({'sub':'synthetic-subject'}).encode()).decode().rstrip('=')
with open(sys.argv[1],'w') as f: json.dump({'tokens':{'account_id':'synthetic-account','id_token':'e30.'+b+'.c2ln'}},f)
PY
cat > "$HOME/stubs/probe-fake.py" <<'PY'
import json,os,sys
if os.environ.get('TEST_UNSUPPORTED'): sys.exit(1)
for line in sys.stdin:
    msg=json.loads(line); method=msg.get('method')
    if method == 'initialized': continue
    if method == 'initialize': result={'codexHome':os.environ['CODEX_HOME'],'userAgent':'probe/0.166.0'}
    elif method == 'config/read':
        result={'config':{'model_provider':None,'model_providers':{},'cli_auth_credentials_store':'file',
                'sandbox_mode':'workspace-write','approval_policy':'on-request',
                'sandbox_workspace_write':{'network_access':False},
                'chatgpt_base_url':'https://chatgpt.com/backend-api/'},'origins':{},'layers':[]}
    elif method == 'configRequirements/read': result={'requirements':{'fixture':os.environ.get('TEST_FINGERPRINT','1')}}
    else: sys.exit(2)
    print(json.dumps({'id':msg['id'],'result':result}), flush=True)
PY
ln -s "$REPO/bin/overclaude-codex-probe" "$HOME/stubs/overclaude-codex-probe"
out="$(CODEX_TOOL_CALL_ID=initial-call $RUN --package "$HOME/package.md" 2>/dev/null)"
source_run="$(printf '%s' "$out" | jq -r .output_dir)"
assert_eq "$(jq -r .policy_version "$source_run/manifest.json")" 2 'verified policy pinned'
assert_eq "$(jq -r '.identity_pin | length' "$source_run/manifest.json")" 64 'synthetic identity pinned'
CODEX_TOOL_CALL_ID=different-call "$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1 && pass || fail 'verified resume across tool invocations'
result="$($RUN resume --run "$source_run" 2>/dev/null)"
assert_eq "$?" 0 'verified resume executes'
assert_contains "$(tail -1 "$HOME/calls")" 'resume 01234567-89ab-4cde-8fab-0123456789ab -' 'exact thread resumed'
assert_contains "$(cat "$HOME/input")" 'never blindly replay' 'resume reconciliation prompt'
assert_absent "$(tail -1 "$HOME/calls")" 'approval_policy' 'resume preserves existing policy'
TEST_FINGERPRINT=2 "$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1 && fail 'changed effective config rejected' || pass
OPENAI_BASE_URL=https://different.invalid "$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1 && fail 'provider override rejected' || pass
TEST_UNSUPPORTED=1 "$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1 && fail 'unsupported policy rejected' || pass
CODEX_API_KEY=synthetic "$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1 && fail 'alternate credentials rejected for resume' || pass
TEST_LOGIN_EXIT=1 "$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1 && fail 'failed login rejected' || pass
(cd "$HOME" && "$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1) && fail 'wrong cwd rejected' || pass
cp "$HOME/codex/auth.json" "$HOME/auth.backup"
printf '{"tokens":{"account_id":"other","id_token":"e30.eyJzdWIiOiJkaWZmZXJlbnQifQ.c2ln"}}' > "$HOME/codex/auth.json"
"$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1 && fail 'changed identity rejected' || pass
mv "$HOME/auth.backup" "$HOME/codex/auth.json"
CODEX_API_KEY=synthetic "$RUN" --package "$HOME/package.md" > "$HOME/key-result" 2>/dev/null
key_run="$(jq -r .output_dir "$HOME/key-result")"
assert_eq "$(jq -r .policy_version "$key_run/manifest.json")" null 'API credential environment is not resumable'
cp "$source_run/manifest.json" "$HOME/original-manifest"
python3 - "$source_run/manifest.json" <<'PY'
import json,sys
p=sys.argv[1]
with open(p) as f: data=json.load(f)
data['policy_version']=1
with open(p,'w') as f: json.dump(data,f)
PY
"$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1 && fail 'legacy manifest rejected' || pass
python3 - "$source_run/manifest.json" "$HOME/original-manifest" <<'PY'
import json,sys
with open(sys.argv[2]) as f: data=json.load(f)
data['thread_id']='invalid'
with open(sys.argv[1],'w') as f: json.dump(data,f)
PY
"$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1 && fail 'invalid UUID rejected' || pass
cp "$HOME/original-manifest" "$source_run/manifest.json"
sleep 30 & live_child=$!
python3 - "$source_run/manifest.json" "$live_child" <<'PY'
import json,sys
p=sys.argv[1]
with open(p) as f: data=json.load(f)
data.update(state='interrupted',runner_pid=99999999,child_pid=int(sys.argv[2]),child_process_start=None)
with open(p,'w') as f: json.dump(data,f)
PY
"$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1 && fail 'live child rejected even after interruption' || pass
kill "$live_child" 2>/dev/null; wait "$live_child" 2>/dev/null
cp "$HOME/original-manifest" "$source_run/manifest.json"
digest="$(printf '%s' "$(pwd -P)" | shasum -a 256 | cut -c1-12)"
lock="$HOME/.claude-swap-backup/continuations/$digest.lock"
mv "$lock" "$lock.saved"
ln -s "$HOME/package.md" "$lock"
"$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1 && fail 'symlink lock rejected' || pass
rm "$lock"
mv "$lock.saved" "$lock"
cp "$HOME/codex/auth.json" "$HOME/valid-auth"
printf '[]' > "$HOME/codex/auth.json"
out="$($RUN --package "$HOME/package.md" 2>/dev/null)"; code=$?
assert_eq "$code" 0 'malformed auth object does not prevent continuation'
malformed_run="$(printf '%s' "$out" | jq -r .output_dir)"
assert_eq "$(jq -r .policy_version "$malformed_run/manifest.json")" null 'malformed auth leaves no pins'
mv "$HOME/valid-auth" "$HOME/codex/auth.json"
mv "$HOME/stubs/overclaude-codex-probe" "$HOME/stubs/real-probe"
cat > "$HOME/stubs/overclaude-codex-probe" <<'EOF'
#!/bin/bash
printf '[]\n'
EOF
chmod +x "$HOME/stubs/overclaude-codex-probe"
out="$($RUN --package "$HOME/package.md" 2>/dev/null)"; code=$?
assert_eq "$code" 0 'malformed probe object does not prevent continuation'
malformed_run="$(printf '%s' "$out" | jq -r .output_dir)"
assert_eq "$(jq -r .policy_version "$malformed_run/manifest.json")" null 'malformed probe leaves no pins'
"$RUN" resume --run "$source_run" --dry-run >/dev/null 2>&1 && fail 'malformed probe refuses resume' || pass
finish
