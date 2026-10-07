-- thurbox's info panel, as a plugin.
--
-- v1 drew this in Rust (`src/ui/info_panel.rs`, 2018 lines) and the v2 kernel
-- deleted it along with the rest of `src/ui`. This is the same panel through the
-- plugin API: the snapshot for reads, theme roles for colour, and four node
-- kinds for everything on screen.
--
-- NOT bundled. Install it into your interface with:
--
--     thurbox-cli plugin install git+https://github.com/Thurbeen/thurbox-info-panel
--
-- Two things are worth reading for what they imply about writing a pane:
--
-- 1. **Every number is formatted here.** The kernel publishes byte counts, token
--    counts, durations, percentages and costs raw, so the formatters below are
--    the plugin's own. That is deliberate: a kernel that shipped "8.0/16.0 GB"
--    would leave a pane arranging strings someone else composed.
-- 2. **Nothing here reads a clock.** The sandbox grants no `os`, so every age
--    and countdown is measured against `thurbox.taken_at_ms` — the instant the
--    rows being drawn were read, which is the right instant to measure from
--    anyway.
--
-- It declares no `input` and mutates nothing: like v1's panel it is a readout,
-- so it has no scoped keyboard beyond the one key that brings it forward.

local format = require("thurbox-info-panel.lib.format")
local quota = require("thurbox-info-panel.lib.quota")
local panels = require("lib.panels")
local theme = require("lib.theme")
local widgets = require("lib.widgets")

--- The pane's name, used as its own focus target and settings key. A local so
--- the string is written once and the focus command cannot drift from it.
local NAME = "info"

--- Width of the label column. `Activity:` is the longest label plus its space,
--- and aligning every value at one column is what makes the panel scannable
--- rather than ragged.
local LABEL = 10

--- Left margin. The bundled panes indent their content by two columns (the
--- selection marker in `widgets.list` occupies the same two), so a panel beside
--- them lines up.
local INDENT = "  "

--- Columns the frame itself costs. Every width budget below starts by paying it:
--- `ctx.width` is the pane's rect, and the border is drawn inside it. Forgetting
--- this is not a cosmetic error in a WRAPPED row — the wrap then produces lines
--- two columns too wide, and the renderer clips exactly the characters wrapping
--- existed to keep.
local BORDERS = 2

--- Columns available inside the frame.
local function inner_width(width)
  return math.max(1, (width or 0) - BORDERS)
end

--- Columns the value needs before a PADDED label column earns its place.
---
--- Alignment is not free: it costs `INDENT + LABEL` on every row, and on a narrow
--- panel that is nearly half of them — spent so values start in one column while
--- each one wraps across three lines. Below this the labels go ragged instead,
--- which reads fine; a wrapped value does not.
local COMPACT_VALUE_MIN = 22

--- Is this width too narrow to pay for an aligned label column?
local function compact(width)
  return inner_width(width) - #INDENT - LABEL < COMPACT_VALUE_MIN
end

--- Where a row's label ends and its value begins, at this width.
---
--- Returns the first line's prefix, the indent continuation lines get, and the
--- columns left for the value. One function, so every row below switches between
--- aligned and compact together rather than each deciding for itself.
---
--- The continuation indent is always the prefix's own width, so wrapped lines sit
--- under the value in both modes.
local function shape(label, width)
  local prefix
  if compact(width) then
    -- One space after the label. An empty label still gets an indent, so a
    --- continuation row reads as subordinate without a column to line up under.
    prefix = (label == "") and (INDENT .. " ") or (INDENT .. label .. " ")
  else
    prefix = INDENT .. widgets.pad(label, LABEL)
  end
  local used = widgets.len(prefix)
  return prefix, string.rep(" ", used), math.max(1, inner_width(width) - used)
end

--- Automations listed before the section says "and N more". The panel is a
--- readout beside a terminal, not an automations pane — past a handful of rows
--- it stops being glanceable and starts pushing the sections below it off.
local AUTOMATION_ROWS = 5

--- Marks a countdown to a window's reset, as fleet's queue pane does.
local RESET_GLYPH = "↻"

-- ── formatters ──────────────────────────────────────────────────────────────

--- Reduce a byte count to a value, its divisor and its unit — always binary and
--- never below KB, so "0 bytes" reads as `0.0 KB` rather than switching units
--- near zero.
local function human_bytes(bytes)
  local GB = 1073741824
  local MB = 1048576
  local KB = 1024
  if bytes >= GB then
    return bytes / GB, GB, "GB"
  elseif bytes >= MB then
    return bytes / MB, MB, "MB"
  end
  return bytes / KB, KB, "KB"
end

local function format_bytes(bytes)
  local value, _, unit = human_bytes(bytes)
  return string.format("%.1f %s", value, unit)
end

--- Both halves in the *total's* unit, so `8.0/16.0 GB` compares at a glance
--- instead of mixing MB against GB.
local function format_bytes_pair(used, total)
  local total_value, divisor, unit = human_bytes(total)
  return string.format("%.1f/%.1f %s", used / divisor, total_value, unit)
end

--- Four decimal places below a dollar: agent turns routinely cost fractions of a
--- cent, and `$0.00` would hide the difference between them.
local function format_cost(usd)
  if usd >= 1 then
    return string.format("$%.2f", usd)
  end
  return string.format("$%.4f", usd)
end

--- Elapsed milliseconds in the same compact units as every countdown here.
local function format_duration(ms)
  return format.duration(ms / 1000)
end

local function format_tokens(count)
  if count >= 1000000 then
    return string.format("%.1fM", count / 1000000)
  elseif count >= 1000 then
    return string.format("%.1fk", count / 1000)
  end
  return string.format("%d", count)
end

-- ── row shapes ──────────────────────────────────────────────────────────────

--- Split a word too long to fit into `width`-character chunks.
---
--- Cut on character boundaries, not byte offsets: `string.sub` in the middle of
--- a multi-byte glyph produces a broken one, and the values reaching here are
--- exactly the ones with such glyphs in them.
local function chunks(word, width)
  local out, parts, used = {}, {}, 0
  for _, code in utf8.codes(word) do
    local char = utf8.char(code)
    local columns = widgets.len(char)
    if used + columns > width and #parts > 0 then
      out[#out + 1] = table.concat(parts)
      parts, used = {}, 0
    end
    if columns > width then
      -- A two-column glyph cannot occupy a one-column remainder.
      char, columns = "…", 1
    end
    parts[#parts + 1], used = char, used + columns
  end
  if #parts > 0 then
    out[#out + 1] = table.concat(parts)
  end
  return out
end

--- Word-wrap `text` into lines of at most `width` characters.
---
--- Measured with `widgets.len`, not `#`: Lua's length operator counts bytes, so
--- a session named `café-fix` would be wrapped a column early on every line.
--- A word wider than the column is split across lines rather than truncated —
--- a path or a URL in an agent's notification is one word and all of it matters.
local function wrap_text(text, width)
  if width <= 0 then
    return { text }
  end
  local lines = {}
  local line = ""
  local function flush()
    if line ~= "" then
      lines[#lines + 1] = line
      line = ""
    end
  end
  for word in text:gmatch("%S+") do
    if widgets.len(word) > width then
      flush()
      local parts = chunks(word, width)
      for index = 1, #parts - 1 do
        lines[#lines + 1] = parts[index]
      end
      -- The tail stays open so the next word can share its line.
      line = parts[#parts] or ""
    else
      local candidate = (line == "") and word or (line .. " " .. word)
      if widgets.len(candidate) <= width then
        line = candidate
      else
        flush()
        line = word
      end
    end
  end
  flush()
  if #lines == 0 then
    lines[1] = ""
  end
  return lines
end

--- A `label: value` row, wrapped under a hanging indent.
---
--- Wrapped rather than clipped because most of these values are agent-supplied —
--- an OSC title, a notification body, a session name — and the pane edge would
--- hide exactly the text a user reads when a session wants attention. The
--- continuation lines are indented to the value column, so the label column
--- stays the thing that aligns them.
local function field(label, value, style, width)
  local prefix, cont, room = shape(label, width)
  local lines = wrap_text(tostring(value), room)
  local out = {}
  for index = 1, #lines do
    out[index] = {
      { text = (index == 1) and prefix or cont, style = { fg = theme.muted } },
      { text = lines[index], style = style },
    }
  end
  return { type = "text", len = #out, text = out }
end

--- Clip a list of styled spans to `room` characters.
---
--- The renderer clips an overlong row at the border anyway. Doing it here means
--- the PLUGIN chooses what goes, and these rows are built most-important-first,
--- so what goes is the tail. A span that does not fit WHOLE is dropped rather
--- than cut — `+214 / …` reads as a broken number — along with any separator it
--- leaves dangling. Only a first span is ever cut, since dropping it leaves nothing.
local function clip(spans, room)
  local out = {}
  local used = 0
  for _, span in ipairs(spans) do
    local text = span.text or ""
    local len = widgets.len(text)
    if used + len <= room then
      out[#out + 1] = span
      used = used + len
    else
      if used == 0 and room > 0 then
        out[#out + 1] = { text = widgets.truncate(text, room), style = span.style }
      end
      break
    end
  end
  while #out > 1 and (out[#out].text or ""):match("^[%s/·]*$") do
    out[#out] = nil
  end
  return out
end

--- A further value for the row `label` started, aligned under that row's value.
---
--- Distinct from `field("", …)`, which lines up under a fixed label COLUMN. In
--- compact mode there is no such column — each row's value starts wherever its own
--- label ended — so a continuation has to be told which label it is continuing.
--- Passing an empty one indented `website` by three columns while the
--- `thurbox/fix/osc52` above it started at nine, which read as a new section
--- rather than as more of the same one.
local function field_more(label, value, style, width)
  local _, cont, room = shape(label, width)
  local lines = wrap_text(tostring(value), room)
  local out = {}
  for index = 1, #lines do
    out[index] = { { text = cont }, { text = lines[index], style = style } }
  end
  return { type = "text", len = #out, text = out }
end

--- A row whose value is assembled from several styled spans — `+12 / -3`, where
--- each half carries its own colour. One line: these are numbers the plugin
--- composed itself, and clipping the tail reads better than wrapping two of them.
local function spans_field(label, spans, width)
  local prefix, _, room = shape(label, width)
  local line = { { text = prefix, style = { fg = theme.muted } } }
  for _, span in ipairs(clip(spans, room)) do
    line[#line + 1] = span
  end
  return { type = "text", len = 1, text = { line } }
end

--- A row with no label column, clipped to the frame.
---
--- Distinct from `spans_field("", …)`, which pays for the label column in order
--- to align a continuation UNDER a value. An automation row has no value above
--- it to align with, so ten columns of indent is ten columns of the schedule it
--- could have shown instead.
local function plain_row(spans, width)
  local line = { { text = INDENT } }
  for _, span in ipairs(clip(spans, inner_width(width) - #INDENT)) do
    line[#line + 1] = span
  end
  return { type = "text", len = 1, text = { line } }
end

local function blank()
  return { type = "text", len = 1, text = "" }
end

--- A section heading, preceded by a rule so the panel reads as sections rather
--- than one long list of rows.
---
--- `titles` is a string or a list, widest first: the first that fits whole is
--- drawn, so a narrow column says `Agent` rather than `Agent (claude-son…`. Only
--- when none fits is the last one cut. `note`, when given, sits at the right edge
--- in the warning colour, and goes when it would crowd the title.
local function section(rows, titles, width, note)
  local inner = inner_width(width)
  titles = type(titles) == "table" and titles or { titles }
  local room = inner - #INDENT
  if note and room - widgets.len(note) - 2 >= widgets.len(titles[#titles]) then
    room = room - widgets.len(note) - 2
  else
    note = nil
  end
  local title = widgets.truncate(titles[#titles], math.max(1, room))
  for _, candidate in ipairs(titles) do
    if widgets.len(candidate) <= room then
      title = candidate
      break
    end
  end
  local line = { { text = INDENT .. title, style = { fg = theme.accent, bold = true } } }
  if note then
    line[#line + 1] = {
      text = string.rep(" ", inner - #INDENT - widgets.len(title) - widgets.len(note)) .. note,
      style = { fg = theme.warn },
    }
  end
  rows[#rows + 1] = widgets.divider(inner)
  rows[#rows + 1] = { type = "text", len = 1, text = { line } }
end

-- Gauge geometry. At file scope because a GROUP of gauges has to budget with the
-- same numbers one gauge does — see `group_bar`.
local PCT = 6
local GAP = 2
local MAX_BAR = 24

--- Below this a bar is not worth its columns. Four blocks quantise a percentage
--- into quarters, which the number beside it already states exactly — so when a
--- group cannot afford both, the DETAIL is what stays: `15.2/31.3 GB` is
--- information no bar can carry.
local USEFUL_BAR = 8

--- Colour by pressure, not by value: 85% means the same thing whatever is being
--- measured, and the theme's own roles keep it right in all thirty-six palettes.
local function pressure(ratio)
  if ratio >= 0.85 then
    return theme.bad
  elseif ratio >= 0.6 then
    return theme.warn
  end
  return theme.ok
end

--- One bar length for a GROUP of gauges, and whether their details fit.
---
--- Three properties, each learned from getting it wrong:
---
--- * **Every bar in a group is the same length**, the rows with no detail
---   included. A gauge that cannot be read against the one above it defeats the
---   only reason to draw a bar instead of printing the number.
--- * **A group takes bars or details, never both for some rows and one for
---   others.** At the default 38-column width the System group's bars came out
---   four blocks wide beside `15.2/31.3 GB`; dropping the bar and keeping the
---   numbers is the better trade, and it must apply to the whole group.
--- * **Details are only kept when they fit at all.** Narrower still, there is no
---   room for the numbers either, and the bar comes back — because a bar shrinks
---   gracefully and a string does not.
---
--- Returns the bar's length — 0 for "draw none" — and whether details are kept.
--- Between them the row is exactly `INDENT + LABEL + PCT + bar + detail` wide,
--- which is what lets `meter` do no clipping of its own.
local function group_bar(labels, details, width)
  -- Gauges keep an aligned label column even when the text rows give theirs up:
  -- bars that do not start in the same column cannot be read against each other,
  -- which is the whole point of them. What compact mode changes is the column's
  -- WIDTH — the group's own longest label rather than a global ten, which is four
  -- to seven columns back on every gauge row.
  local label_width = LABEL
  if compact(width) then
    local longest_label = 0
    for _, label in ipairs(labels) do
      longest_label = math.max(longest_label, widgets.len(label))
    end
    label_width = math.max(1, math.min(LABEL, longest_label + 1))
  end

  local longest = 0
  for _, detail in ipairs(details) do
    if detail ~= "" then
      longest = math.max(longest, GAP + widgets.len(detail))
    end
  end
  local room = inner_width(width) - #INDENT - label_width - PCT
  local bars_only = math.max(0, math.min(room, MAX_BAR))

  if longest == 0 or room < longest then
    return bars_only, false, label_width
  end
  if room - longest < USEFUL_BAR then
    return 0, true, label_width
  end
  return math.min(room - longest, MAX_BAR), true, label_width
end

--- A labelled gauge on one line: `RAM   ██████░░░░  49%  15.2/31.3 GB`.
---
--- `bar` and `detail` are decided by `group_bar` rather than here, so every gauge
--- in a section agrees. A `bar` of 0 draws the row without one, which is a real
--- outcome and not an empty gauge.
---
--- `percent` overrides the number shown, for a value that is not its own ratio.
local function meter(label, ratio, detail, percent, bar, label_width)
  ratio = math.max(0, math.min(ratio or 0, 1))
  bar = bar or 0
  local spans = {
    { text = INDENT .. widgets.pad(label, label_width or LABEL), style = { fg = theme.muted } },
  }
  if bar > 0 then
    local filled = math.floor(ratio * bar + 0.5)
    spans[#spans + 1] = { text = string.rep("█", filled), style = { fg = pressure(ratio) } }
    spans[#spans + 1] = { text = string.rep("░", bar - filled), style = { fg = theme.muted } }
  end
  spans[#spans + 1] = {
    text = string.format(" %3d%%", math.floor((percent or ratio * 100) + 0.5)),
    style = { fg = theme.text, bold = true },
  }
  if detail then
    spans[#spans + 1] = { text = string.rep(" ", GAP) .. detail, style = { fg = theme.muted } }
  end
  return { type = "text", len = 1, text = { spans } }
end

-- ── sections ────────────────────────────────────────────────────────────────

--- Name, status, agent, and the optional parent / host / activity / signal rows.
local function push_session(rows, session, parent_name, width)
  rows[#rows + 1] = field("Name:", session.name or "", { fg = theme.text }, width)

  local status = session.status or "idle"
  local spec = theme.status(status)
  rows[#rows + 1] = spans_field("Status:", {
    -- The glyph and colour come from `theme.status`, the same function the
    -- session list draws its dot with — which is what keeps the two the same
    -- colour under every palette instead of agreeing by coincidence.
    { text = spec.glyph .. " " .. status, style = { fg = spec.color, bold = true } },
  }, width)

  rows[#rows + 1] = field("Agent:", session.agent or "", { fg = theme.accent, bold = true }, width)

  -- Lead/worker linkage. The snapshot publishes the parent's *id*; a name is
  -- what a reader can act on, so the caller resolves it and this row is omitted
  -- when the parent is no longer in the list.
  if parent_name then
    rows[#rows + 1] = field("Parent:", parent_name, { fg = theme.secondary }, width)
  end

  if session.host then
    rows[#rows + 1] = field("Host:", "⇅ " .. session.host, { fg = theme.accent }, width)
  end

  -- Why this session's terminal is not live, when it is not. v1 had no such row
  -- because a v1 session could not be a placeholder; an unreachable host is a
  -- state the panel should name rather than leave as a grey dot.
  if session.attach_error then
    rows[#rows + 1] = field("Detached:", session.attach_error, { fg = theme.bad }, width)
  end

  if session.activity then
    rows[#rows + 1] = field("Activity:", session.activity, { fg = theme.secondary }, width)
  end

  if session.notification then
    -- The signal is only urgent while the session is actually blocked on it;
    -- afterwards it is the last thing that happened, and colouring it red would
    -- keep asking for attention nothing needs.
    local style = (status == "blocked") and { fg = spec.color } or { fg = theme.muted }
    rows[#rows + 1] = field("Signal:", session.notification, style, width)
  end
end

--- The primary repo and branch, then one row per additional member directory.
local function push_repos(rows, session, width)
  local repo, branch = session.repo, session.branch
  local primary
  if repo and branch then
    primary = repo .. "/" .. branch
  elseif repo then
    primary = repo
  elseif branch then
    primary = branch
  else
    return
  end
  rows[#rows + 1] = field("Repos:", primary, { fg = theme.branch }, width)

  -- A multi-repo session spans several directories. `repos` lists them all
  -- including the primary, so the first is skipped rather than repeated.
  local extra = session.repos or {}
  for index = 2, #extra do
    rows[#rows + 1] = field_more("Repos:", extra[index], { fg = theme.branch }, width)
  end

  -- What the diff is taken against, when it is not the branch itself.
  if session.base_branch and session.base_branch ~= branch then
    rows[#rows + 1] = field("Base:", session.base_branch, { fg = theme.muted }, width)
  end
end

local function push_git(rows, git, width)
  if git.files > 0 or git.dirty then
    local files = (git.files == 1) and "1 file" or string.format("%d files", git.files)
    -- The diff first: it is what a narrow column keeps when the rest is clipped.
    local spans = {
      { text = string.format("+%d", git.insertions), style = { fg = theme.ok } },
      { text = " / ", style = { fg = theme.muted } },
      { text = string.format("-%d", git.deletions), style = { fg = theme.bad } },
      { text = "  " },
      { text = files, style = { fg = theme.text } },
    }
    -- Untracked-only changes count as dirty with nothing in the diff, so say so
    -- rather than showing "+0 / -0  0 files" and nothing else.
    if git.dirty and git.files == 0 then
      spans[#spans + 1] = { text = "  dirty", style = { fg = theme.warn } }
    end
    if (git.untracked or 0) > 0 then
      spans[#spans + 1] = {
        text = string.format("  %d untracked", git.untracked),
        style = { fg = theme.muted },
      }
    end
    rows[#rows + 1] = spans_field("Changes:", spans, width)
  end
  if git.ahead > 0 or git.behind > 0 then
    rows[#rows + 1] = spans_field("Sync:", {
      { text = string.format("↑%d", git.ahead), style = { fg = theme.ok } },
      { text = " " },
      { text = string.format("↓%d", git.behind), style = { fg = theme.warn } },
    }, width)
  end
end

--- This session's own process, distinct from the machine's total below.
---
--- NEITHER number gets a bar, and that is the difference between this section and
--- `System` below. A gauge needs a denominator. The machine has one for both of
--- its rows (100%, total RAM); a process has one for neither — its CPU is a share
--- of ONE core and passes 100% across several, and nothing published here says
--- how many cores there are to divide by.
---
--- v1 drew a gauge anyway. Filled to a hard 100% it read *maxed out* at 188%, and
--- read exactly the same at 400% — a bar that stops carrying information above
--- its own end is worse than the number it was drawn from. Saying `1.9 cores` is
--- what the bar was throwing away.
---
--- The value is not colour-coded by pressure either, for the same missing
--- denominator: 188% is nothing on a sixteen-core machine, so painting it red
--- would be a warning the panel cannot justify.
local function push_session_resources(rows, m, width)
  local cpu = m.cpu_percent or 0
  local memory = m.memory_bytes or 0
  if cpu <= 0 and memory <= 0 then
    return
  end

  local percent = string.format("%.0f%%", cpu)
  local spans = { { text = percent, style = { fg = theme.text } } }
  -- Above one core the percentage alone is a puzzle, so answer it in cores. Added
  -- only when it fits WHOLE: `clip` would otherwise truncate it to `(1.9 co…`,
  -- and a half-written parenthetical reads as a bug rather than as an aside the
  -- column had no room for.
  if cpu > 100 then
    local hint = string.format("  (%.1f cores)", cpu / 100)
    local _, _, room = shape("CPU:", width)
    if widgets.len(percent) + widgets.len(hint) <= room then
      spans[#spans + 1] = { text = hint, style = { fg = theme.muted } }
    end
  end
  rows[#rows + 1] = spans_field("CPU:", spans, width)
  rows[#rows + 1] = field("RAM:", format_bytes(memory), { fg = theme.text }, width)
end

--- The agent heading, widest first, for `section` to pick from.
local function agent_heading(m)
  local model, version = m.model, m.cli_version
  local titles = {}
  if model and version then
    titles[#titles + 1] = string.format("Agent (%s v%s)", model, version)
  end
  if model then
    titles[#titles + 1] = string.format("Agent (%s)", model)
  elseif version then
    titles[#titles + 1] = string.format("Agent (v%s)", version)
  end
  titles[#titles + 1] = "Agent"
  return titles
end

--- What the agent has spent, from the statusline file it writes.
---
--- Every field is optional in the snapshot because it is optional in fact, and
--- absence is kept distinct from zero throughout: a row is omitted rather than
--- drawn as `0`, so an agent that reports nothing does not look like one that
--- has spent nothing.
local function push_agent(rows, m, width)
  section(rows, agent_heading(m), width)

  if m.cost_usd and m.cost_usd > 0 then
    rows[#rows + 1] = field("Cost:", format_cost(m.cost_usd), { fg = theme.accent }, width)
  end

  if m.duration_ms then
    local spans = { { text = format_duration(m.duration_ms), style = { fg = theme.text } } }
    if m.api_duration_ms and m.api_duration_ms > 0 then
      spans[#spans + 1] = {
        text = string.format("  (api %s)", format_duration(m.api_duration_ms)),
        style = { fg = theme.muted },
      }
    end
    rows[#rows + 1] = spans_field("Time:", spans, width)
  end

  if m.input_tokens or m.output_tokens then
    local function shown(value)
      return value and format_tokens(value) or "-"
    end
    rows[#rows + 1] = field(
      "Tokens:",
      string.format("%s in / %s out", shown(m.input_tokens), shown(m.output_tokens)),
      { fg = theme.text },
      width
    )
  end

  -- The context window as used/total tokens when its size is known, else a bare
  -- percentage: the percentage alone hides how much room is left.
  if m.context_used_percent then
    local detail = nil
    if m.context_window then
      local consumed = math.floor(m.context_window * m.context_used_percent / 100 + 0.5)
      detail = string.format("%s/%s", format_tokens(consumed), format_tokens(m.context_window))
    end
    -- A group of one, so this row obeys the same bar-or-detail rule the sections
    -- with several gauges do. Budgeting it alone is how it ended up showing a
    -- full-width bar and dropping `142.0k/200.0k`, which is the half that says
    -- how much room is left.
    local bar, keep, label_width = group_bar({ "Context" }, { detail or "" }, width)
    rows[#rows + 1] =
      meter("Context", m.context_used_percent / 100, keep and detail or nil, nil, bar, label_width)
  end

  if m.lines_added or m.lines_removed then
    rows[#rows + 1] = spans_field("Lines:", {
      { text = string.format("+%d", m.lines_added or 0), style = { fg = theme.ok } },
      { text = " / ", style = { fg = theme.muted } },
      { text = string.format("-%d", m.lines_removed or 0), style = { fg = theme.bad } },
    }, width)
  end

  local read, created = m.cache_read_tokens or 0, m.cache_creation_tokens or 0
  if read > 0 or created > 0 then
    rows[#rows + 1] = field(
      "Cache:",
      string.format("%s read / %s created", format_tokens(read), format_tokens(created)),
      { fg = theme.text },
      width
    )
  end
end

-- All requests originate in actions/events, never in the draw path.
local parsed_stdout, parsed_stderr, parsed_key, parsed_at, parsed
local QUOTA_TIMEOUT = 30

--- A session on this machine to run quota-axi in: the selected one when it is
--- local, else the first local one. Thurbox fails a `run` that names no session,
--- and a remote session would read that host's accounts instead of these.
local function local_session()
  local sessions = (thurbox and thurbox.sessions) or {}
  for _, session in ipairs(sessions) do
    if session.id == store.selected and not session.host and session.cwd then
      return session
    end
  end
  for _, session in ipairs(sessions) do
    if not session.host and session.cwd then
      return session
    end
  end
  return nil
end

local function refresh_quota()
  local session = local_session()
  if run and session then
    run("quota", "quota-axi --json", { session = session.id, ttl = 60, timeout = QUOTA_TIMEOUT })
  end
end

local function quota_reading()
  if not run then
    return { status = "untrusted", rows = {} }
  end
  local now = math.floor((thurbox.taken_at_ms or 0) / 1000)
  local answer = (thurbox.runs or {}).quota
  if not answer and not local_session() then
    return { status = "unavailable", reason = "needs a local session", rows = {} }
  end
  local stdout = answer and answer.stdout
  -- Decode once per answer, plus a minute tick for age validation.
  local minute = math.floor(now / 60)
  local key = answer
      and table.concat({
        answer.state or "",
        tostring(answer.status),
        tostring(answer.timed_out),
        tostring(answer.truncated),
        -- The reason shown for a failure comes from this, and from stderr below.
        tostring(answer.error),
      }, ":")
    or "pending"
  local stderr = answer and answer.stderr
  if
    parsed_key ~= key
    or parsed_stdout ~= stdout
    or parsed_stderr ~= stderr
    or parsed_at ~= minute
    or not parsed
  then
    parsed = quota.parse(answer, now, QUOTA_TIMEOUT)
    parsed_key, parsed_stdout, parsed_stderr, parsed_at = key, stdout, stderr, minute
  end
  return parsed
end

local function quota_field(value, style, width)
  local lines = {}
  for _, line in ipairs(wrap_text(value, math.max(1, inner_width(width) - #INDENT))) do
    lines[#lines + 1] = { { text = INDENT .. line, style = style } }
  end
  return { type = "text", len = #lines, text = lines }
end

-- The quota block follows fleet's FUEL rows: one gauge per subscription for
-- the window that binds it, then each window's number and reset under it.

--- Percent remaining at or under which a window is low, and under which it is
--- getting there. The bar ticks the reserve so the floor is seen, not spelled.
local QUOTA_RESERVE = 15
local QUOTA_WARN = 40

--- Columns a subscription's label may spend before it is cut with `…`.
local QUOTA_LABEL_MAX = 18

--- A bar narrower than this is a decoration; the number stands alone instead.
local QUOTA_BAR_MIN = 6
local QUOTA_BAR_MAX = 20

--- `100%`, the widest number, so every number ends in the same column.
local QUOTA_NUMBER = 4

--- `  ↻ 23h 59m`: the reset column is kept even for a window with none, so the
--- numbers above and below it never move.
local QUOTA_RESET = 4 + format.WIDEST

local function quota_tone(remaining)
  if remaining <= QUOTA_RESERVE then
    return theme.bad
  elseif remaining <= QUOTA_WARN then
    return theme.warn
  end
  return theme.ok
end

--- `remaining` as `cells` of bar, the reserve ticked where it falls. Spans are
--- coalesced by style, so a bar is a few spans rather than one per cell.
local function quota_bar(remaining, cells)
  local filled = math.max(0, math.min(cells, math.floor(remaining / 100 * cells + 0.5)))
  local mark = math.max(1, math.min(cells, math.floor(QUOTA_RESERVE / 100 * cells + 0.5)))
  local full, empty, tick =
    { fg = quota_tone(remaining) }, { fg = theme.muted }, { fg = theme.warn }
  local spans, last = {}, nil
  for cell = 1, cells do
    local char, style = "░", empty
    if cell == mark then
      char, style = "┃", tick
    elseif cell <= filled then
      char, style = "█", full
    end
    if last and last.style == style then
      last.text = last.text .. char
    else
      last = { text = char, style = style }
      spans[#spans + 1] = last
    end
  end
  return spans
end

local function quota_number(remaining)
  return string.format("%3d%%", math.floor(remaining + 0.5))
end

--- How a subscription names itself: the provider, and its account unless the
--- reading carried none.
local function account_label(row)
  if row.account == "default" then
    return row.provider
  end
  return row.provider .. " · " .. row.account
end

--- The window a subscription's gauge shows: its tightest binding window that
--- has a number.
local function headline(row)
  local best
  for _, window in ipairs(row.bindings) do
    if window.remaining and (not best or window.remaining < best.remaining) then
      best = window
    end
  end
  return best
end

--- The row's reset as `↻ 1d 5h`, or nothing when the window gave no instant.
local function reset_spans(spans, window, now)
  if window.resets_at and now > 0 then
    spans[#spans + 1] = {
      text = "  " .. RESET_GLYPH .. " " .. format.duration(window.resets_at - now),
      style = { fg = theme.muted },
    }
  end
end

local function push_quota(rows, width)
  local reading = quota_reading()
  local now = math.floor((thurbox.taken_at_ms or 0) / 1000)
  -- The reading's age, only once a refresh that should have landed has not:
  -- inside the TTL and its timeout it is the pane working as designed.
  local age
  if reading.generated_at and now - reading.generated_at > 90 then
    age = format.duration(now - reading.generated_at) .. " ago"
  end
  section(rows, { "Quota left · local accounts", "Quota left" }, width, age)
  if reading.status ~= "ready" then
    local messages = {
      untrusted = "trust run in Interface settings",
      loading = "loading",
      missing = "npm install -g quota-axi",
      unavailable = "unavailable",
    }
    local message = messages[reading.status] or "unavailable"
    if reading.reason then
      message = message .. " · " .. reading.reason
    end
    rows[#rows + 1] = quota_field(message, { fg = theme.muted }, width)
    return
  end
  if #reading.rows == 0 then
    rows[#rows + 1] = quota_field("no configured providers", { fg = theme.muted }, width)
    return
  end

  -- One geometry for the whole block, so every bar, number and reset sits in
  -- the same column. A wide column puts the label beside the gauge; a narrow
  -- one gives the label its own line, the gauge the next, and drops the bar
  -- before it drops a number.
  local inner = inner_width(width)
  local label_width = 1
  for _, row in ipairs(reading.rows) do
    label_width = math.max(label_width, widgets.len(account_label(row)))
  end
  label_width = math.min(label_width, QUOTA_LABEL_MAX)
  local beside = inner - #INDENT - label_width - 1 - 1 - QUOTA_NUMBER - QUOTA_RESET
  local one_line = beside >= QUOTA_BAR_MIN
  local gauge_at = one_line and (#INDENT + label_width + 1) or (#INDENT * 2)
  local show_reset = inner - gauge_at >= QUOTA_NUMBER + QUOTA_RESET
  local bar = inner - gauge_at - 1 - QUOTA_NUMBER - (show_reset and QUOTA_RESET or 0)
  bar = bar >= QUOTA_BAR_MIN and math.min(bar, QUOTA_BAR_MAX) or 0
  -- Where every number ends, and what the gauge slot holds in its place.
  local number_end = gauge_at + (bar > 0 and bar + 1 or 0) + QUOTA_NUMBER
  local slot = number_end - gauge_at + (show_reset and QUOTA_RESET or 0)

  for _, row in ipairs(reading.rows) do
    local label = account_label(row)
    local spans = { { text = INDENT } }
    local label_style = { fg = theme.text, bold = true }
    if one_line then
      spans[#spans + 1] = {
        text = widgets.pad(widgets.truncate(label, label_width), label_width) .. " ",
        style = label_style,
      }
    else
      -- The gauge below has no label of its own, so the name line says which
      -- window it is, when that fits whole beside the name.
      label = widgets.truncate(label, inner - #INDENT)
      spans[#spans + 1] = { text = label, style = label_style }
      local which = headline(row) and headline(row).label
      local gap = which and inner - #INDENT - widgets.len(label) - widgets.len(which)
      if gap and gap >= 2 then
        spans[#spans + 1] = {
          text = string.rep(" ", gap) .. which,
          style = { fg = theme.accent, bold = true },
        }
      end
      rows[#rows + 1] = { type = "text", len = 1, text = { spans } }
      spans = { { text = INDENT .. INDENT } }
    end

    local top = headline(row)
    local word
    if row.status ~= "fresh" then
      word = row.status
    elseif #row.bindings == 0 then
      word = "binding unavailable"
    elseif not top then
      word = "unavailable"
    end
    if top then
      if bar > 0 then
        for _, span in ipairs(quota_bar(top.remaining, bar)) do
          spans[#spans + 1] = span
        end
        spans[#spans + 1] = { text = " " }
      end
      spans[#spans + 1] = {
        text = quota_number(top.remaining),
        style = { fg = quota_tone(top.remaining), bold = true },
      }
      if show_reset then
        reset_spans(spans, top, now)
      end
    else
      spans[#spans + 1] = {
        text = widgets.truncate(word, slot),
        style = { fg = row.status == "fresh" and theme.muted or theme.warn },
      }
    end
    rows[#rows + 1] = { type = "text", len = 1, text = { spans } }

    -- Every window under a fresh reading, in the reading's order, the binding
    -- ones in the accent. Narrow, the gauge already says the one that binds,
    -- so only a tie, a model-scope binding, or no binding at all lists them.
    local windows = {}
    if row.status == "fresh" and (one_line or #row.bindings ~= 1) then
      windows = (one_line or #row.bindings == 0) and row.windows or row.bindings
    end
    for _, window in ipairs(windows) do
      -- A window with no number says why in the number's place, spilling into
      -- the reset column rather than into its label.
      local number = window.remaining and quota_number(window.remaining)
        or widgets.truncate(window.status, slot - (number_end - gauge_at - QUOTA_NUMBER))
      local room = math.max(1, number_end - QUOTA_NUMBER - #INDENT * 2 - 1)
      local detail = {
        { text = INDENT .. INDENT },
        {
          text = widgets.pad(widgets.truncate(window.label, room), room) .. " ",
          style = window.binding and { fg = theme.accent, bold = true } or { fg = theme.muted },
        },
        {
          text = number,
          style = window.remaining and { fg = quota_tone(window.remaining), bold = true }
            or { fg = theme.warn },
        },
      }
      if show_reset and window.remaining then
        reset_spans(detail, window, now)
      end
      rows[#rows + 1] = { type = "text", len = 1, text = { clip(detail, inner) } }
    end
  end
end

local function push_system(rows, system, width)
  section(rows, "System", width)
  local used, total = system.memory_used or 0, system.memory_total or 0
  local ratio = (total > 0) and (used / total) or 0
  local pair = format_bytes_pair(used, total)
  -- CPU carries no detail but is sized as though it did, so the two bars below
  -- can be read against each other.
  local bar, keep, label_width = group_bar({ "CPU", "RAM" }, { pair }, width)

  rows[#rows + 1] = meter("CPU", (system.cpu_percent or 0) / 100, nil, nil, bar, label_width)
  rows[#rows + 1] = meter("RAM", ratio, keep and pair or nil, nil, bar, label_width)
end

--- The automations that would fire, with their schedules.
---
--- v1 showed a countdown per entry ("in 2m 30s"). The snapshot publishes each
--- automation's schedule and last outcome but not its next due time, so this
--- shows the schedule instead of computing a countdown from something that is
--- not there. Disabled entries are left out: v1 listed what was *upcoming*, and
--- a disabled automation is not.
local function push_automations(rows, automations, width)
  local live = {}
  for _, entry in ipairs(automations) do
    if entry.enabled then
      live[#live + 1] = entry
    end
  end
  if #live == 0 then
    return
  end

  section(rows, string.format("Automations (%d)", #live), width)
  for index = 1, math.min(#live, AUTOMATION_ROWS) do
    local entry = live[index]
    -- The last outcome is the one thing here that can be bad news, so it is the
    -- only thing coloured.
    local outcome = entry.last_outcome
    local style = { fg = theme.muted }
    if outcome == "failed" or outcome == "error" then
      style = { fg = theme.bad }
    elseif outcome == "ok" or outcome == "success" then
      style = { fg = theme.ok }
    end
    -- The name gives way to the schedule beside it, down to eight columns —
    -- the pair says whether this will fire, and a cut schedule says nothing.
    local room = inner_width(width) - #INDENT
    local schedule = widgets.len(entry.schedule or "")
    local spans = {
      {
        text = widgets.truncate(entry.name or "?", math.max(8, room - 2 - schedule)),
        style = { fg = theme.secondary },
      },
      { text = "  " .. (entry.schedule or ""), style = { fg = theme.muted } },
    }
    if outcome then
      spans[#spans + 1] = { text = "  " .. outcome, style = style }
    end
    rows[#rows + 1] = plain_row(spans, width)
  end
  if #live > AUTOMATION_ROWS then
    local more = string.format("+%d more", #live - AUTOMATION_ROWS)
    rows[#rows + 1] = plain_row({ { text = more, style = { fg = theme.muted } } }, width)
  end
end

-- ── the pane ────────────────────────────────────────────────────────────────

--- The selected session, which is the one every session-scoped row describes.
---
--- `store.selected` is the bus the session list publishes its cursor on, so this
--- panel follows the list without either knowing about the other.
local function selected_session()
  local id = store.selected
  if not id then
    return nil
  end
  for _, session in ipairs((thurbox and thurbox.sessions) or {}) do
    if session.id == id then
      return session
    end
  end
  return nil
end

--- A session's name, by id. Used for the parent row, which the snapshot gives
--- as an id.
local function name_of(id)
  if not id then
    return nil
  end
  for _, session in ipairs((thurbox and thurbox.sessions) or {}) do
    if session.id == id then
      return session.name
    end
  end
  return nil
end

--- The panel in its frame. One place builds the box, so the empty states below
--- are framed exactly like the full one — an unbordered message would read as a
--- pane that failed to draw.
---
--- Always drawn as UNFOCUSED, and not because the flag was forgotten: this panel
--- cannot take focus (see the declaration below), so a focused border would
--- promise a keyboard it does not have. v1 drew it with `border_unfocused` for
--- the same reason.
local function panel(rows)
  return {
    type = "box",
    frame = widgets.panel("Info", false),
    children = rows,
  }
end

--- The panel's rows for the selected session, or the empty state.
local function body(width)
  local snapshot = thurbox or {}

  local session = selected_session()
  local metrics = snapshot.metrics or {}
  local system = metrics.system
  local own = session and (metrics.sessions or {})[session.id] or nil

  local rows = {}

  if session then
    push_session(rows, session, name_of(session.parent), width)
    push_repos(rows, session, width)
    -- Absent means "not computed yet", which the panel must not draw as a clean
    -- tree.
    if session.git then
      push_git(rows, session.git, width)
    end
    if own then
      push_session_resources(rows, own, width)
    end
    if own and own.agent then
      push_agent(rows, own.agent, width)
    end
  else
    -- v1 returned before painting its block when there was no session. An empty
    -- bordered box is worse than either that or this: the panel says what it is
    -- waiting for, and the System section below still has news.
    rows[#rows + 1] =
      plain_row({ { text = "no session selected", style = { fg = theme.muted } } }, width)
  end

  push_quota(rows, width)

  -- The kernel publishes a ZEROED machine table before the first sample rather
  -- than omitting it, so `system ~= nil` is not the question. A total memory of
  -- zero is: no machine reports that, so it means nothing has been sampled yet —
  -- and `0.0/0.0 KB` is a worse answer than no section.
  if system and (system.memory_total or 0) > 0 then
    push_system(rows, system, width)
  end
  push_automations(rows, snapshot.automations or {}, width)

  -- A spacer that takes the remainder, so the rows stack from the top instead of
  -- spreading down the column. Every row above declares `len`, and a child with
  -- no length declared is what shares what is left.
  rows[#rows + 1] = blank()
  rows[#rows].len = nil

  return rows
end

return {
  name = NAME,
  capabilities = { "run" },
  pure = true,
  -- A session can appear after the reload, and the run needs one.
  events = { "interface.reloaded", "session.created" },
  on_event = function()
    refresh_quota()
  end,
  commands = { { action = "info.quota.refresh", desc = "refresh local account quotas" } },

  -- Its own COLUMN, and `layout.lua` places it — which is why installing this
  -- needs the three lines README.md gives you. That edit is not an oversight to
  -- be worked around; it is the kernel's second rule holding:
  --
  --   **Layout resolves before render.** Each pane is called with the rect it is
  --   drawing into, so a column has to exist before anything draws into it.
  --
  -- A `decorates = "center"` version of this pane needs no such edit and was
  -- written first. It is wrong, and instructively so: the centre's occupant has
  -- ALREADY rendered by the time a decorator sees its tree, so shrinking that
  -- tree hands the terminal pane a rect it did not compose for — its title, its
  -- own truncation and its surface geometry were all decided at the full width.
  -- The visible symptom is the agent's frame losing its right border, because a
  -- title built for 100 columns was painted into 62. Decorators restyle a tree
  -- (matching `id`/`class`/`role`); they must not resize one.
  slot = "info",
  order = 30,

  -- NOT focusable, exactly as v1's panel was not: it is a readout with no scoped
  -- keyboard, no cursor and nothing to mutate, and it declares no `input`. So it
  -- is absent from the `Ctrl+H`/`Ctrl+L` ring and can never hold the selection —
  -- `F2` shows and hides it rather than moving focus to it.
  focusable = false,

  -- The action band's entry, so the panel is offered on screen and not only to
  -- whoever knows the key. Clicking it runs the same toggle `F2` does.
  pills = {
    { action = "info.toggle", label = "info", priority = 30 },
  },

  keys = {
    {
      key = "f2",
      action = "info.toggle",
      desc = "show/hide the info panel",
      scope = "global",
      group = "Panels",
    },
  },

  render = function(ctx)
    -- ctx.width is THIS COLUMN's, not the screen's — which is what every width
    -- budget below is measured against.
    return panel(body(ctx.width or 0))
  end,

  on_action = function(action)
    if action == "info.quota.refresh" then
      refresh_quota()
      return true
    elseif action == "info.toggle" then
      refresh_quota()
      -- Visibility, not focus, and it belongs in `lib.panels` rather than in this
      -- file because `layout.lua` has to read it: the arrangement decides whether
      -- to carve the column BEFORE this plugin runs, so the answer cannot live
      -- inside the plugin. The bundled session list spells its F9 the same way.
      panels.toggle(NAME)
      return true
    end
    return false
  end,
}
