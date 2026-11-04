#!/bin/bash
. "$(dirname "$0")/lib.sh"
new_home
POOL="$REPO/bin/overclaude-codex-pool"
mkdir -p "$HOME/stubs" "$HOME/.codex" "$HOME/.codex-accounts/work" "$HOME/project"
export PATH="$HOME/stubs:$PATH"
cat > "$HOME/stubs/codex" <<'PY'
#!/usr/bin/env python3
import json, os, subprocess, sys, time
home=os.environ['CODEX_HOME']
try:
 with open(os.path.join(home,'fixture.json')) as f: fixture=json.load(f)
except OSError: fixture={}
if fixture.get('hang'):
 child=subprocess.Popen(['sleep','30'])
 with open(os.path.join(os.environ['HOME'],'pool-child'),'w') as f: f.write(str(child.pid))
 time.sleep(30); sys.exit()
if fixture.get('malformed'): print('{bad',flush=True); time.sleep(30); sys.exit()
for line in sys.stdin:
 msg=json.loads(line); method=msg.get('method')
 with open(os.path.join(os.environ['HOME'],'methods'),'a') as f: f.write(str(method)+'\n')
 if method=='initialized': continue
 if method=='account/rateLimits/read' and fixture.get('authError'):
  print(json.dumps({'id':msg['id'],'error':{'code':-32603,'message':'401 expired auth token SECRET_FAKE_TOKEN https://secret.invalid'}}),flush=True); continue
 if method=='account/rateLimits/read' and fixture.get('genericError'):
  print(json.dumps({'id':msg['id'],'error':{'code':-32603,'message':'SECRET_FAKE_TOKEN'}}),flush=True); continue
 if method=='initialize': result={'codexHome':home}
 elif method=='account/read':
  assert msg.get('params') == {'refreshToken':False}
  result={'account':{'type':fixture.get('type','chatgpt'),'email':'synthetic@example.invalid','planType':'pro'},'requiresOpenaiAuth':True}
  if fixture.get('mutateEarly'):
   with open(os.path.join(home,'auth.json'),'w') as f: json.dump({},f)
 elif method=='config/read': result={'config':{'cli_auth_credentials_store':None if fixture.get('old') else 'file','model_provider':None,'model_providers':fixture.get('providers',{}),'chatgpt_base_url':fixture.get('url')},'origins':{},'layers':[]}
 elif method=='configRequirements/read': result={'requirements':fixture.get('requirements')}
 elif method=='account/rateLimits/read':
  now=int(time.time()); window={'usedPercent':fixture.get('pct',10),'resetsAt':now+fixture.get('reset',3600),'windowDurationMins':fixture.get('duration',300)}
  if fixture.get('nanReset'): window['resetsAt']=float('nan')
  if fixture.get('infiniteDuration'): window.update(resetsAt=now+999999999,windowDurationMins=float('inf'))
  result={'rateLimits':{'limitId':fixture.get('limitId','codex'),'primary':window,'secondary':None}}
  if fixture.get('mutate'):
   with open(os.path.join(home,'auth.json'),'w') as f: json.dump({},f)
  if fixture.get('missingQuota'): result={'rateLimits':{}}
  if fixture.get('unknownPermission'): result['ordinaryUsageAllowed']=None
  if fixture.get('new'): result.update(accountId=fixture.get('accountId'),rateLimitsByLimitId={'codex':result['rateLimits']})
  if fixture.get('contradiction'):
   result['rateLimitsByLimitId']={'codex':{'limitId':'codex','primary':dict(window,usedPercent=10),'secondary':None}}
   result['rateLimits']['primary']=dict(window,usedPercent=100)
  if fixture.get('wrongEmbedded'):
   result['rateLimitsByLimitId']={'codex':{'limitId':'wrong','primary':window,'secondary':None}}
  if fixture.get('legacyOther'):
   result['rateLimits']['limitId']='unrelated'
   result['rateLimitsByLimitId']={'codex':{'limitId':'codex','primary':window,'secondary':None}}
  if 'spend' in fixture: result['rateLimits']['spendControlReached']=fixture['spend']
  if 'reached' in fixture: result['rateLimits']['rateLimitReachedType']=fixture['reached']
 elif method=='model/list': result={'data':fixture.get('models',[]),'nextCursor':'x'*100000 if fixture.get('hugeCursor') else None}
 else: sys.exit(2)
 print(json.dumps({'id':msg['id'],'result':result}),flush=True)
PY
chmod +x "$HOME/stubs/codex"
python3 - "$HOME" <<'PY'
import base64,json,os,sys
home=sys.argv[1]
for name,account in [('.codex','acct-a'),('.codex-accounts/work','acct-b')]:
 d=os.path.join(home,name); payload=base64.urlsafe_b64encode(json.dumps({'sub':'subject-'+account}).encode()).decode().rstrip('=')
 with open(os.path.join(d,'auth.json'),'w') as f: json.dump({'tokens':{'account_id':account,'id_token':'e30.'+payload+'.c2ln'}},f)
PY
printf '{"pct":100}' > "$HOME/.codex/fixture.json"
printf '{"new":true,"accountId":"acct-b"}' > "$HOME/.codex-accounts/work/fixture.json"
printf primary > "$HOME/.codex-accounts/.active"
cd "$HOME/project" || exit 1
out="$($POOL)"
assert_eq "$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="primary") | .status')" exhausted 'active exhausted'
assert_eq "$(printf '%s' "$out" | jq -r .selected)" "$(cd "$HOME/.codex-accounts/work" && pwd -P)" 'selects usable alternate'
assert_eq "$(cat "$HOME/.codex-accounts/.active")" primary 'active marker unchanged'
assert_absent "$out" 'synthetic@example.invalid' 'email omitted'
assert_absent "$out" 'acct-b' 'account identity omitted'
assert_eq "$(printf '%s' "$out" | jq -r .model_eligibility)" unchecked 'model eligibility disclosed as unchecked'
assert_absent "$(cat "$HOME/methods")" 'thread/' 'no thread operations'
printf '{"pct":10}' > "$HOME/.codex/fixture.json"
out="$($POOL)"
assert_eq "$(printf '%s' "$out" | jq -r .selected)" "$(cd "$HOME/.codex" && pwd -P)" 'eligible active preferred'
cp "$HOME/.codex/auth.json" "$HOME/.codex-accounts/work/auth.json"
printf '{"pct":10}' > "$HOME/.codex-accounts/work/fixture.json"
printf work > "$HOME/.codex-accounts/.active"
out="$($POOL)"
assert_eq "$(printf '%s' "$out" | jq -r .selected)" "$(cd "$HOME/.codex-accounts/work" && pwd -P)" 'duplicate prefers active'
assert_eq "$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="primary") | .status')" duplicate 'duplicate marked'
python3 - "$HOME/.codex-accounts/work/auth.json" <<'PY'
import base64,json,sys
b=base64.urlsafe_b64encode(b'{"sub":"subject-b"}').decode().rstrip('=')
with open(sys.argv[1],'w') as f: json.dump({'tokens':{'account_id':'acct-b','id_token':'e30.'+b+'.c2ln'}},f)
PY
for spec in '{"spend":"yes"}' '{"reached":false}' '{"reached":"unknown"}' '{"nanReset":true}' '{"infiniteDuration":true}' '{"contradiction":true}' '{"wrongEmbedded":true}' '{"unknownPermission":true}' '{"missingQuota":true}' '{"limitId":"other"}' '{"new":true,"accountId":"wrong"}' '{"requirements":{"cli_auth_credentials_store":"keyring"}}' '{"url":"https://evil.invalid"}' '{"providers":[]}' '{"pct":101}' '{"pct":-1}' '{"reset":-1}' '{"reset":99999999}' '{"duration":0}' '{"type":"apiKey"}' '{"malformed":true}'; do
  printf '%s' "$spec" > "$HOME/.codex-accounts/work/fixture.json"
  out="$($POOL)"
  assert_eq "$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="work") | .status')" unknown "invalid input rejected: $spec"
done
printf '{"legacyOther":true}' > "$HOME/.codex-accounts/work/fixture.json"
out="$($POOL)"
assert_eq "$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="work") | .status')" eligible 'unrelated legacy bucket ignored'
printf '{"authError":true}' > "$HOME/.codex-accounts/work/fixture.json"
out="$($POOL)"
reason="$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="work") | .reason')"
assert_contains "$reason" 'account/rateLimits/read' 'authentication error identifies operation'
assert_contains "$reason" 'sign in again' 'expired authentication is actionable'
assert_absent "$out" 'SECRET_FAKE_TOKEN' 'authentication error does not expose server text'
assert_absent "$out" 'secret.invalid' 'authentication error does not expose server URLs'
printf '{"genericError":true}' > "$HOME/.codex-accounts/work/fixture.json"
out="$($POOL)"
reason="$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="work") | .reason')"
assert_contains "$reason" 'account/rateLimits/read' 'generic error identifies operation'
assert_absent "$out" 'SECRET_FAKE_TOKEN' 'generic error does not expose server text'
printf '{"old":true}' > "$HOME/.codex-accounts/work/fixture.json"
out="$($POOL)"
assert_eq "$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="work") | .status')" eligible 'old null auth default safely resolved'
cp "$HOME/.codex-accounts/work/auth.json" "$HOME/auth.backup"
printf '{"mutateEarly":true}' > "$HOME/.codex-accounts/work/fixture.json"
out="$($POOL)"
assert_eq "$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="work") | .status')" unknown 'identity change before account response rejected'
mv "$HOME/auth.backup" "$HOME/.codex-accounts/work/auth.json"
printf '{"pct":100}' > "$HOME/.codex/fixture.json"
printf '{"pct":100}' > "$HOME/.codex-accounts/work/fixture.json"
out="$($POOL)"
assert_eq "$(printf '%s' "$out" | jq -r .selected)" null 'no available account'
printf '{"models":[{"model":"test-model","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"high"},{"reasoningEffort":"high"}]}]}' > "$HOME/.codex-accounts/work/fixture.json"
out="$($POOL --model test-model)"
assert_eq "$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="work") | .supported_efforts[0]')" high 'native model effort confirmed'
assert_eq "$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="work") | .supported_efforts | length')" 1 'reasoning effort output deduplicated'
out="$($POOL --model missing-model)"
assert_eq "$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="work") | .status')" unknown 'missing model unavailable'
printf '{"hugeCursor":true}' > "$HOME/.codex-accounts/work/fixture.json"
out="$($POOL --model test-model)"
assert_contains "$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="work") | .reason')" 'cursor invalid' 'oversized cursor safely rejected'
printf '{"hang":true}' > "$HOME/.codex-accounts/work/fixture.json"
out="$($POOL)"
assert_contains "$(printf '%s' "$out" | jq -r '.candidates[] | select(.name=="work") | .reason')" 'timed out' 'timeout surfaced'
child_pid="$(cat "$HOME/pool-child")"
kill -0 "$child_pid" 2>/dev/null && fail 'timed-out process group cleaned' || pass
# A truncated inventory is reported before any account is contacted.
for n in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32; do mkdir "$HOME/.codex-accounts/extra$n"; done
before="$(wc -l < "$HOME/methods")"
out="$($POOL)"
after="$(wc -l < "$HOME/methods")"
assert_eq "$(printf '%s' "$out" | jq -r .selected)" null 'truncated inventory selects no account'
assert_eq "$(printf '%s' "$out" | jq -r .inventory_complete)" false 'incomplete inventory explicitly reported'
assert_contains "$(printf '%s' "$out" | jq -r .reason)" 'inventory' 'inventory limit explained'
assert_eq "$before" "$after" 'incomplete inventory does not probe accounts'
finish
