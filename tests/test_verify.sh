#!/bin/bash
. "$(dirname "$0")/lib.sh"
new_home
export PYTHONPATH="$REPO/src"
mkdir -p "$HOME/testbin"
version="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$REPO/vendor/claude-swap/pyproject.toml" | head -1)"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "claude-swap %s"\nexit 0\n' "$version" > "$HOME/testbin/cswap"
chmod +x "$HOME/testbin/cswap"
export PATH="$HOME/testbin:$HOME/.local/bin:$PATH" SWAP_GUARD_NO_LAUNCHCTL=1
OVERCLAUDE_VERSION=1.2.3 bash "$REPO/install.sh" > "$HOME/install.log" 2>&1 || { cat "$HOME/install.log"; exit 1; }
python3 - "$REPO" <<'PYINSTALL'
import os, sys
from overclaude.verify import verify
errors, notes = verify(sys.argv[1], os.environ["HOME"], "1.2.3")
assert not errors, errors
print("test_verify.sh: actual installer output verifies")
PYINSTALL
[ "$?" -eq 0 ] || exit 1
python3 - "$REPO" <<'PY'
import json
import io
import contextlib
import os
import shutil
import stat
import sys
from pathlib import Path
from unittest import mock

from overclaude import cli
from overclaude.verify import FILES, verify

payload, home = Path(sys.argv[1]), Path(os.environ['HOME'])
for src, dst, mode in FILES:
    path = home / dst
    path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(payload / src, path)
    if mode is not None:
        path.chmod(mode)
(home / '.claude/CLAUDE.md').write_text(chr(10).join(['user text', '@ULTRACODE.md', '']))
(home / '.claude-swap-backup/kit-version').write_text('1.2.3\n')
settings = json.loads((payload / 'settings/settings-fragment.json').read_text())
settings['model'] = 'user choice'
settings['statusLine'] = {'type':'command', 'command':'custom'}
settings['hooks']['Stop'].append({'hooks':[{'type':'command', 'command':'custom'}]})
settings_path = home / '.claude/settings.json'
def save(): settings_path.write_text(json.dumps(settings))
save()
with mock.patch('socket.socket', side_effect=AssertionError('network')), \
     mock.patch('subprocess.call', side_effect=AssertionError('service call')):
    errors, notes = verify(payload, home, '1.2.3')
    assert not errors, errors
    assert notes and 'custom statusLine' in notes[0]
    target = home / FILES[0][1]
    target.write_text('tampered')
    assert any('content differs' in x for x in verify(payload, home, '1.2.3')[0])
    shutil.copyfile(payload / FILES[0][0], target); target.chmod(0o700)
    assert any('incorrect mode' in x for x in verify(payload, home, '1.2.3')[0])
    target.chmod(0o755); target.unlink()
    assert any('missing required' in x for x in verify(payload, home, '1.2.3')[0])
    target.symlink_to(home / '.claude/credentials.json')
    assert any('missing required' in x for x in verify(payload, home, '1.2.3')[0])
    target.unlink(); shutil.copyfile(payload / FILES[0][0], target); target.chmod(0o755)
    settings['hooks']['StopFailure'][0]['matcher'] = 'wrong'; save()
    assert any('StopFailure hook' in x for x in verify(payload, home, '1.2.3')[0])
    settings['hooks']['StopFailure'][0]['matcher'] = 'rate_limit'; save()
    checkpoint = settings['hooks']['PostToolUse'][1]['hooks'][0]
    checkpoint['async'] = True; save()
    assert any('checkpoint' in x for x in verify(payload, home, '1.2.3')[0])
    del checkpoint['async']
    checkpoint['disabled'] = True; save()
    assert any('checkpoint' in x for x in verify(payload, home, '1.2.3')[0])
    del checkpoint['disabled']
    settings['disableAllHooks'] = True; save()
    assert any('all hooks are disabled' in x for x in verify(payload, home, '1.2.3')[0])
    del settings['disableAllHooks']
    for bad_status in (None, {}, {'type':'command', 'command':''}):
        settings['statusLine'] = bad_status; save()
        assert any('statusLine is missing or invalid' in x for x in verify(payload, home, '1.2.3')[0])
    settings['statusLine'] = {'type':'command', 'command':'custom'}; save()
    assert any('version' in x for x in verify(payload, home, 'bad-version')[0])
    assert not verify(payload, home, '1.2.3')[0]
    zshrc = home / '.zshrc'; original = zshrc.read_text()
    zshrc.write_text(original.replace('# --- claude-swap integration (end) ---', ''))
    assert any('shell integration markers' in x for x in verify(payload, home, '1.2.3')[0])
    zshrc.write_text(original.replace("alias swap=", "alias myswap="))
    assert any('shell integration differs' in x for x in verify(payload, home, '1.2.3')[1])
    zshrc.write_text(original)
    settings_path.unlink(); os.mkfifo(settings_path)
    assert any('settings' in x for x in verify(payload, home, '1.2.3')[0])
    settings_path.unlink(); save()
# Update must verify in the freshly upgraded interpreter and propagate failure.
with mock.patch.object(cli, 'pkg_version', return_value='1'), mock.patch.object(cli, '_latest_version', return_value='1'), \
     mock.patch.object(cli.subprocess, 'call', side_effect=[0, 7]) as call:
    assert cli._update(False) == 7
    assert [c.args[0][-1] for c in call.call_args_list] == ['install', 'verify']
with mock.patch.object(cli, 'pkg_version', return_value='1'), mock.patch.object(cli, '_latest_version', return_value='1'), \
     mock.patch.object(cli.subprocess, 'call', return_value=4) as call:
    assert cli._update(False) == 4 and call.call_count == 1
with mock.patch.object(sys, 'argv', ['overclaude', 'status', '--cwd', '/tmp/project', '--json']), \
     mock.patch('os.path.isfile', return_value=True), mock.patch('os.access', return_value=True), \
     mock.patch.object(cli.subprocess, 'call', return_value=0) as call:
    try:
        cli.main()
    except SystemExit as e:
        assert e.code == 0
    assert call.call_args.args[0][-4:] == ['status', '--cwd', '/tmp/project', '--json']
with mock.patch.object(sys, 'argv', ['overclaude', 'resume', '--run', '/tmp/a run', '--dry-run']), \
     mock.patch('os.path.isfile', return_value=True), mock.patch('os.access', return_value=True), \
     mock.patch.object(cli.subprocess, 'call', return_value=9) as call:
    try:
        cli.main()
    except SystemExit as e:
        assert e.code == 9
    assert call.call_args.args[0][-4:] == ['resume', '--run', '/tmp/a run', '--dry-run']
with mock.patch.object(sys, 'argv', ['overclaude', 'codex-pool', '--model', 'gpt-6.1-sol']), \
     mock.patch('os.path.isfile', return_value=True), mock.patch('os.access', return_value=True), \
     mock.patch.object(cli.subprocess, 'call', return_value=7) as call:
    try:
        cli.main()
    except SystemExit as e:
        assert e.code == 7
    assert call.call_args.args[0][-2:] == ['--model', 'gpt-6.1-sol']
    assert call.call_args.args[0][0].endswith('/overclaude-codex-pool')
with mock.patch.object(sys, 'argv', ['overclaude', 'recover', '--transaction', 'tx', '--keep-current']), \
     mock.patch.object(cli, '_payload_dir', return_value='/payload'), mock.patch.object(cli.subprocess, 'call', return_value=7) as call:
    try:
        cli.main()
    except SystemExit as e:
        assert e.code == 7
    assert call.call_args.args[0][-4:] == ['recover', '--transaction', 'tx', '--keep-current']
for argv in (['overclaude', 'recover', '--list', '--keep-current'], ['overclaude', 'codex-pool', '--switch'], ['overclaude', 'resume'], ['overclaude', 'resume', '--run', '/tmp/a', '--dry'],
             ['overclaude', 'resume', '--run', '/tmp/a', '--model', 'x']):
    with mock.patch.object(sys, 'argv', argv), mock.patch.object(cli.subprocess, 'call') as call, contextlib.redirect_stderr(io.StringIO()):
        try:
            cli.main()
            assert False, 'invalid arguments were accepted'
        except SystemExit as e:
            assert e.code == 2
        call.assert_not_called()
print('test_verify.sh: offline integrity, update, status, and resume checks passed')
PY
rc=$?
rm -rf "$HOME"
exit "$rc"
