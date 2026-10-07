"""Run the real TUI with a mock quota worker in a disposable profile."""
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys

os.environ.pop("NO_COLOR", None)
os.environ["COLORTERM"] = "truecolor"
os.environ["TERM"] = "xterm-256color"
repo = Path(__file__).resolve().parent.parent
root = Path.home() / ".cache/info-panel-demo"
root.mkdir(parents=True, exist_ok=True)
for name, subdir in {
    "THURBOX_CONFIG_DIR": "config", "THURBOX_DATA_DIR": "data",
    "THURBOX_UI_DIR": "ui", "XDG_CACHE_HOME": "cache",
}.items():
    os.environ[name] = str(root / subdir)
socket_root = Path.home() / ".cache/info-panel-demo-sockets"
socket_root.mkdir(parents=True, exist_ok=True)
os.environ["TMUX_TMPDIR"] = str(socket_root)
for name in ("THURBOX_SESSION", "THURBOX_SESSION_ID", "THURBOX_SOCKET", "THURBOX_SOCKET_FOR"):
    os.environ.pop(name, None)
# Rebuild the scratch UI; source files and the live interface stay untouched.
if (root / "ui").exists():
    shutil.rmtree(root / "ui")
subprocess.run([sys.executable, str(repo / "scripts/interface.py"), str(root)], check=True, stdout=subprocess.DEVNULL)
width = 28 if "narrow" in sys.argv else 44
layout = root / "ui/layout.lua"
layout.write_text(layout.read_text().replace('slot = "info", len = 44', f'slot = "info", len = {width}'))
# Mock only the worker answer. The screen and session/git/system data are real.
fixture = json.loads((repo / "tests/fixtures/several.json").read_text())
fixture["providers"] = fixture["providers"][:4]
from datetime import datetime, timezone
# Move the whole reading to now, resets included, so countdowns read as recorded.
now = datetime.now(timezone.utc).replace(microsecond=0)
def iso(t):
    return t.isoformat().replace("+00:00", "Z")
def parse(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))
shift = now - parse(fixture["generatedAt"])
fixture["generatedAt"] = iso(now)
for provider in fixture["providers"]:
    for window in provider.get("windows", []):
        if "resetsAt" in window:
            window["resetsAt"] = iso(parse(window["resetsAt"]) + shift)
answer = json.dumps(fixture)
pane = root / "ui/thurbox-info-panel/info_panel.lua"
source = pane.read_text()
source = 'local run = function() end -- sandbox mock worker\n' + source
source = source.replace('local answer = (thurbox.runs or {}).quota', 'local answer = {state="done", status=0, stdout=[=[' + answer + ']=]}')
pane.write_text(source)
# Use a named palette from the release, not custom colours.
(root / "config/settings.toml").unlink(missing_ok=True)
work = root / "project"
work.mkdir(exist_ok=True)
if not (work / ".git").exists():
    subprocess.run(["git", "init", "-q", "-b", "main", str(work)], check=True)
    (work / "README.md").write_text("# Demo project\n")
    subprocess.run(["git", "-C", str(work), "-c", "user.name=Demo", "-c", "user.email=demo@example.invalid", "add", "README.md"], check=True)
    subprocess.run(["git", "-C", str(work), "-c", "user.name=Demo", "-c", "user.email=demo@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "Initial demo"], check=True)
(work / "README.md").write_text("# Demo project\n\nQuota readout preview.\n")
created = subprocess.run(["thurbox-cli", "session", "create", "--json", "--name", "demo", "--repo-path", str(work), "--command", "sh", "--arg", "-c", "--arg", "printf '\\033[2J\\033[HInfo panel demo\\n\\nAccount windows stay separate.\\nPress F2 to toggle Info.\\n'; sleep 120", "--on-existing", "adopt"], check=True, text=True, capture_output=True)
session_id = json.loads(created.stdout)["id"]
with sqlite3.connect(root / "data/thurbox.db") as db:
    db.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES ('v2_interface_acknowledged','1')")
    db.execute("INSERT OR REPLACE INTO metadata(key,value) VALUES ('active_theme',?)", ('catppuccin-latte' if "light" in sys.argv else 'catppuccin-mocha',))
try:
    subprocess.run(["thurbox"], cwd=work, check=True)
finally:
    subprocess.run(['thurbox-cli','runtime','stop','--json'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    # Only this profile's demo session and multiplexer server are removed.
    subprocess.run(["thurbox-cli", "session", "delete", session_id, "--force"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
