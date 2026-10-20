"""Real pane -> pinned core run -> fake SSH -> quota fixture, without live hosts.

Pass an existing, independently verified core binary directory; never builds or
installs core. Trust is granted through the disposable TUI's public settings.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--core-bin-dir', required=True, type=Path)
parser.add_argument('--pane-source', type=Path)
parser.add_argument('--evidence-dir', required=True, type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent
core = args.core_bin_dir.resolve()
assert (core/'thurbox').is_file() and (core/'thurbox-cli').is_file()
evidence = args.evidence_dir.resolve()
evidence.mkdir(parents=True, exist_ok=True)
cache = Path.home()/'.cache'
cache.mkdir(exist_ok=True)
# Kept short: the UI control socket path under it must fit in 108 bytes.
scratch = tempfile.TemporaryDirectory(prefix='ihq-', dir=cache)
root = Path(scratch.name)
for name in ['bin','home','config','data','cache','runtime','mux']:
    (root/name).mkdir()
# An allowlist keeps provider credentials and real host configuration out.
env = {k: os.environ[k] for k in ['PATH','LANG','LC_ALL'] if k in os.environ}
env.update(HOME=str(root/'home'), XDG_CONFIG_HOME=str(root/'config'),
           XDG_DATA_HOME=str(root/'data'), XDG_CACHE_HOME=str(root/'cache'),
           XDG_RUNTIME_DIR=str(root/'runtime'), THURBOX_CONFIG_DIR=str(root/'config'),
           THURBOX_DATA_DIR=str(root/'data'), THURBOX_UI_DIR=str(root/'ui'),
           TMPDIR=str(root/'runtime'), TMUX_TMPDIR=str(root/'mux'), TERM='xterm-256color', COLORTERM='truecolor',
           PATH=os.pathsep.join([str(root/'bin'), str(core), env.get('PATH','')]))
# No real SSH binary, quota tool, host or provider can be reached by this test.
def executable(name, body):
    p = root/'bin'/name
    p.write_text('#!'+sys.executable+'\n'+body)
    p.chmod(0o700)

fixture = json.loads((repo/'tests/fixtures/several.json').read_text())
# One account with its measured windows leaves each host visible in the TUI.
fixture['providers'] = fixture['providers'][:1]
from datetime import datetime, timezone, timedelta
now = datetime.now(timezone.utc).replace(microsecond=0)
old = datetime.fromisoformat(fixture['generatedAt'].replace('Z','+00:00'))
shift = now-old
fixture['generatedAt'] = now.isoformat().replace('+00:00','Z')
for provider in fixture['providers']:
    for window in provider['windows']:
        if 'resetsAt' in window:
            reset = datetime.fromisoformat(window['resetsAt'].replace('Z','+00:00'))+shift
            window['resetsAt'] = reset.isoformat().replace('+00:00','Z')
(root/'report.json').write_text(json.dumps(fixture))
executable('quota-axi', f'''import json, os, sys
from pathlib import Path
root=Path({str(root)!r})
assert sys.argv[1:]==['--json','--no-credential-refresh'], sys.argv
host=os.environ.get('FIXTURE_HOST','local')
with (root/'quota-calls.jsonl').open('a') as f: f.write(json.dumps({{'host':host,'args':sys.argv[1:]}})+'\\n')
report=json.loads((root/'report.json').read_text())
if host=='missing': sys.exit(127)
if host=='malformed': print('{{broken'); sys.exit(0)
for p in report['providers']:
    for w in p['windows']: w['percentRemaining']=37 if host=='healthy' else 80
print(json.dumps(report))
''')
executable('ssh', f'''import json, os, sys, time
from pathlib import Path
root=Path({str(root)!r})
a=sys.argv[1:]
while a and a[0].startswith('-'):
    opt=a.pop(0)
    if opt in ['-o','-p','-i','-F']: a.pop(0)
assert a and a[0].startswith('fixture-'), a
host=a.pop(0)[len('fixture-'):]
program=' '.join(a)
# The core's read-only mux probes are not quota requests.
if 'quota-axi' not in program: print('tmux'); sys.exit(0)
with (root/'ssh-calls.jsonl').open('a') as f: f.write(json.dumps({{'host':host,'program':program,'pid':os.getpid()}})+'\\n')
if host=='offline': print('fixture transport unavailable',file=sys.stderr); sys.exit(255)
if host=='slow': time.sleep(60); sys.exit(1)
home=root/('home-'+host); home.mkdir(exist_ok=True)
os.environ['HOME']=str(home)
os.environ['FIXTURE_HOST']=host
os.execvp('sh',['sh','-c',program])
''')
hosts = ['healthy','offline','missing','malformed','slow']
(root/'config/hosts.toml').write_text('config_version = 1\n'+''.join(
    f'\n[[hosts]]\nname = "{host}"\ndestination = "fixture-{host}"\nshare_sessions = false\n'
    for host in hosts))
(root/'config/settings.toml').write_text('[features]\nversion_check=false\nauto_update=false\nnotifications=false\n')
socket = str(root/'test.sock')
def invoke(command, check=False):
    result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=15)
    if check and result.returncode:
        raise AssertionError(Path(command[0]).name+' failed:\n'+result.stdout+result.stderr)
    return result
def cli(*command):
    r=invoke([str(core/'thurbox-cli'),*command], check=True)
    return r.stdout

def tmux(*command, check=True):
    return invoke(['tmux','-S',socket,*command],check=check).stdout

def screen():
    return tmux('capture-pane','-p','-t','hosts')

def wait_for(needle, timeout=10):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        frame=screen()
        if needle in frame: return frame
        time.sleep(.1)
    raise AssertionError('Missing '+needle+'\n'+screen())

def save(name):
    (evidence/(name+'.txt')).write_text(screen())
    (evidence/(name+'.ansi')).write_text(tmux('capture-pane','-p','-e','-t','hosts'))

started = False
try:
    r=invoke([sys.executable,str(repo/'scripts/interface.py'),str(root)],check=True)
    if args.pane_source:
        shutil.copyfile(args.pane_source,root/'ui/thurbox-info-panel/info_panel.lua')
    with sqlite3.connect(root/'data/thurbox.db') as db:
        db.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES ('v2_interface_acknowledged','1')")
    tmux('new-session','-d','-s','hosts','-x','180','-y','55',str(core/'thurbox'))
    started = True
    wait_for('trust run in Interface settings')
    assert not (root/'quota-calls.jsonl').exists(), 'quota ran before trust'
    save('untrusted')
    cli('ui','action','settings.open','--json')
    cli('ui','input','modal','--key',']','--json')
    wait_for('Interface')
    for _ in range(100):
        selected = [line for line in screen().splitlines() if '▸ ' in line]
        if any('info_panel' in line for line in selected):
            cli('ui','input','modal','--key','t','--json')
            break
        cli('ui','input','modal','--key','down','--json')
    else:
        raise AssertionError('Could not select info panel for disposable trust\n'+screen())
    cli('ui','input','modal','--key','esc','--json')
    cli('ui','action','info.quota.refresh','--json')
    # Healthy/local answers must display while the slow peer is still pending.
    wait_for('37%')
    wait_for('80%')
    assert 'no session selected' in screen()
    save('healthy')
    cli('ui','action','info.quota.next','--json')
    wait_for('loading')
    save('pending-peer')
    calls_before = (root/'quota-calls.jsonl').read_text().splitlines()
    for _ in range(10):
        cli('ui','action','info.quota.refresh','--json')
    time.sleep(.2)
    assert len((root/'quota-calls.jsonl').read_text().splitlines()) == len(calls_before), 'TTL did not deduplicate requests'
    # Every host is fetched even when on another display page, with no sessions.
    wait_for('unreadable')
    wait_for('timed out after 30s',timeout=40)
    save('peer-failures')
    ssh_calls=[json.loads(s) for s in (root/'ssh-calls.jsonl').read_text().splitlines()]
    assert set(c['host'] for c in ssh_calls) == set(hosts), ssh_calls
    assert len(ssh_calls)==len(hosts), 'one command per host per TTL required'
    assert all('--no-credential-refresh' in c['program'] for c in ssh_calls)
    quota_calls=[json.loads(s) for s in (root/'quota-calls.jsonl').read_text().splitlines()]
    assert {c['host'] for c in quota_calls} == {'local','healthy','missing','malformed'}
    (evidence/'transport-calls.json').write_text(json.dumps(ssh_calls,indent=2)+'\n')
    print('Real host TUI passed: public trust, sessionless/share=false, distinct local/remote, slow isolation, TTL, errors, timeout')
except Exception:
    if started:
        save('failure')
    raise
finally:
    if (root/'data').exists():
        invoke([str(core/'thurbox-cli'),'runtime','stop','--json'])
    tmux('kill-server',check=False)
    if (root/'ssh-calls.jsonl').exists():
        for row in (root/'ssh-calls.jsonl').read_text().splitlines():
            pid=json.loads(row)['pid']
            proc=Path('/proc')/str(pid)/'cmdline'
            if proc.exists() and str(root/'bin/ssh').encode() in proc.read_bytes():
                try: os.kill(pid,signal.SIGTERM)
                except ProcessLookupError: pass
    scratch.cleanup()
