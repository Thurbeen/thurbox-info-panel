"""The companion extension installs, schedules and uninstalls on its own Thurbox floor."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

with tempfile.TemporaryDirectory(prefix='info-extension-') as scratch:
    root = Path(scratch)
    env = dict(os.environ, THURBOX_CONFIG_DIR=str(root/'config'), THURBOX_DATA_DIR=str(root/'data'))
    def cli(*args, check=True):
        return subprocess.run(['thurbox-cli',*args], env=env, check=check, text=True, capture_output=True).stdout
    try:
        cli('extension','install','.', '--home',str(root/'extension'),'--json')
        status = json.loads(cli('extension','status','info-panel-refresh','--json'))
        assert 'info-panel-quota-refresh' in json.dumps(status), status
        cli('extension','uninstall','info-panel-refresh','--json')
        cli('runtime','stop','--json')
        assert not json.loads(cli('runtime','status','--json'))['automation_heartbeat'], 'test left its heartbeat keeper running'
        print('Extension smoke passed: scheduler install/status/uninstall')
    finally:
        cli('runtime','stop','--json', check=False)
