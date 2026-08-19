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

--- Columns available for a row's value, after the margin and the label column.
local function value_width(width)
  return math.max(1, inner_width(width) - #INDENT - LABEL)
end

--- Automations listed before the section says "and N more". The panel is a
--- readout beside a terminal, not an automations pane — past a handful of rows
--- it stops being glanceable and starts pushing the sections below it off.
local AUTOMATION_ROWS = 5

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

local function format_duration(ms)
  if ms < 1000 then
    return string.format("%dms", ms)
  end
  local total_secs = math.floor(ms / 1000)
  local secs = total_secs % 60
  local mins = math.floor(total_secs / 60) % 60
  local hours = math.floor(total_secs / 3600)
  if hours > 0 then
    return string.format("%dh %02dm", hours, mins)
  elseif mins > 0 then
    return string.format("%dm %02ds", mins, secs)
  end
  return string.format("%ds", secs)
end

local function format_tokens(count)
  if count >= 1000000 then
    return string.format("%.1fM", count / 1000000)
  elseif count >= 1000 then
    return string.format("%.1fk", count / 1000)
  end
  return string.format("%d", count)
end

--- A rate-limit window's reset, coarse on purpose: the exact second is noise
--- when the window is days wide.
local function format_countdown(secs)
  if secs <= 0 then
    return "now"
  end
  local days = math.floor(secs / 86400)
  local hours = math.floor((secs % 86400) / 3600)
  local mins = math.floor((secs % 3600) / 60)
  if days > 0 then
    return string.format("%dd %dh", days, hours)
  elseif hours > 0 then
    return string.format("%dh %dm", hours, mins)
  elseif mins > 0 then
    return string.format("%dm", mins)
  end
  return "<1m"
end

-- ── row shapes ──────────────────────────────────────────────────────────────

--- Split a word too long to fit into `width`-character chunks.
---
--- Cut on character boundaries, not byte offsets: `string.sub` in the middle of
--- a multi-byte glyph produces a broken one, and the values reaching here are
--- exactly the ones with such glyphs in them.
local function chunks(word, width)
  local out = {}
  local total = widgets.len(word)
  local first = 1
  while first <= total do
    local last = math.min(first + width - 1, total)
    local from = utf8.offset(word, first) or 1
    local to = (utf8.offset(word, last + 1) or (#word + 1)) - 1
    out[#out + 1] = string.sub(word, from, to)
    first = last + 1
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
  local lines = wrap_text(tostring(value), value_width(width))
  local out = {}
  for index = 1, #lines do
    if index == 1 then
      out[index] = {
        { text = INDENT .. widgets.pad(label, LABEL), style = { fg = theme.muted } },
        { text = lines[index], style = style },
      }
    else
      out[index] = {
        { text = INDENT .. string.rep(" ", LABEL) },
        { text = lines[index], style = style },
      }
    end
  end
  return { type = "text", len = #out, text = out }
end

--- Clip a list of styled spans to `room` characters.
---
--- The renderer clips an overlong row at the border anyway. Doing it here means
--- the PLUGIN chooses what goes, and these rows are built most-important-first,
--- so what goes is the tail: a truncated `3 untracked` beats a `-38` that ran
--- off the edge because a count nobody asked about was in front of it.
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
      local left = room - used
      if left > 0 then
        out[#out + 1] = { text = widgets.truncate(text, left), style = span.style }
      end
      break
    end
  end
  return out
end

--- A row whose value is assembled from several styled spans — `+12 / -3`, where
--- each half carries its own colour. One line: these are numbers the plugin
--- composed itself, and clipping the tail reads better than wrapping two of them.
local function spans_field(label, spans, width)
  local line = { { text = INDENT .. widgets.pad(label, LABEL), style = { fg = theme.muted } } }
  for _, span in ipairs(clip(spans, value_width(width))) do
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
local function section(rows, title, width)
  rows[#rows + 1] = widgets.divider(inner_width(width))
  rows[#rows + 1] = {
    type = "text",
    len = 1,
    text = { { { text = INDENT .. title, style = { fg = theme.accent, bold = true } } } },
  }
end

-- Gauge geometry. At file scope because a GROUP of gauges has to budget with the
-- same numbers one gauge does — see `group_bar`.
local PCT = 6
local GAP = 2
local MAX_BAR = 24
local MIN_BAR = 4

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
--- A gauge whose bar is shorter than the one above it cannot be read against it,
--- which is the only reason to draw bars instead of printing percentages. So the
--- group pays for its LONGEST detail and every bar in it comes out the same
--- length — including the rows that have no detail. When even that leaves no room
--- for a bar, the whole group drops its details together rather than half of them.
local function group_bar(details, width)
  local longest = 0
  for _, detail in ipairs(details) do
    if detail ~= "" then
      longest = math.max(longest, GAP + widgets.len(detail))
    end
  end
  local room = inner_width(width) - #INDENT - LABEL - PCT
  if room - longest < MIN_BAR then
    -- No room for the details: bars only, all of them equal.
    return math.max(MIN_BAR, math.min(room, MAX_BAR)), false
  end
  return math.max(MIN_BAR, math.min(room - longest, MAX_BAR)), true
end

--- A labelled gauge on one line: `CPU   ████░░░░   38%  11.2/15.9 GB`.
---
--- The bar is sized from what is left after the label, the percentage AND the
--- detail. Budgeting for the first two only is how a detail string ends up
--- clipped at the pane edge in a narrow column, and every fix by subtraction is
--- one column short of the next terminal width. So the DETAIL is served first
--- and the bar takes the remainder: a bar stays legible at any length above a
--- few columns, and `15.9 G…` is legible at none. Below the point where both
--- fit, the detail is dropped rather than truncated — the gauge beside it
--- already carries the same number approximately.
---
--- `percent` overrides the number shown, for the one gauge whose value is not
--- its ratio: a process using two cores is at 200%, which has no place on a bar
--- that ends at one.
local function meter(label, ratio, detail, width, percent, bar)
  ratio = math.max(0, math.min(ratio or 0, 1))
  local inner = inner_width(width)
  local fixed = #INDENT + LABEL + PCT
  local shown = nil
  if detail and inner - fixed - (GAP + widgets.len(detail)) >= MIN_BAR then
    shown = detail
  end
  if not bar then
    local room = inner - fixed - (shown and (GAP + widgets.len(shown)) or 0)
    bar = math.max(MIN_BAR, math.min(room, MAX_BAR))
  end
  local filled = math.floor(ratio * bar + 0.5)
  return {
    type = "text",
    len = 1,
    text = {
      {
        { text = INDENT .. widgets.pad(label, LABEL), style = { fg = theme.muted } },
        { text = string.rep("█", filled), style = { fg = pressure(ratio) } },
        { text = string.rep("░", bar - filled), style = { fg = theme.muted } },
        {
          text = string.format(" %3d%%", math.floor((percent or ratio * 100) + 0.5)),
          style = { fg = theme.text, bold = true },
        },
        { text = shown and (string.rep(" ", GAP) .. shown) or "" },
      },
    },
  }
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
    rows[#rows + 1] = field("", extra[index], { fg = theme.branch }, width)
  end

  -- What the diff is taken against, when it is not the branch itself.
  if session.base_branch and session.base_branch ~= branch then
    rows[#rows + 1] = field("Base:", session.base_branch, { fg = theme.muted }, width)
  end
end

local function push_git(rows, git, width)
  if git.files > 0 or git.dirty then
    local files = (git.files == 1) and "1 file" or string.format("%d files", git.files)
    local spans = {
      { text = files, style = { fg = theme.text } },
      { text = "  " },
      { text = string.format("+%d", git.insertions), style = { fg = theme.ok } },
      { text = " / ", style = { fg = theme.muted } },
      { text = string.format("-%d", git.deletions), style = { fg = theme.bad } },
    }
    -- Untracked-only changes count as dirty with nothing in the diff, so say so
    -- rather than showing "0 files +0 / -0" and nothing else.
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
local function push_session_resources(rows, m, width)
  if (m.cpu_percent or 0) <= 0 and (m.memory_bytes or 0) <= 0 then
    return
  end
  local cpu = m.cpu_percent or 0
  -- A process spanning cores reports above 100. The bar still ends at one core's
  -- worth, and the number beside it tells the truth.
  rows[#rows + 1] = meter("CPU", cpu / 100, nil, width, cpu)
  rows[#rows + 1] = field("RAM", format_bytes(m.memory_bytes or 0), { fg = theme.text }, width)
end

local function agent_heading(m)
  local model, version = m.model, m.cli_version
  if model and version then
    return string.format("Agent (%s v%s)", model, version)
  elseif model then
    return string.format("Agent (%s)", model)
  elseif version then
    return string.format("Agent (v%s)", version)
  end
  return "Agent"
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
    rows[#rows + 1] = meter("Context", m.context_used_percent / 100, detail, width)
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

--- The heading names the plan and, for a remote session, the host whose
--- credentials the numbers came from — so usage from two accounts is never
--- mistaken for one.
local function usage_heading(usage, host)
  local plan = usage.plan
  if plan and host then
    return string.format("Usage (%s · %s)", plan, host)
  elseif plan then
    return string.format("Usage (%s)", plan)
  elseif host then
    return string.format("Usage (%s)", host)
  end
  return "Usage"
end

local function push_usage(rows, usage, host, width)
  section(rows, usage_heading(usage, host), width)

  local windows = usage.windows or {}
  if #windows == 0 then
    if usage.note then
      rows[#rows + 1] = field("", usage.note, { fg = theme.muted }, width)
    end
    return
  end

  -- `resets_at` is an absolute epoch second and the sandbox has no clock, so the
  -- countdown is measured from the snapshot's own instant.
  local now = math.floor(widgets.now_ms() / 1000)
  local details = {}
  for index = 1, #windows do
    local window = windows[index]
    if window.resets_at and now > 0 then
      details[index] = format_countdown(window.resets_at - now)
    else
      -- An empty string rather than a hole: `ipairs` stops at the first `nil`,
      -- so a window with no reset time would end the budget early and size the
      -- group off the windows before it.
      details[index] = ""
    end
  end
  local bar, keep = group_bar(details, width)

  for index = 1, #windows do
    local window = windows[index]
    local percent = window.used_percent or 0
    local detail = keep and details[index] ~= "" and details[index] or nil
    rows[#rows + 1] = meter(window.label or "?", percent / 100, detail, width, percent, bar)
  end
end

local function push_system(rows, system, width)
  section(rows, "System", width)
  local used, total = system.memory_used or 0, system.memory_total or 0
  local ratio = (total > 0) and (used / total) or 0
  local pair = format_bytes_pair(used, total)
  -- CPU carries no detail but is sized as though it did, so the two bars below
  -- can be read against each other.
  local bar, keep = group_bar({ pair }, width)

  rows[#rows + 1] = meter("CPU", (system.cpu_percent or 0) / 100, nil, width, nil, bar)
  rows[#rows + 1] = meter("RAM", ratio, keep and pair or nil, width, nil, bar)
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
    -- Half the row for the name, so a long one cannot leave no room for the
    -- schedule beside it — which is the pair that says whether this will fire.
    local room = inner_width(width) - #INDENT
    local spans = {
      {
        text = widgets.truncate(entry.name or "?", math.max(8, math.floor(room / 2))),
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
    rows[#rows + 1] =
      field("", string.format("+%d more", #live - AUTOMATION_ROWS), { fg = theme.muted }, width)
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
local function panel(ctx, rows)
  return {
    type = "box",
    frame = widgets.panel("Info", ctx.focused),
    children = rows,
  }
end

--- A framed explanation, wrapped.
---
--- Wrapped rather than one line because these are sentences, not values: the
--- longest of them names a settings key and overran a 44-column column, which is
--- the width v1 gave this panel.
local function saying(ctx, text)
  local lines = wrap_text(text, math.max(1, inner_width(ctx.width or 0) - #INDENT))
  local out = {}
  for index = 1, #lines do
    out[index] = { { text = INDENT .. lines[index], style = { fg = theme.muted } } }
  end
  return panel(ctx, { { type = "text", len = #out, text = out } })
end

return {
  name = NAME,
  -- The centre, shared with the agent terminal, because that is the only slot
  -- the shipped `layout.lua` offers a plugin: the manager never writes the
  -- arrangement, so a pane asking for a slot of its own installs and then never
  -- draws. `F2` brings it forward and puts the terminal back.
  --
  -- v1's geometry was a column BESIDE the terminal. README.md has that recipe —
  -- three lines in `layout.lua` and a one-word edit here — for anyone who wants
  -- it and is willing to edit the arrangement to get it.
  slot = "center",
  slot_mode = "switch",
  order = 30,
  -- Focusable because in a switch slot focus is what makes a pane DRAWN, not
  -- merely what gives it the keyboard. A readout that could not be focused
  -- could not be shown.
  focusable = true,

  -- The action band's entry for this pane, so it is offered on screen rather
  -- than only by a key somebody has to know. The kernel reports a switch
  -- alternate with no pill as undiscoverable, and it is right to.
  pills = {
    { action = "info.toggle", label = "info", priority = 30 },
  },

  keys = {
    {
      key = "f2",
      action = "info.toggle",
      desc = "session info",
      scope = "global",
      group = "UI",
    },
  },

  render = function(ctx)
    local snapshot = thurbox or {}
    local width = ctx.width or 0

    -- The kernel publishes every feature switch, including the ones it does not
    -- act on, precisely so the pane owning a surface can honour its own. v1's
    -- `[features] info_panel = false` hid this panel; here it is the panel's
    -- job, and nothing else in thurbox reads that flag any more.
    local features = snapshot.settings and snapshot.settings.features
    if features and features.info_panel == false then
      return saying(ctx, "switched off by [features] info_panel in settings.toml")
    end

    local session = selected_session()
    local metrics = snapshot.metrics or {}
    local system = metrics.system
    local own = session and (metrics.sessions or {})[session.id] or nil

    local rows = {}

    if session then
      push_session(rows, session, name_of(session.parent), width)
      push_repos(rows, session, width)
      -- Absent means "not computed yet", which the panel must not draw as a
      -- clean tree.
      if session.git then
        push_git(rows, session.git, width)
      end
      if own then
        push_session_resources(rows, own, width)
      end
      if own and own.agent then
        push_agent(rows, own.agent, width)
      end
      if own and own.usage then
        push_usage(rows, own.usage, session.host, width)
      end
    else
      -- v1 returned before painting its block when there was no session. An
      -- empty bordered box is worse than either that or this: the panel says
      -- what it is waiting for, and the System section below still has news.
      rows[#rows + 1] =
        plain_row({ { text = "no session selected", style = { fg = theme.muted } } }, width)
    end

    -- The kernel publishes a ZEROED machine table before the first sample rather
    -- than omitting it, so `system ~= nil` is not the question. A total memory of
    -- zero is: no machine reports that, so it means nothing has been sampled yet
    -- — and `0.0/0.0 KB` is a worse answer than no section.
    if system and (system.memory_total or 0) > 0 then
      push_system(rows, system, width)
    end
    push_automations(rows, snapshot.automations or {}, width)

    -- A spacer that takes the remainder, so the rows stack from the top instead
    -- of being spread down the column. Every row above declares `len`, and a
    -- child with no length declared is what shares what is left.
    rows[#rows + 1] = blank()
    rows[#rows].len = nil

    return panel(ctx, rows)
  end,

  on_action = function(action)
    if action == "info.toggle" then
      -- `toggle` is what makes one key a door that swings both ways: it focuses
      -- this pane, and focuses whatever you came from when this pane already has
      -- focus. Without it the key would be a one-way trip into a readout.
      command("focus", { text = NAME, toggle = true })
      return true
    end
    return false
  end,
}
