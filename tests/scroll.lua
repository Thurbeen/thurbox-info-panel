-- Regression: the WHOLE panel scrolls, so every section stays reachable in a
-- short or narrow column. Uses the real pane and installed interface libraries.
local UI = assert(arg[1], "pass a Thurbox ui/ directory")
local PANE = arg[2] or "info_panel.lua"
package.path = UI .. "/?.lua;./?.lua;" .. package.path
for _, name in ipairs({ "quota", "format", "host_quota" }) do
  package.preload["thurbox-info-panel.lib." .. name] = function()
    return dofile("lib/" .. name .. ".lua")
  end
end
text = {
  width = function(s)
    return utf8.len(s)
  end,
  truncate = function(s, n)
    if utf8.len(s) <= n then
      return s
    end
    return s:sub(1, (utf8.offset(s, math.max(1, n)) or 1) - 1) .. "…"
  end,
  pad = function(s, n)
    return s .. string.rep(" ", math.max(0, n - utf8.len(s)))
  end,
}

local function flatten(node, lines)
  if node.type == "text" then
    if type(node.text) == "string" then
      lines[#lines + 1] = node.text
    elseif node.text.text ~= nil then
      -- One span is one line: `widgets.divider` draws a section rule this way.
      lines[#lines + 1] = node.text.text
    else
      for _, line in ipairs(node.text or {}) do
        local parts = {}
        for _, span in ipairs(line) do
          parts[#parts + 1] = span.text or ""
        end
        lines[#lines + 1] = table.concat(parts)
      end
    end
  end
  for _, child in ipairs(node.children or {}) do
    flatten(child, lines)
  end
  return lines
end

local function read(path)
  local file = assert(io.open(path))
  local body = file:read("a")
  file:close()
  return body
end
local report = read("tests/fixtures/several.json")
local function done(stdout)
  return { state = "done", status = 0, stdout = stdout }
end

local SESSION = "s1"
local function snapshot()
  return {
    taken_at_ms = 1791374400000,
    registry = { settings = {} },
    theme = { roles = {} },
    platform = { os = "linux" },
    sessions = {
      {
        id = SESSION,
        name = "fix-osc52-tmux",
        agent = "claude",
        status = "working",
        repo = "thurbox",
        branch = "fix/osc52",
        base_branch = "main",
        repos = { "thurbox", "website", "docs-site" },
        activity = "Editing src/agent/transport.rs and running the control-mode probe",
        notification = "Claude needs approval to run a push",
        git = {
          files = 7,
          insertions = 214,
          deletions = 38,
          untracked = 3,
          dirty = true,
          ahead = 2,
          behind = 1,
        },
      },
    },
    metrics = {
      system = { cpu_percent = 63.4, memory_used = 15603 * 1048576, memory_total = 32017 * 1048576 },
      sessions = {
        [SESSION] = {
          cpu_percent = 187.5,
          memory_bytes = 812 * 1048576,
          agent = {
            model = "Opus 5",
            cost_usd = 0.83,
            context_window = 200000,
            context_used_percent = 71,
          },
        },
      },
    },
    hosts = {
      { name = "first-host", platform = "posix" },
      { name = "second-host", platform = "windows" },
      { name = "third-host", platform = "posix" },
    },
    runs = {
      quota = done(report),
      ["quota.host:first-host"] = done(report),
      ["quota.host:second-host"] = { state = "failed", error = "fixture host unavailable" },
      ["quota.host:third-host"] = done(report),
    },
    automations = {
      {
        id = 1,
        name = "shepherd-tick",
        schedule = "*/10 * * * *",
        enabled = true,
        last_outcome = "ok",
        runs = {},
      },
      { id = 2, name = "last-automation", schedule = "0 3 * * 1", enabled = true, runs = {} },
    },
  }
end

run = function()
  error("viewport operations must not ask for work")
end
run_forget = function()
  error("viewport operations must not forget work")
end
command = function() end

-- Every content line the pane draws, at a height that fits all of it.
local function reference(pane, width)
  local lines = flatten(pane.render({ width = width, height = 10000 }), {})
  while #lines > 0 and lines[#lines]:match("^%s*$") do
    lines[#lines] = nil
  end
  return lines
end

-- The viewport's content lines: the pane ends every frame with one spacer.
local function frame(pane, width, height)
  local lines = flatten(pane.render({ width = width, height = height }), {})
  assert(lines[#lines] == "", "frame lost its trailing spacer")
  lines[#lines] = nil
  assert(#lines <= height - 2, "viewport drew more lines than fit at height " .. height)
  return lines
end

-- Where `lines` sits inside `all`, searching from `from` so repeated blank lines
-- resolve to the position scrolling down actually reached.
local function window(all, lines, from)
  for start = from, #all - #lines + 1 do
    local same = true
    for i = 1, #lines do
      if all[start + i - 1] ~= lines[i] then
        same = false
        break
      end
    end
    if same then
      return start
    end
  end
  error("frame is not a contiguous slice of the panel:\n" .. table.concat(lines, "\n"))
end

-- Step down with `down` until the frame stops moving, then back up with `up`.
-- Every line must be shown on the way down, and the top must come back.
local function sweep(pane, width, height, down, up, label)
  local all = reference(pane, width)
  local seen, at, previous, steady = {}, 1, nil, 0
  for _ = 1, #all * 4 + 10 do
    local lines = frame(pane, width, height)
    at = window(all, lines, at)
    for i = at, at + #lines - 1 do
      seen[i] = true
    end
    local key = table.concat(lines, "\n")
    steady = key == previous and steady + 1 or 0
    if steady >= 2 then
      break
    end
    previous = key
    down()
  end
  for i = 1, #all do
    assert(
      seen[i],
      string.format("%s skipped line %d/%d at %dx%d: %q", label, i, #all, width, height, all[i])
    )
  end
  local bottom = frame(pane, width, height)
  assert(bottom[#bottom] == all[#all], label .. " never reached the last component")
  for _ = 1, #all * 4 + 10 do
    up()
  end
  local top = frame(pane, width, height)
  assert(top[1] == all[1], label .. " never returned to the first component")
  return all
end

for _, width in ipairs({ 28, 36, 44 }) do
  for _, height in ipairs({ 3, 4, 6, 9, 14 }) do
    thurbox, store, state = snapshot(), { selected = SESSION }, {}
    local pane = dofile(PANE)
    local all = sweep(pane, width, height, function()
      assert(pane.on_scroll({ up = false }) == true, "wheel down was declined")
    end, function()
      assert(pane.on_scroll({ up = true }) == true, "wheel up was declined")
    end, "wheel")
    local rules = 0
    for _, line in ipairs(all) do
      rules = rules + ((line ~= "" and line:gsub("─", "") == "") and 1 or 0)
    end
    assert(rules >= 5, "section rules vanished from the panel: " .. rules)
    for _, want in ipairs({ "fix-osc52-tmux", "Quota left", "third-host", "Automations" }) do
      assert(
        table.concat(all, "\n"):find(want, 1, true),
        "mixed content lacks " .. want .. " at width " .. width
      )
    end

    -- Without a mouse: palette actions page through the same content.
    state = {}
    pane = dofile(PANE)
    sweep(pane, width, height, function()
      assert(pane.on_action("info.scroll.down") == true, "scroll down action missing")
    end, function()
      assert(pane.on_action("info.scroll.up") == true, "scroll up action missing")
    end, "keyboard")
  end
end
print("Whole-panel scroll passed: wheel and actions reach every line at 28-44 columns, 3-14 rows")

-- The actions are palette commands, never default global keys.
thurbox, store, state = snapshot(), { selected = SESSION }, {}
local pane = dofile(PANE)
local declared = {}
for _, entry in ipairs(pane.commands) do
  declared[entry.action] = true
end
assert(
  declared["info.scroll.down"] and declared["info.scroll.up"],
  "scroll actions not in the palette"
)
for _, key in ipairs(pane.keys) do
  assert(not key.action:find("scroll", 1, true), "scroll took a global key: " .. key.key)
end
assert(pane.focusable == false, "scrolling must not make the readout take focus")
-- The kernel offers the wheel only to a hit target. A pane that cannot take
-- focus is not one by its rect alone, so its body must carry an identity.
assert(pane.render({ width = 36, height = 8 }).id, "the wheel cannot find an unidentified pane")

-- Clamp: at the bottom, content that shrinks must still fill the viewport
-- with its own last lines instead of leaving it blank or stale.
local width, height = 36, 8
for _ = 1, 500 do
  pane.on_scroll({ up = false })
  pane.render({ width = width, height = height })
end
thurbox.hosts = { thurbox.hosts[1] }
thurbox.automations = {}
local shrunk = reference(pane, width)
local lines = frame(pane, width, height)
assert(#lines == height - 2, "shrunk content left the viewport partly blank")
assert(lines[#lines] == shrunk[#shrunk], "shrunk content did not clamp to its new end")
-- A wheel tick up after the shrink moves at once: no hidden overshoot to unwind.
pane.on_scroll({ up = true })
local above = frame(pane, width, height)
assert(above[#above] ~= lines[#lines], "scroll kept overshoot from the longer content")
-- Growing the column shows more of the same position without blank padding.
local tall = frame(pane, width, 20)
assert(#tall == math.min(18, #shrunk), "taller viewport did not fill")
-- Content that fits entirely needs no scrolling and stays at the top.
local fits = frame(pane, width, 10000)
assert(fits[1] == shrunk[1], "content that fits did not start at the top")

-- The border title says where more is, and stays plain when everything fits.
local function title(h)
  return pane.render({ width = width, height = h }).frame.title
end
assert(title(10000) == " Info ", "content that fits gained a scroll marker")
pane.on_scroll({ up = true })
state.info_scroll = 0
assert(title(height) == " Info ↓ ", "top of long content lacks the more-below marker")
pane.on_scroll({ up = false })
assert(title(height) == " Info ↑↓ ", "middle of long content lacks both markers")
for _ = 1, 500 do
  pane.on_scroll({ up = false })
end
assert(title(height) == " Info ↑ ", "bottom of long content lacks the more-above marker")

-- Empty state at the smallest height: still renders, and scrolling is inert.
thurbox, store, state = { taken_at_ms = 0, sessions = {}, metrics = {}, runs = {} }, {}, {}
pane = dofile(PANE)
for _, h in ipairs({ 1, 2, 3 }) do
  pane.render({ width = 28, height = h })
  pane.on_scroll({ up = false })
  pane.on_action("info.scroll.down")
end
print("Whole-panel scroll clamp passed: shrink, overshoot, grow, fit, empty and minimal heights")
