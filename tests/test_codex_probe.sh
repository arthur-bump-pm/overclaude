#!/bin/bash
. "$(dirname "$0")/lib.sh"
new_home
mkdir -p "$HOME/bin" "$HOME/codex" "$HOME/project"
cat > "$HOME/bin/codex" <<'PY'
#!/usr/bin/env python3
import json, os, subprocess, sys, time
home = os.environ['CODEX_HOME']; mode = os.environ.get('PROBE_MODE', '')
with open(os.path.join(os.environ['HOME'], 'args'), 'w') as f: json.dump([sys.argv[1:], home], f)
if mode == 'hang': time.sleep(30); sys.exit()
if mode == 'oversize': sys.stdout.write('x' * (2 * 1024 * 1024 + 1)); sys.stdout.flush(); time.sleep(30); sys.exit()
if mode == 'child':
    child = subprocess.Popen(['python3', '-c', 'import time; time.sleep(30)'])
    open(os.path.join(os.environ['HOME'], 'child'), 'w').write(str(child.pid))
for line in sys.stdin:
    msg = json.loads(line); method = msg.get('method')
    if method == 'initialized': continue
    if mode == 'bad': print('not json', flush=True); continue
    if method == 'initialize': result = {'codexHome': '/wrong' if mode == 'wrong' else home, 'userAgent': None if mode == 'noagent' else ('probe/0.145.0' if mode in ('old', 'oldambiguous', 'oldmanaged', 'oldrequirement', 'oldorigin') else ('probe/0.167.0' if mode == 'agentchange' else 'probe/0.166.0'))}
    elif method == 'config/read':
        result = {'config': {'model_provider': 'other' if mode == 'provider' else None,
            'model_providers': {}, 'cli_auth_credentials_store': 'auto' if mode == 'auth' else (None if mode in ('old','oldambiguous','oldmanaged','oldrequirement','oldorigin') else 'file'), 'sandbox_mode': 'workspace-write',
            'approval_policy': 'on-request', 'sandbox_workspace_write': {'network_access': False},
            'chatgpt_base_url': 'https://chatgpt.com/backend-api/', 'instructions': 'SECRET_PROBE_VALUE'},
            'origins': ({'cli_auth_credentials_store': {'name':'managed'}} if mode == 'oldorigin' else {}), 'layers': [{'name':{'type':'mdm' if mode == 'oldmanaged' else 'user'}, 'config':{'secret':'SECRET_PROBE_VALUE', **({'cli_auth_credentials_store':'auto'} if mode == 'oldambiguous' else {})}}]}
        if mode.startswith('role'):
            path = os.path.realpath(os.path.join(os.environ['HOME'], 'role.toml'))
            if mode == 'rolerelative': path = 'role.toml'
            if mode == 'rolesymlink': path = os.path.join(os.path.realpath(os.environ['HOME']), 'role-link.toml')
            name = {'type':'user', 'file':os.path.join(home, 'config.toml')}
            result['config']['agents'] = {'review':{'config_file':path}}
            result['origins']['agents.review.config_file'] = {'name':name}
            result['layers'].append({'name':name, 'config':{}})
    elif method == 'configRequirements/read': result = {'requirements': {'models': ['x' if mode != 'changed' else 'y'], **({'cliAuthCredentialsStore':'auto'} if mode == 'oldrequirement' else {})}}
    else: sys.exit(2)
    print(json.dumps({'id':msg['id'], 'result':result}), flush=True)
PY
chmod +x "$HOME/bin/codex"
export PATH="$HOME/bin:$PATH"
PROBE="$REPO/bin/overclaude-codex-probe"
python3 - "$PROBE" "$HOME" <<'PY'
import json, os, subprocess, sys
probe, home = sys.argv[1:]
cmd = [probe, '--home', home + '/codex', '--cwd', home + '/project', 'policy']
def run(mode='', **env):
    e = dict(os.environ, PROBE_MODE=mode, **env)
    return subprocess.run(cmd, env=e, capture_output=True, text=True, timeout=12)
a = run(); assert a.returncode == 0, a.stderr
out = json.loads(a.stdout); assert out['policyVersion'] == 2 and out['home'] == os.path.realpath(home+'/codex')
assert out['approval'] == 'on-request' and out['networkAccess'] is False
assert 'SECRET_PROBE_VALUE' not in a.stdout + a.stderr
args, actual_home = json.load(open(home + '/args'))
assert args == ['-c', 'sandbox_mode="workspace-write"', 'app-server'] and actual_home == os.path.realpath(home+'/codex')
assert json.loads(run().stdout)['fingerprint'] == out['fingerprint']
assert json.loads(run('changed').stdout)['fingerprint'] != out['fingerprint']
assert json.loads(run('agentchange').stdout)['fingerprint'] != out['fingerprint']
old = run('old'); assert old.returncode == 0 and json.loads(old.stdout)['authStore'] == 'file'
assert json.loads(old.stdout)['fingerprint'] != out['fingerprint']
for mode in ('wrong','bad','provider','auth','oldambiguous','oldmanaged','oldrequirement','oldorigin','noagent','hang','oversize'):
    r = run(mode); assert r.returncode != 0 and not r.stdout and 'SECRET_PROBE_VALUE' not in r.stderr, (mode, r.stdout, r.stderr)
r = run(OPENAI_API_KEY='not-a-real-secret'); assert r.returncode != 0 and 'not-a-real-secret' not in r.stderr
role = home + '/role.toml'
open(role, 'w').write('model = "one"\n')
role_a = run('role'); assert role_a.returncode == 0, role_a.stderr
open(role, 'w').write('model = "two"\n')
assert json.loads(run('role').stdout)['fingerprint'] != json.loads(role_a.stdout)['fingerprint']
os.symlink(role, home + '/role-link.toml')
for mode in ('rolerelative', 'rolesymlink'):
    assert run(mode).returncode != 0, mode
open(role, 'w').write('model_instructions_file = "nested.md"\n')
assert run('role').returncode != 0
open(role, 'w').write('"\\u0063onfig_file" = "nested.toml"\n')
assert run('role').returncode != 0
open(role, 'w').write('developer_instructions = "mention profile and config_file in prose"\n')
assert run('role').returncode == 0
os.unlink(role)
assert run('role').returncode != 0
r = run('child'); assert r.returncode == 0
pid = int(open(home+'/child').read())
try: os.kill(pid, 0)
except ProcessLookupError: pass
else:
    # A killed orphan can remain temporarily as a zombie awaiting reaping.
    state = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
    assert not state or state.startswith('Z'), state
print('test_codex_probe.sh: protocol, isolation, bounds, and policy checks passed')
PY
rc=$?
rm -rf "$HOME"
exit "$rc"
