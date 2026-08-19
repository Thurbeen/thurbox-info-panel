# thurbox-info-panel

v1's info panel, as a [thurbox](https://github.com/Thurbeen/thurbox) interface
plugin: everything the selected session is doing, and what it has cost, in one
column beside the terminal.

thurbox v1 drew this in Rust (`src/ui/info_panel.rs`, ~2000 lines) and the v2
plugin kernel deleted it along with the rest of `src/ui`. This is the same panel
rebuilt through the plugin API — the snapshot for reads, theme roles for colour,
and the kernel's four node kinds for everything on screen.

```text
╭ Sessions ─────────────────⠇╮╭ Info ────────────────────────────╮╭ ◀ F9 ─ Agent ── fix-osc52-tmux ╮
│── thurbox ─────────────────││  Name:     fix-osc52-tmux        ││                                │
│ ⠇ ⇅ ⑂ fix-osc52-tmux       ││  Status:   ◐ working             ││                                │
│                            ││  Agent:    claude                ││                                │
│                            ││  Parent:   lead-session          ││                                │
│                            ││  Host:     ⇅ devbox              ││                                │
│                            ││  Activity: Editing               ││                                │
│                            ││            src/agent/transport.rs││                                │
│                            ││            and running the tmux  ││        terminal surface        │
│                            ││  Signal:   Claude needs approval ││                                │
│                            ││            to run `git push      ││                                │
│                            ││            --force-with-lease    ││                                │
│                            ││            origin fix/osc52`     ││                                │
│                            ││  Repos:    thurbox/fix/osc52     ││                                │
│                            ││            website               ││                                │
│                            ││  Base:     main                  ││                                │
│                            ││  Changes:  7 files  +214 / -38  …││                                │
│                            ││  Sync:     ↑2 ↓1                 ││                                │
│                            ││  CPU:      188%  (1.9 cores)     ││                                │
│                            ││  RAM:      812.0 MB              ││                                │
│                            ││──────────────────────────────────││                                │
│                            ││  Agent (Opus 5 v2.1.4)           ││                                │
│                            ││  Cost:     $0.8342               ││                                │
│                            ││  Time:     1h 15m  (api 31m 20s) ││                                │
│                            ││  Tokens:   1.3M in / 48.2k out   ││                                │
│                            ││  Context     71%  142.0k/200.0k  ││                                │
│                            ││  Lines:    +412 / -96            ││                                │
│                            ││  Cache:    980.0k read / 120.0k  ││                                │
│                            ││──────────────────────────────────││                                │
│                            ││  Usage (max · devbox)            ││                                │
│                            ││  5h        ███░░░░░  42%  2h 0m  ││                                │
│                            ││  Week      ███████░  89%  3d 20h ││                                │
│                            ││──────────────────────────────────││                                │
│                            ││  System                          ││                                │
│                            ││  CPU         63%                 ││                                │
│                            ││  RAM         49%  15.2/31.3 GB   ││                                │
│                            ││──────────────────────────────────││                                │
│                            ││  Automations (2)                 ││                                │
│                            ││  shepherd-tick  */10 * * * *  ok ││                                │
╰────────────────────────────╯╰──────────────────────────────────╯╰────────────────────────────────╯
```

## Install

```bash
thurbox-cli plugin install git+https://github.com/Thurbeen/thurbox-info-panel
```

Then give the column a place in your `layout.lua`, inside the `columns` block and
**before** the `center` entry — that order is what puts it between the session
list and the terminal:

```lua
if panels.shown("info") and filled(ctx, "info") then
  columns[#columns + 1] = { slot = "info", pct = 30, min = 34 }
end
```

Both helpers are already in `layout.lua`: `panels.shown` is what `F2` toggles, and
`filled` is the other half — turned off in the Interface tab, the column is not
reserved either. `pct`/`min` are yours to tune; the panel is legible from about 28
columns and the preview above is at 36.

Then run `thurbox-cli plugin check`, and press **`F2`** (or click the **`info`**
pill). It starts hidden, as v1's did.

It needs no trust and grants nothing: the pane declares no capabilities, so it
cannot run a program or read a file. Everything it draws is already in the
snapshot the kernel publishes each frame.

### Why the layout edit cannot be skipped

It is fair to ask why an installed plugin does not simply appear. The panel is a
**column**, and a column is arrangement — which `layout.lua` owns and which the
package manager deliberately never writes. `plugin check` is the guard rail,
because a pane that loaded but which nothing places is the one failure with no
symptom:

```text
✗ plugins/30_info_panel.lua — loaded, but nothing places slot "info"
    add it to layout.lua's children: { slot = "info" }
```

There *is* a version that needs no edit, and it is worth knowing why it was
thrown away. A plugin can declare `decorates = "center"` and hand back the
centre's tree wrapped in a horizontal split — no slot, no arrangement, and
unfocusable for free. It draws in the right place, and it is broken, because of
the kernel's second rule:

> **Layout resolves before render.** Rects are computed first, then each plugin
> is called with its own.

By the time a decorator sees the centre's tree, the terminal pane has *already
rendered*: it composed its title, its truncation and its surface geometry for the
full width. Shrinking that tree afterwards hands it a rect it never agreed to, and
the visible symptom is the agent's frame losing its right border — a title built
for 100 columns painted into 62. (The agent pane is not at fault; rendered *at* 62
it closes its frame correctly.) Decorators restyle a tree, matching on the
`id`/`class`/`role` its nodes carry. They must not resize one.

So the three lines are the honest price of a real column, and they buy the thing
the shortcut only imitated.

## Not focusable, by design

Like v1's panel, this one is a **readout**. It declares `focusable = false` and no
`input`, so it has no scoped keyboard, no cursor and nothing to mutate: it is
absent from the `Ctrl+H`/`Ctrl+L` focus ring and can never hold the selection.
`F2` shows and hides it rather than moving focus into it. It follows the session
list's cursor (`store.selected`), so what it describes is always whatever is
selected over there.

**Turning it off** is the Interface tab (`Ctrl+,` then `]`, then `space`), which
stops the file being loaded — so it declares no key and, through `filled` above,
is given no column either. v1's `[features] info_panel` is not consulted: nothing
in v2 reads those flags, and the Interface tab is their replacement.

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
rumdl check .                              # this file
lua dev/preview.lua <ui-dir> [width] [scenario]
```

`thurbox.yml` is vendored from the thurbox repository: it is selene's standard
library for this pane and declares exactly what the plugin VM grants, so reaching
for `os` or `print` fails lint instead of failing when someone opens the pane.
Keep it in step with upstream.

**`dev/preview.lua` renders the pane outside thurbox**, against a fabricated
snapshot, and exits non-zero if any row is wider than the pane. It exists because
a pane can only fail at runtime and because the kernel's `Metrics` has no
setters — everything below the `Agent` heading is unreachable from a Rust
integration test. It has already earned its place three times over, catching an
assignment to a `for` variable (an error in Lua 5.4, which the kernel embeds), two
rows whose width budget had forgotten the frame's own two columns, and a
`[features]` branch that returned a message where a *column* was expected — which
would have replaced the terminal with it.

```bash
# a checkout's interface, or ~/.config/thurbox/ui
UI=~/.config/thurbox/ui
for s in full no-session bare; do
  for w in 28 36 44 80; do
    lua dev/preview.lua "$UI" $w $s >/dev/null || echo "FAIL $s@$w"
  done
done
```

`width` is the column's width, which is what the pane is handed and what every
budget inside it measures against — so sweeping it is how the wrap, the clip and
the bar-or-detail rule get exercised. The harness needs an interface directory
because the pane requires `lib.theme`, `lib.widgets` and `lib.panels` from it.

`selene dev` prints a harmless `lua version lua52 … not enabled` notice from
selene's own build; the exit code is what matters.

## License

MIT — see [LICENSE](LICENSE).
