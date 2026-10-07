-- Exercise the installed pane against current Thurbox libraries and worker JSON.
local UI = assert(arg[1], "pass a Thurbox ui/ directory")
package.path = UI .. "/?.lua;./?.lua;" .. package.path
package.preload["thurbox-info-panel.lib.quota"] = function()
  return dofile("lib/quota.lua")
end
package.preload["thurbox-info-panel.lib.format"] = function()
  return dofile("lib/format.lua")
end
-- These fixtures contain ASCII and single-column bars only.
text = {
  width = function(s)
    local width = 0
    for _, c in utf8.codes(s) do
      width = width + (c >= 0x4E00 and c <= 0x9FFF and 2 or 1)
    end
    return width
  end,
  truncate = function(s, n, opts)
    local chars = {}
    for _, c in utf8.codes(s) do
      chars[#chars + 1] = utf8.char(c)
    end
    if #chars <= n then
      return s
    end
    local tail = type(opts) == "string" and opts or type(opts) == "table" and opts.ellipsis or "…"
    return table.concat(chars, "", 1, math.max(0, n - utf8.len(tail))) .. tail
  end,
  pad = function(s, n)
    return s .. string.rep(" ", math.max(0, n - utf8.len(s)))
  end,
}
local function read(path)
  local f = assert(io.open(path))
  local s = f:read("a")
  f:close()
  return s
end
local function screen(node, lines, width)
  if node.type == "text" then
    for _, line in ipairs(node.text or {}) do
      local spans = {}
      for _, span in ipairs(line) do
        spans[#spans + 1] = span.text or ""
      end
      local s = table.concat(spans)
      assert(text.width(s) <= width - 2, "overflow: " .. s)
      lines[#lines + 1] = s
    end
  end
  for _, child in ipairs(node.children or {}) do
    screen(child, lines, width)
  end
  return table.concat(lines, "\n")
end
-- A narrow column wraps a message at word boundaries; read it back unwrapped.
local function contains(s, needle)
  local flat = s:gsub("%s*\n%s*", " ")
  assert(flat:find(needle, 1, true), "missing " .. needle .. "\n" .. s)
end
local cases = {
  {
    name = "several",
    answer = { state = "done", status = 0, ok = true, stdout = read("tests/fixtures/several.json") },
    want = {
      "Quota",
      "claude",
      "personal",
      "work",
      "codex",
      "cursor",
      "copilot",
      "zai",
      "agy",
      "60%",
      "25%",
      "week",
      "↻ 5d",
      "unavailable",
      "━",
    },
  },
  {
    name = "partial",
    answer = { state = "done", status = 0, stdout = read("tests/fixtures/partial.json") },
    want = { "80%", "unavailable", "binding unavailable", "Opus" },
    wide = { "Opus model week" },
    absent = "60%",
  },
  {
    name = "stale",
    answer = { state = "done", status = 0, ok = true, stdout = read("tests/fixtures/stale.json") },
    want = { "claude", "stale" },
    absent = "60%",
  },
  {
    name = "failed",
    answer = {
      state = "done",
      status = 1,
      ok = false,
      stdout = "",
      stderr = "network error\nretry later",
    },
    want = { "unavailable", "exit 1", "network error" },
    absent = "0%",
  },
  {
    name = "missing",
    answer = {
      state = "done",
      status = 127,
      ok = false,
      stdout = "",
      stderr = "quota-axi: not found",
    },
    want = { "npm install -g quota-axi" },
  },
  {
    name = "invalid",
    answer = { state = "done", status = 0, ok = true, stdout = "{}" },
    want = {
      "unavailable",
    },
  },
  {
    name = "not run",
    answer = { state = "failed", error = "no session  to run it in" },
    want = { "unavailable", "no session" },
  },
  {
    name = "timed out",
    answer = { state = "done", ok = false, stdout = "", timed_out = true },
    want = { "timed out after 30s" },
  },
  {
    name = "truncated",
    answer = { state = "done", status = 0, ok = true, stdout = "{", truncated = true },
    want = { "output truncated" },
  },
  -- quota-axi reads this machine's accounts, so it must run in a local session
  -- even while a remote one is selected.
  {
    name = "remote selected",
    remote = true,
    answer = { state = "done", status = 0, ok = true, stdout = read("tests/fixtures/several.json") },
    want = { "60%" },
  },
  {
    name = "only remote",
    remote = true,
    only_remote = true,
    want = { "needs a local session" },
    asks = 0,
  },
  { name = "pending", want = { "loading" } },
  { name = "cjk", cjk = true, want = { "Name", "loading" } },
  { name = "untrusted", untrusted = true, want = { "trust" } },
}
local function highlighted(node)
  for _, line in ipairs(type(node.text) == "table" and node.text or {}) do
    for _, span in ipairs(line) do
      if
        (span.text or ""):find("week", 1, true)
        and span.style
        and span.style.bold
        and span.style.fg == "accent"
      then
        return true
      end
    end
  end
  for _, child in ipairs(node.children or {}) do
    if highlighted(child) then
      return true
    end
  end
  return false
end
local failures = 0
-- Every narrow width: each window keeps a readable label and every number
-- ends in one column.
for width = 19, 36 do
  store = { selected = "demo" }
  thurbox = {
    taken_at_ms = 1791374400000,
    sessions = { { id = "demo", name = "demo", agent = "codex", status = "idle", cwd = "/w" } },
    registry = { settings = {} },
    theme = { roles = {} },
    metrics = {},
    runs = { quota = cases[1].answer },
  }
  run = function() end
  local ok, err = pcall(function()
    local s = screen(dofile("info_panel.lua").render({ width = width, height = 80 }), {}, width)
    local column
    for line in s:gmatch("[^\n]+") do
      assert(not line:find("^%s*…"), "label cut to nothing: " .. line)
      local at = line:find("%d%%")
      if at then
        at = utf8.len(line:sub(1, at + 1))
        assert(not column or at == column, "numbers must align: " .. line)
        column = at
      end
    end
    contains(s, "week")
  end)
  if not ok then
    failures = failures + 1
    print("FAIL narrow@" .. width .. ": " .. tostring(err))
  end
end
-- A long automation name gives way to its outcome, and a short agent turn
-- keeps its seconds.
for _, width in ipairs({ 30, 44 }) do
  store = { selected = "demo" }
  thurbox = {
    taken_at_ms = 1791374400000,
    sessions = { { id = "demo", name = "demo", agent = "codex", status = "idle", cwd = "/w" } },
    registry = { settings = {} },
    theme = { roles = {} },
    metrics = {
      sessions = {
        demo = { cpu_percent = 1, agent = { duration_ms = 45000, api_duration_ms = 800 } },
      },
    },
    automations = {
      {
        name = "renovate-dependency-update-weekly",
        schedule = "0 3 * * 1",
        enabled = true,
        last_outcome = "failed",
      },
    },
  }
  run = nil
  local ok, err = pcall(function()
    local s = screen(dofile("info_panel.lua").render({ width = width, height = 80 }), {}, width)
    contains(s, "failed")
    contains(s, "45s")
    contains(s, "800ms")
  end)
  if not ok then
    failures = failures + 1
    print("FAIL automation@" .. width .. ": " .. tostring(err))
  end
end
for _, case in ipairs(cases) do
  for _, width in ipairs({ 28, 44, 80 }) do
    store = { selected = case.remote and "far" or "demo" }
    state = {}
    thurbox = {
      taken_at_ms = 1791374400000,
      sessions = {
        {
          id = "far",
          name = "far",
          agent = "codex",
          status = "idle",
          host = "devbox",
          cwd = "/srv/far",
          repos = {},
        },
        not case.only_remote and {
          id = "demo",
          name = case.cjk and string.rep("界", 25) or "demo",
          agent = "codex",
          status = "idle",
          cwd = "/work/demo",
          repos = {},
        } or nil,
      },
      registry = { settings = {} },
      theme = {
        roles = { accent = "accent", status_idle = "ok", status_working = "warn", danger = "bad" },
      },
      metrics = {},
      runs = { quota = case.answer },
      platform = { os = "linux" },
    }
    local asks = 0
    run = not case.untrusted
        and function(key, cmd, opts)
          assert(key == "quota" and cmd == "quota-axi --json", "portable local command")
          -- Thurbox fails a run with no session before starting it.
          assert(opts.session == "demo", "account quota must run in a local session")
          assert(opts.ttl >= 60 and opts.timeout <= 30)
          asks = asks + 1
        end
      or nil
    command = function() end
    local ok, err = pcall(function()
      local pane = dofile("info_panel.lua")
      local tree = pane.render({ width = width, height = 80 })
      local s = screen(tree, {}, width)
      for _, want in ipairs(case.want) do
        contains(s, want)
      end
      if case.name == "several" then
        if width >= 36 then
          contains(s, "session")
          contains(s, "Opus week")
          contains(s, "80%")
          contains(s, "90%")
          contains(s, "↻ 5d 21h")
        end
        -- Every window of every subscription at every width: Claude's 5h and
        -- week windows each with a number and a reset, model windows too.
        local five_hour, gauges = 0, 0
        for line in s:gmatch("[^\n]+") do
          if line:find("^%s+5h session") and line:find("↻ 3h", 1, true) then
            five_hour = five_hour + 1
          end
          if
            (line:find("━", 1, true) or line:find("─", 1, true))
            and line:find("^%s")
            and line:find("%d%%")
          then
            gauges = gauges + 1
          end
        end
        assert(five_hour == 3, "a 5h row per claude account and codex, got " .. five_hour)
        -- One gauge per measured window, plus System's CPU and RAM when shown.
        assert(gauges == 15, "a gauge for each of the 15 windows, got " .. gauges)
        contains(s, "Opus")
        contains(s, "↻ 5d 21h")
        -- Every number ends in one column, gauge rows and window rows alike.
        local column
        for line in s:gmatch("[^\n]+") do
          local at = line:find("%d%%")
          if at then
            at = utf8.len(line:sub(1, at + 1))
            assert(not column or at == column, "numbers must align across subscriptions")
            column = at
          end
        end
      end
      if case.name == "several" then
        assert(highlighted(tree), "binding label must use theme accent and bold")
      end
      if width >= 36 then
        for _, want in ipairs(case.wide or {}) do
          contains(s, want)
        end
      end
      if case.absent then
        assert(not s:find(case.absent, 1, true), "fake quota value")
      end
      assert(not s:find("kimi", 1, true), "provider not set up must be omitted")
      if case.name == "failed" then
        -- Same exit status, new reason: the cached reading must not keep the old one.
        thurbox.runs.quota =
          { state = "done", status = 1, ok = false, stdout = "", stderr = "credential expired" }
        contains(
          screen(pane.render({ width = width, height = 80 }), {}, width),
          "credential expired"
        )
        thurbox.runs.quota = case.answer
      end
      for _ = 1, 100 do
        pane.render({ width = width, height = 80 })
      end
      assert(asks == 0, "worker requested in frame loop")
      assert(pane.pure == true, "pure render cache is required")
      pane.on_action("info.quota.refresh")
      local want_asks = case.asks or (case.untrusted and 0 or 1)
      assert(asks == want_asks, "refresh action asked " .. asks .. " times, want " .. want_asks)
    end)
    if not ok then
      failures = failures + 1
      print("FAIL " .. case.name .. "@" .. width .. ": " .. tostring(err))
    end
  end
end
assert(failures == 0, failures .. " panel cases failed")
print(#cases * 3 .. " panel cases passed")
