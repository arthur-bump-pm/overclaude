#!/bin/bash
. "$(dirname "$0")/lib.sh"
new_home
python3 - "$REPO" "$HOME" <<'PY'
import contextlib, fcntl, importlib.machinery, importlib.util, io, json, os, pathlib, shutil, stat, subprocess, sys, tempfile
from unittest import mock
repo, root = map(pathlib.Path, sys.argv[1:]); script = repo / 'bin/overclaude-install-transaction'
loader = importlib.machinery.SourceFileLoader('txn', str(script)); spec=importlib.util.spec_from_loader(loader.name,loader); mod=importlib.util.module_from_spec(spec); loader.exec_module(mod)
verifier = mod.read_payload(repo); count = len(verifier.FILES) + len(mod.SHARED)

def newhome(label):
    home = root / label; home.mkdir(); (home/'.claude').mkdir(); (home/'.claude/settings.json').write_text('{"model":"mine"}\n'); return home

def invoke(home, args, patch=None):
    env = mock.patch.dict(os.environ, {'HOME':str(home)})
    argv = mock.patch.object(sys, 'argv', ['txn','--payload',str(repo)] + args)
    with env, argv, contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        if patch:
            with patch: return mod.main()
        return mod.main()

# Every managed write can fail; already-written entries must roll back.
for n in range(1, count + 1):
    home = newhome('failure-' + str(n)); original = (home/'.claude/settings.json').read_bytes()
    real = mod.apply_snapshot; counter = [0]; fired = [False]
    def fail_once(*args):
        if not fired[0]:
            counter[0] += 1
            if counter[0] == n:
                fired[0] = True
                raise OSError('injected')
        return real(*args)
    rc = invoke(home, ['apply','--version','test'], mock.patch.object(mod,'apply_snapshot',side_effect=fail_once))
    assert rc != 0 and fired[0], (n, rc)
    assert (home/'.claude/settings.json').read_bytes() == original
    assert not (home/'.local/bin/swap-guard').exists()
    journals = [p for p in (home/'.claude-swap-backup/install-transactions').iterdir() if p.is_dir()]
    assert len(journals)==1 and json.loads((journals[0]/'journal.json').read_text())['state']=='rolled_back'
print('every managed write rolls back on injected failure:', count)

home = newhome('normal'); target = home/'dotfiles'; target.mkdir();
real_settings = target/'settings.json'; real_settings.write_text('{"model":"mine"}\n'); real_settings.chmod(0o600)
(home/'.claude/settings.json').unlink(); (home/'.claude/settings.json').symlink_to(real_settings)
real_zsh = target/'zshrc'; real_zsh.write_text('export X=1\n'); real_zsh.chmod(0o600); (home/'.zshrc').symlink_to(real_zsh)
assert invoke(home,['apply','--version','test']) == 0
assert (home/'.claude/settings.json').is_symlink() and (home/'.zshrc').is_symlink()
assert stat.S_IMODE(real_settings.stat().st_mode)==0o600 and stat.S_IMODE(real_zsh.stat().st_mode)==0o600
assert json.loads(real_settings.read_text())['model']=='mine'
assert invoke(home,['apply','--version','test']) == 0

# An editor change found immediately before write survives rollback as conflict.
home = newhome('edit'); real=mod.apply_snapshot; fired=[False]
def edit_before(h, rel, desired, expected, allow_link):
    if rel=='.claude/settings.json' and not fired[0]:
        fired[0]=True; (h/rel).write_text('{"user":"concurrent"}\n')
    return real(h,rel,desired,expected,allow_link)
assert invoke(home,['apply','--version','test'],mock.patch.object(mod,'apply_snapshot',side_effect=edit_before)) != 0
assert json.loads((home/'.claude/settings.json').read_text()) == {'user':'concurrent'}
assert not (home/'.local/bin/swap-guard').exists()
journal = next(p for p in (home/'.claude-swap-backup/install-transactions').iterdir() if p.is_dir())
assert json.loads((journal/'journal.json').read_text())['state']=='conflict'
assert invoke(home,['apply','--version','test']) != 0
assert invoke(home,['recover','--transaction',journal.name]) != 0
assert json.loads((home/'.claude/settings.json').read_text()) == {'user':'concurrent'}
assert invoke(home,['recover','--transaction',journal.name,'--keep-current']) == 0
saved = json.loads((journal/'journal.json').read_text())
assert saved['state'] == 'recovered-with-edits'
assert any(item['rel']=='.claude/settings.json' and item['status']=='retained' and item['retainedEvidence'].get('sha256') for item in saved['entries'])
assert json.loads((home/'.claude/settings.json').read_text()) == {'user':'concurrent'}
assert invoke(home,['apply','--version','test']) == 0
assert json.loads((home/'.claude/settings.json').read_text())['user'] == 'concurrent'

# A verification error rolls back before services and preserves later user edits.
home = newhome('verify-fail'); patched = mod.read_payload(repo)
with mock.patch.object(patched, 'verify', return_value=(['injected'], [])):
    assert invoke(home,['apply','--version','test'],mock.patch.object(mod,'read_payload',return_value=patched)) != 0
assert not (home/'.local/bin/swap-guard').exists()
assert json.loads((home/'.claude/settings.json').read_text()) == {'model':'mine'}

home = newhome('new-edited'); patched = mod.read_payload(repo)
def edit_new(*_args):
    (home/'.local/bin/swap-guard').write_text('user-owned change')
    return ['injected'], []
with mock.patch.object(patched, 'verify', side_effect=edit_new):
    assert invoke(home,['apply','--version','test'],mock.patch.object(mod,'read_payload',return_value=patched)) != 0
assert (home/'.local/bin/swap-guard').read_text() == 'user-owned change'
journal = next(p for p in (home/'.claude-swap-backup/install-transactions').iterdir() if p.is_dir())
assert json.loads((journal/'journal.json').read_text())['state']=='conflict'

home = newhome('link-retarget'); target=home/'dot'; target.mkdir(); first=target/'first'; second=target/'second'
first.write_text('{"model":"mine"}'); second.write_text('{"user":"untouched"}')
link=home/'.claude/settings.json'; link.unlink(); link.symlink_to(first)
patched=mod.read_payload(repo)
def retarget(*_args):
    link.unlink(); link.symlink_to(second)
    return ['injected'], []
with mock.patch.object(patched,'verify',side_effect=retarget):
    assert invoke(home,['apply','--version','test'],mock.patch.object(mod,'read_payload',return_value=patched)) != 0
assert link.is_symlink() and os.readlink(link)==str(second) and json.loads(second.read_text())=={'user':'untouched'}
assert json.loads((next(p for p in (home/'.claude-swap-backup/install-transactions').iterdir() if p.is_dir())/'journal.json').read_text())['state']=='conflict'

# A failed transaction stops install.sh before either service helper is called.
home = newhome('service-gate'); stub=home/'stub'; stub.mkdir(); local=home/'.local/bin'; local.mkdir(parents=True)
version=next(line.split('"')[1] for line in (repo/'vendor/claude-swap/pyproject.toml').read_text().splitlines() if line.startswith('version = '))
(stub/'cswap').write_text('#!/bin/bash\n[ "$1" = --version ] && echo "claude-swap '+version+'"\nexit 0\n'); (stub/'cswap').chmod(0o755)
(stub/'python3').write_text('#!/bin/bash\nexit 41\n'); (stub/'python3').chmod(0o755)
(local/'swap-guard').write_text('#!/bin/bash\necho called >> "$HOME/service-called"\n'); (local/'swap-guard').chmod(0o755)
env=dict(os.environ, HOME=str(home), PATH=str(stub)+':'+str(local)+':'+os.environ['PATH'], OVERCLAUDE_VERSION='test')
run=subprocess.run(['/bin/bash',str(repo/'install.sh')], env=env, capture_output=True, text=True)
assert run.returncode != 0 and not (home/'service-called').exists()

# A commit marker that landed before an fsync error must never be rolled back.
home = newhome('commit-uncertain'); real_store=mod.store_manifest
def fail_after_commit(directory, journal):
    real_store(directory, journal)
    if journal['state'] == 'committed': raise OSError('directory fsync failed after rename')
assert invoke(home,['apply','--version','test'],mock.patch.object(mod,'store_manifest',side_effect=fail_after_commit)) != 0
journal = next(p for p in (home/'.claude-swap-backup/install-transactions').iterdir() if p.is_dir())
assert json.loads((journal/'journal.json').read_text())['state']=='committed'
assert (home/'.local/bin/swap-guard').exists()
assert invoke(home,['recover','--transaction',journal.name]) != 0

# A dangling intermediate symlink cannot create its missing external target.
home = newhome('dangling-ancestor'); outside = root/'missing-outside'
(home/'.local').symlink_to(outside, target_is_directory=True)
assert invoke(home,['apply','--version','test']) != 0
assert not outside.exists()

# A failed initial journal write leaves no published transaction to block retry.
home = newhome('initial-enospc'); real_store=mod.store_manifest; fired=[False]
def fail_initial(directory, journal):
    if directory.name.startswith('.staging-') and not fired[0]:
        fired[0]=True; raise OSError('simulated ENOSPC')
    return real_store(directory, journal)
assert invoke(home,['apply','--version','test'],mock.patch.object(mod,'store_manifest',side_effect=fail_initial)) != 0
assert invoke(home,['list']) == 0 and invoke(home,['apply','--version','test']) == 0

# Crash during hidden staging is harmless: it was never a published journal.
home = newhome('stage-crash'); wrapper_stage = r'''
import importlib.machinery,importlib.util,os,sys
loader=importlib.machinery.SourceFileLoader('txn',sys.argv[1]);spec=importlib.util.spec_from_loader(loader.name,loader);m=importlib.util.module_from_spec(spec);loader.exec_module(m)
real=m.store_manifest
def interrupted(directory,journal):
    real(directory,journal)
    if directory.name.startswith('.staging-'): os._exit(72)
m.store_manifest=interrupted;sys.argv=['txn','--payload',sys.argv[2],'apply','--version','test'];sys.exit(m.main())
'''
env=dict(os.environ,HOME=str(home)); run=subprocess.run([sys.executable,'-c',wrapper_stage,str(script),str(repo)],env=env,capture_output=True)
assert run.returncode == 72 and not (home/'.local/bin/swap-guard').exists()
assert invoke(home,['list']) == 0 and invoke(home,['apply','--version','test']) == 0

# Each new directory entry is synchronized before creating the next component.
home = newhome('directory-order'); events=[]; real_mkdir=mod.os.mkdir; real_sync=mod.sync_dir
def traced_mkdir(path, *args, **kwargs):
    result=real_mkdir(path,*args,**kwargs); events.append(('mkdir',os.path.realpath(str(path)))); return result
def traced_sync(path):
    events.append(('sync',str(path))); return real_sync(path)
with mock.patch.object(mod.os,'mkdir',side_effect=traced_mkdir), mock.patch.object(mod,'sync_dir',side_effect=traced_sync):
    mod.durable_mkdir(home/'a'/'b'/'c')
for index, (_, path) in enumerate(events):
    if events[index][0] == 'mkdir':
        assert events[index+1] == ('sync',str(pathlib.Path(path).parent)), events
home = newhome('directory-fault')
with mock.patch.object(mod,'sync_dir',side_effect=OSError('simulated fsync failure')):
    try: mod.durable_mkdir(home/'a'/'b')
    except OSError: pass
    else: raise AssertionError('fsync error ignored')
assert not (home/'a'/'b').exists()
# An interrupted barrier after mkdir(a) must be retried even though a now exists.
home = newhome('directory-retry'); failed=[False]; real_sync=mod.sync_dir
def fail_parent_once(path):
    if pathlib.Path(path) == pathlib.Path(os.path.realpath(home)) and (home/'a').exists() and not failed[0]:
        failed[0]=True; raise OSError('simulated parent fsync failure')
    return real_sync(path)
with mock.patch.object(mod,'sync_dir',side_effect=fail_parent_once):
    try: mod.durable_mkdir(home/'a'/'b')
    except OSError: pass
    else: raise AssertionError('parent fsync error ignored')
assert failed[0] and (home/'a').is_dir() and not (home/'a'/'b').exists()
barriers=[]
def record_parent(path):
    barriers.append(pathlib.Path(path)); return real_sync(path)
with mock.patch.object(mod,'sync_dir',side_effect=record_parent):
    mod.durable_mkdir(home/'a'/'b')
assert pathlib.Path(os.path.realpath(home)) in barriers and (home/'a'/'b').is_dir(), barriers

# A killed process after replacement but before the applied marker is recoverable.
home = newhome('crash'); wrapper = r'''
import importlib.machinery,importlib.util,os,sys
loader=importlib.machinery.SourceFileLoader('txn',sys.argv[1]);spec=importlib.util.spec_from_loader(loader.name,loader);m=importlib.util.module_from_spec(spec);loader.exec_module(m)
real=m.store_manifest
def interrupted(directory,journal):
    if any(i['status']=='applied' for i in journal['entries']): os._exit(71)
    return real(directory,journal)
m.store_manifest=interrupted;sys.argv=['txn','--payload',sys.argv[2],'apply','--version','test'];sys.exit(m.main())
'''
env=dict(os.environ,HOME=str(home)); run=subprocess.run([sys.executable,'-c',wrapper,str(script),str(repo)],env=env,capture_output=True)
assert run.returncode==71 and (home/'.local/bin/overclaude-codex-continue').exists()
journal = next(p for p in (home/'.claude-swap-backup/install-transactions').iterdir() if p.is_dir())
assert invoke(home,['apply','--version','test']) != 0
assert invoke(home,['recover','--transaction',journal.name]) == 0
assert not (home/'.local/bin/overclaude-codex-continue').exists()
assert json.loads((journal/'journal.json').read_text())['state']=='rolled_back'

# Corrupt data, malicious targets, invalid IDs, and lock contention fail safely.
home = newhome('badjournal'); assert invoke(home,['apply','--version','test']) == 0
rootdir=home/'.claude-swap-backup/install-transactions'; journal=next(p for p in rootdir.iterdir() if p.is_dir())
manifest=json.loads((journal/'journal.json').read_text()); manifest['state']='applying'; manifest['entries'][0]['rel']='../../outside'; (journal/'journal.json').write_text(json.dumps(manifest))
assert invoke(home,['recover','--transaction',journal.name]) != 0
assert invoke(home,['recover','--transaction','../../outside']) != 0
with open(rootdir/'.lock','r+') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    assert invoke(home,['list']) != 0
print('test_install_transaction.sh: recovery, conflicts, symlinks, locking, and validation passed')
PY
rc=$?
rm -rf "$HOME"
exit "$rc"
