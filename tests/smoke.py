"""End-to-end: release TUI, quota refresh action and the refresh script."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

source = Path('.cache/check').resolve()
cache = Path.home()/'.cache'
cache.mkdir(exist_ok=True)
scratch = tempfile.TemporaryDirectory(prefix='info-', dir=cache)
root = Path(scratch.name)
shutil.copytree(source/'data', root/'data')
env = dict(os.environ, THURBOX_UI_DIR=str(source/'ui'), THURBOX_CONFIG_DIR=str(root/'config'), THURBOX_DATA_DIR=str(root/'data'))
(root/'config').mkdir()
socket = str(root/'smoke.sock')
def tmux(*args, check=True):
    return subprocess.run(['tmux','-S',socket,*args],env=env,check=check,text=True,capture_output=True).stdout
try:
    tmux('new-session','-d','-s','smoke','-x','160','-y','50','thurbox')
    screen = ''
    for _ in range(50):
        screen = tmux('capture-pane','-p','-t','smoke')
        if 'trust run in Interface settings' in screen: break
        time.sleep(.1)
    assert 'no session selected' in screen, screen
    assert 'Quota' in screen and 'trust run in Interface settings' in screen, screen
    assert '0% left' not in screen
    def cli(*args):
        return subprocess.run(['thurbox-cli',*args], env=env, check=True, text=True, capture_output=True).stdout
    instances = json.loads(cli('ui','instances','--json'))['instances']
    assert len(instances) == 1, instances
    cli('ui','--instance',instances[0]['id'],'action','info.quota.refresh','--json')
    subprocess.run(['node','extension/refresh.mjs'], env=env, check=True)
    tmux('send-keys','-t','smoke','C-q')
    print('Real TUI smoke passed: trust state, refresh action, refresh script')
finally:
    tmux('kill-server', check=False)
    scratch.cleanup()
