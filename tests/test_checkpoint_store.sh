#!/bin/bash
. "$(dirname "$0")/lib.sh"
new_home
python3 - "$REPO/bin/overclaude-checkpoint" "$HOME" <<'PY'
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import stat
import subprocess
import sys
from unittest import mock

script, home = sys.argv[1:]
work = pathlib.Path(home, 'project'); work.mkdir()
other = pathlib.Path(home, 'other'); other.mkdir()
cmd = [script]
sections = {'Goal':'Complete task', 'Current state':'Work in progress', 'Decisions':'None',
            'Validation':'Tests pass', 'Next steps':'Review', 'Work in flight':'None',
            'Artifacts':'missing: /example/not-created'}
def call(args, data=None):
    return subprocess.run(cmd + args, cwd=str(work), input=data, capture_output=True, text=True, timeout=5)
def save(data=sections, session='session-1'):
    return call(['save','--session',session], json.dumps(data))
a = save(); assert a.returncode == 0, a.stderr
first = json.loads(a.stdout); b = save(session='session-2'); assert b.returncode == 0
second = json.loads(b.stdout); assert first['id'] != second['id']
listing = json.loads(call(['list']).stdout); assert {r['id'] for r in listing} == {first['id'], second['id']}
assert {r['session'] for r in listing} == {'session-1', 'session-2'}
assert all(r['session_known'] for r in listing)
unknown = json.loads(save(session='unknown').stdout); assert unknown['session_known'] is False
shown = call(['show', first['id']]); assert shown.returncode == 0 and 'missing: /example/not-created' in shown.stdout
assert all('## ' + k in shown.stdout for k in sections)
assert not os.path.exists('/example/not-created')
assert json.loads(call(['list','--cwd',str(other)]).stdout) == []
assert call(['show', first['id'], '--cwd',str(other)]).returncode != 0
assert call(['show', '../' + first['id']]).returncode != 0
bad = dict(sections); del bad['Goal']; assert save(bad).returncode != 0
bad = dict(sections, Goal='  '); assert save(bad).returncode != 0
bad = dict(sections, **{'Next steps':'None'}); assert save(bad).returncode != 0
for key in ('Goal', 'Current state', 'Next steps'):
    for placeholder in ('TODO', 'TBD', 'N/A', 'None', '... ---', '<!-- pending -->'):
        bad = dict(sections); bad[key] = placeholder
        assert save(bad).returncode != 0, (key, placeholder)
bad = dict(sections, Artifacts='x' * 33000); assert save(bad).returncode != 0
assert save(session='../escape').returncode != 0
scope = pathlib.Path(home,'.claude-swap-backup','checkpoints', __import__('hashlib').sha256(os.path.realpath(work).encode()).hexdigest())
assert stat.S_IMODE(scope.stat().st_mode) == 0o700
assert stat.S_IMODE(scope.parent.stat().st_mode) == 0o700
snapshot = scope / (first['id'] + '.md')
assert stat.S_IMODE(snapshot.stat().st_mode) == 0o400
before = snapshot.read_bytes()
loader = importlib.machinery.SourceFileLoader('checkpoint_test', script)
spec = importlib.util.spec_from_loader(loader.name, loader); mod = importlib.util.module_from_spec(spec); loader.exec_module(mod)
with mock.patch.object(mod.os, 'link', side_effect=OSError('simulated publish failure')):
    try: mod.save(str(work), 'session-3', io.BytesIO(json.dumps(sections).encode()))
    except OSError: pass
    else: raise AssertionError('failure not propagated')
assert snapshot.read_bytes() == before and len(json.loads(call(['list']).stdout)) == 3
fake = '20260101T000000Z-' + 'a' * 32
(scope / (fake + '.md')).write_text('# Checkpoint\n\n<!-- overclaude-checkpoint ' + '[' * 1500 + '0' + ']' * 1500 + ' -->\n')
assert len(json.loads(call(['list']).stdout)) == 3, 'corrupt deeply nested entry must not hide good checkpoints'
(scope / (fake + '.md')).unlink()
os.mkfifo(scope / (fake + '.md'))
assert call(['show',fake]).returncode != 0
assert len(json.loads(call(['list']).stdout)) == 3
(scope / (fake + '.md')).unlink(); (scope / (fake + '.md')).symlink_to(snapshot)
assert call(['show',fake]).returncode != 0
(scope / (fake + '.md')).unlink()
# A symlink at a scoped directory is never followed.
other_hash = __import__('hashlib').sha256(os.path.realpath(other).encode()).hexdigest()
(scope.parent / other_hash).symlink_to(scope, target_is_directory=True)
assert call(['save','--session','s','--cwd',str(other)], json.dumps(sections)).returncode != 0
assert call(['list','--cwd',str(other)]).returncode != 0
assert snapshot.read_bytes() == before
print('test_checkpoint_store.sh: immutable scoped storage, validation, and failure checks passed')
PY
rc=$?
[ "$rc" -eq 0 ] || { rm -rf "$HOME"; exit "$rc"; }
mkdir -p "$HOME/stubbin"
version="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$REPO/vendor/claude-swap/pyproject.toml" | head -1)"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "claude-swap %s"\nexit 0\n' "$version" > "$HOME/stubbin/cswap"
chmod +x "$HOME/stubbin/cswap"
export PATH="$HOME/stubbin:$HOME/.local/bin:$PATH" SWAP_GUARD_NO_LAUNCHCTL=1
OVERCLAUDE_VERSION=1.2.3 bash "$REPO/install.sh" > "$HOME/install.log" 2>&1 || { cat "$HOME/install.log"; exit 1; }
[ -x "$HOME/.local/bin/overclaude-checkpoint" ] && [ -f "$HOME/.claude/skills/checkpoint/SKILL.md" ] || exit 1
PYTHONPATH="$REPO/src" python3 - "$REPO" <<'VERIFY'
import os, sys
from overclaude.verify import verify
errors, _ = verify(sys.argv[1], os.environ['HOME'], '1.2.3')
assert not errors, errors
VERIFY
[ "$?" -eq 0 ] || exit 1
bash "$REPO/uninstall.sh" > "$HOME/uninstall.log" 2>&1 || { cat "$HOME/uninstall.log"; exit 1; }
[ ! -e "$HOME/.local/bin/overclaude-checkpoint" ] && [ ! -e "$HOME/.claude/skills/checkpoint/SKILL.md" ] || exit 1
jq -e '(.permissions.allow // []) | index("Bash(overclaude-checkpoint *)") | not' "$HOME/.claude/settings.json" >/dev/null || exit 1
[ -d "$HOME/.claude-swap-backup/checkpoints" ] || exit 1
printf '%s\n' 'test_checkpoint_store.sh: install, verify, uninstall and preservation passed'
rm -rf "$HOME"
exit "$rc"
