# thurbox-info-panel

v1's info panel, as a [thurbox](https://github.com/Thurbeen/thurbox) interface
plugin: everything the selected session is doing, and what it has cost, in one
column beside the terminal.

thurbox v1 drew this in Rust (`src/ui/info_panel.rs`, ~2000 lines) and the v2
plugin kernel deleted it along with the rest of `src/ui`. This is the same panel
rebuilt through the plugin API — the snapshot for reads, theme roles for colour,
and the kernel's four node kinds for everything on screen.

```text
╭ ▸ Info ──────────────────────────────────────╮
│  Name:     fix-osc52-tmux                    │
│  Status:   ◐ working                         │
│  Agent:    claude                            │
│  Parent:   lead-session                      │
│  Host:     ⇅ devbox                          │
│  Activity: Editing src/agent/transport.rs    │
│            and running the tmux              │
│            control-mode probe                │
│  Signal:   Claude needs approval to run      │
│            `git push --force-with-lease      │
│            origin fix/osc52`                 │
│  Repos:    thurbox/fix/osc52                 │
│            website                           │
│            docs-site                         │
│  Base:     main                              │
│  Changes:  7 files  +214 / -38  3 untracked  │
│  Sync:     ↑2 ↓1                             │
│  CPU:      188%  (1.9 cores)                 │
│  RAM:      812.0 MB                          │
│──────────────────────────────────────────────│
│  Agent (Opus 5 v2.1.4)                       │
│  Cost:     $0.8342                           │
│  Time:     1h 15m  (api 31m 20s)             │
│  Tokens:   1.3M in / 48.2k out               │
│  Context   ████████░░░  71%  142.0k/200.0k   │
│  Lines:    +412 / -96                        │
│  Cache:    980.0k read / 120.0k created      │
│──────────────────────────────────────────────│
│  Usage (max · devbox)                        │
│  5h        ████████░░░░░░░░░░  42%  2h 0m    │
│  Week      ████████████████░░  89%  3d 20h   │
│  Opus      ██░░░░░░░░░░░░░░░░  12%           │
│──────────────────────────────────────────────│
│  System                                      │
│  CPU       ████████░░░░  63%                 │
│  RAM       ██████░░░░░░  49%  15.2/31.3 GB   │
│──────────────────────────────────────────────│
│  Automations (2)                             │
│  shepherd-tick  */10 * * * *  ok             │
│  renovate-tick  0 3 * * 1  failed            │
╰──────────────────────────────────────────────╯
```

## Install

```bash
thurbox-cli plugin install git+https://github.com/Thurbeen/thurbox-info-panel
```

Then press **`F2`** — or click the **`info`** pill in the action band.

It needs no trust and grants nothing: the pane declares no capabilities, so it
cannot run a program or read a file. Everything it draws is already in the
snapshot the kernel publishes each frame.

## Where it appears

The panel shares the **centre** slot with the agent terminal (`slot_mode =
"switch"`), because that is the only slot thurbox's shipped `layout.lua`
offers a plugin — the package manager never writes the arrangement, so a pane
that asks for a slot of its own would install and then never draw. `F2`
brings the panel forward and puts the terminal back.

### v1's geometry: a column beside the terminal

v1 put this panel in its own column, next to the terminal rather than in front of
it. That needs two edits, because the arrangement is yours and not the plugin's:

1. In the installed pane, change the slot and drop the switch:

   ```lua
   slot = "info",
   -- slot_mode = "switch",   -- delete this line
   ```

2. In your `layout.lua`, give that slot a column — inside the `columns` block,
   after the `center` entry:

   ```lua
   local panels = require("lib.panels")     -- already at the top of the file
   -- …
   columns[#columns + 1] = { slot = "center" }
   if panels.shown("info") and filled(ctx, "info") then
     columns[#columns + 1] = { slot = "info", pct = 30, min = 34 }
   end
   ```

3. Make `F2` toggle the column instead of the focus. Replace the body of
   `on_action`:

   ```lua
   if action == "info.toggle" then
     require("lib.panels").toggle("info")
     return true
   end
   ```

Editing an installed pane is expected: `plugin update` preserves your edits and
reports the file as `edited` rather than overwriting it.

Run `thurbox-cli plugin check` after either route. It fails on a pane that loaded
but which no arrangement places — the one failure with no symptom — and prints the
`layout.lua` line to add.

## What it shows, and where each number comes from

Every section is omitted when its source has published nothing, so a panel never
shows a zero it did not measure.

| Section | Source | Notes |
|---|---|---|
| Name / Status / Agent | snapshot session row | the status glyph and colour come from `theme.status`, the same function the session list draws its dot with |
| Parent | resolved from the row's parent id | lead/worker linkage; omitted for a top-level session |
| Host | `session.host` | present only for an SSH or WSL session |
| Detached | `session.attach_error` | why the terminal is not live — a v1 session could not be a placeholder, so this row is new |
| Activity / Signal | what the agent said over its own terminal | wrapped, never clipped: this is the text you read when a session wants you |
| Repos / Base | the session's member directories | one row per repo for a multi-repo session |
| Changes / Sync | `session.git` | `dirty` with no diff is called out, since untracked-only changes look like nothing |
| CPU / RAM | `metrics.sessions[id]` | this session's own process, as plain values — see below |
| Agent | the agent's statusline file | cost, wall and API time, tokens, context window, lines, cache |
| Usage | the vendor's rate-limit windows | scoped per agent *and* host, so two accounts are never merged |
| System | `metrics.system` | the whole machine |
| Automations | `thurbox.automations` | the enabled ones and their schedules |

Two properties worth knowing, because both were bugs first:

- **Bars in a group are the same length.** A gauge that cannot be read against
  the one above it defeats the point of drawing a bar, so each group budgets for
  its longest detail and every bar in it comes out equal — details are dropped
  for the whole group, or for none of it.
- **Rows are wrapped or clipped by the plugin, never by the renderer.** The
  renderer would clip an overlong row at the border silently. Values that matter
  (an agent's notification, a path) wrap under a hanging indent; composed number
  rows clip their own tail, which is the least important end.
- **A bar is only drawn where there is a denominator.** The `System` rows have
  one (100% of the machine, total RAM) and get gauges. A *process* has one for
  neither: its CPU is a share of one core and passes 100% across several, and
  nothing published here says how many cores to divide by. v1 drew a gauge
  anyway, which read *maxed out* at 188% and read identically at 400% — so the
  session's own CPU and RAM are plain values here, and above one core the
  percentage is answered in cores (`188%  (1.9 cores)`).

## Differences from v1

Three of v1's rows are not here, each because the v2 snapshot does not carry the
data — not by choice:

- **`Hooks: degraded`** — v1 read `SessionInfo::hook_wiring`. The kernel has the
  field but does not publish it to Lua.
- **`Disk (thurbox dir)`** — `kernel::metrics` does not sample the data
  directory's size.
- **Automation countdowns** (`in 2m 30s`) — the snapshot publishes each
  automation's schedule and last outcome but not its next due time, so the
  schedule is shown instead of a countdown computed from something absent.

Each becomes a few lines here the day the kernel publishes the field.

## Development

```bash
selene .                                   # the pane, against the plugin sandbox
selene dev --config dev/selene.toml        # the harness, against real Lua
stylua --check .                           # formatting
lua dev/preview.lua <thurbox-ui-dir> [width] [scenario]
```

`thurbox.yml` is vendored from the thurbox repository: it is selene's standard
library for this pane and declares exactly what the plugin VM grants, so reaching
for `os` or `print` fails lint instead of failing when someone opens the pane.
Keep it in step with upstream.

**`dev/preview.lua` renders the pane outside thurbox**, against a fabricated
snapshot, and exits non-zero if any row is wider than the pane. It exists because
a pane can only fail at runtime and because the kernel's `Metrics` has no
setters — everything below the `Agent` heading is unreachable from a Rust
integration test. It has already earned its place twice, catching an assignment
to a `for` variable (an error in Lua 5.4, which the kernel embeds) and two rows
whose width budget had forgotten the frame's own two columns.

```bash
# a checkout's interface, or ~/.config/thurbox/ui
UI=~/.config/thurbox/ui
for s in full no-session bare off; do
  for w in 28 44 80; do
    lua dev/preview.lua "$UI" $w $s >/dev/null || echo "FAIL $s@$w"
  done
done
```

The harness needs an interface directory because the pane requires `lib.theme`
and `lib.widgets` from it. `selene dev` prints a harmless
`lua version lua52 … not enabled` notice from selene's own build; the exit
code is what matters.

## License

MIT — see [LICENSE](LICENSE).
