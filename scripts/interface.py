"""Prepare a disposable copy of the release's interface, never the live UI."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

repo = Path(__file__).resolve().parent.parent
root = Path(sys.argv[1]).resolve()
root.mkdir(parents=True, exist_ok=True)
marker = root / ".info-panel-scratch"
if (root / "ui").exists():
    if not marker.exists():
        raise SystemExit("Refusing to replace an interface not created by this harness")
    shutil.rmtree(root / "ui")
marker.touch()
for name, suffix in {
    "THURBOX_UI_DIR": "ui", "THURBOX_CONFIG_DIR": "config",
    "THURBOX_DATA_DIR": "data", "XDG_CACHE_HOME": "cache",
}.items():
    os.environ[name] = str(root / suffix)
    (root / suffix).mkdir(exist_ok=True)
subprocess.run(["thurbox-cli", "plugin", "install", str(repo), "--text"], check=True)
ui = root / "ui"
(ui / "plugins/30_info_panel.lua").unlink(missing_ok=True)
(ui / "plugins.lock").unlink(missing_ok=True)
payload = ui / "thurbox-info-panel"
payload.mkdir(exist_ok=True)
for name in ("info_panel.lua", "plugin.toml"):
    shutil.copyfile(repo / name, payload / name)
shutil.copytree(repo / "lib", payload / "lib", dirs_exist_ok=True)
(ui / "plugins.toml").write_text('[[plugin]]\nsrc = "git+https://github.com/Thurbeen/thurbox-info-panel"\nfile = "thurbox-info-panel/info_panel.lua"\n')
# Keep the release's bands and search arrangement; add a visible info column.
layout = (ui / "layout.lua").read_text()
layout = layout.replace('columns[#columns + 1] = { slot = "center" }',
    'columns[#columns + 1] = { slot = "info", len = 44 }\n    columns[#columns + 1] = { slot = "center" }')
(ui / "layout.lua").write_text(layout)
subprocess.run(["thurbox-cli", "plugin", "check", "--text"], check=True)
print("Isolated plugin check passed")
