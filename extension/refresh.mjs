// One heartbeat invocation, with no resident process or account data on disk.
import { execFileSync } from 'node:child_process';

const cli = process.platform === 'win32' ? 'thurbox-cli.exe' : 'thurbox-cli';
const invoke = args => execFileSync(cli, args, {
  encoding: 'utf8', timeout: 10000, stdio: ['ignore', 'pipe', 'pipe'],
});
const { instances } = JSON.parse(invoke(['ui', 'instances', '--json']));
for (const { id } of instances) {
  try {
    // Instances without the pane, or ones closed since discovery, need no work.
    invoke(['ui', '--instance', id, 'action', 'info.quota.refresh', '--json']);
  } catch (error) {
    const stderr = String(error.stderr || '');
    if (!/unknown|not found|unreachable|connect/i.test(stderr)) throw error;
  }
}
