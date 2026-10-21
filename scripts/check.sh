#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
UI=${UI:-.cache/check/ui}
python3 scripts/interface.py .cache/check
stylua --check info_panel.lua lib dev tests
selene info_panel.lua lib
selene dev tests --config dev/selene.toml
rumdl check README.md
node --check extension/refresh.mjs
lua tests/format.lua
lua tests/quota.lua
lua tests/host-quota.lua
lua tests/panel.lua "$UI"
lua tests/remote-hosts.lua "$UI"
lua tests/many-hosts.lua "$UI"
lua tests/scroll.lua "$UI"
lua tests/snapshot.lua "$UI"
for scenario in full no-session bare; do
  for width in 28 36 44 80; do
    lua dev/preview.lua "$UI" "$width" "$scenario" >/dev/null
  done
done
python3 tests/smoke.py
# Remote hosts need Thurbox 2.66.0 or later; CI still installs an older release.
if [ -n "${INFO_PANEL_CORE_BIN:-}" ]; then
  python3 tests/remote-smoke.py --core-bin-dir "$INFO_PANEL_CORE_BIN" \
    --evidence-dir .cache/remote-smoke
fi
