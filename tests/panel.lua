-- Exercise the installed pane against current Thurbox libraries and worker JSON.
local UI = assert(arg[1], "pass a Thurbox ui/ directory")
package.path = UI .. "/?.lua;./?.lua;" .. package.path
package.preload["thurbox-info-panel.lib.quota"] = function()
  return dofile("lib/quota.lua")
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
local function contains(s, needle)
  assert(s:find(needle, 1, true), "missing " .. needle .. "\n" .. s)
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
      "60% left",
      "25%",
      "week",
      "2026-10-12",
      "unavailable",
      "█",
    },
  },
  {
    name = "stale",
    answer = { state = "done", status = 0, ok = true, stdout = read("tests/fixtures/stale.json") },
    want = { "claude", "stale" },
    absent = "60%",
  },
  {
    name = "failed",
    answer = { state = "done", status = 1, ok = false, stdout = "", stderr = "network error" },
    want = { "unavailable" },
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
  { name = "pending", want = { "loading" } },
  { name = "cjk", cjk = true, want = { "Name", "loading" } },
  { name = "untrusted", untrusted = true, want = { "trust" } },
}
local failures = 0
for _, case in ipairs(cases) do
  for _, width in ipairs({ 28, 44, 80 }) do
    store = { selected = "demo" }
    state = {}
    thurbox = {
      taken_at_ms = 1791374400000,
      sessions = {
        {
          id = "demo",
          name = case.cjk and string.rep("界", 25) or "demo",
          agent = "codex",
          status = "idle",
          repos = {},
        },
      },
      registry = { settings = {} },
      theme = { roles = {} },
      metrics = {},
      runs = { quota = case.answer },
      platform = { os = "linux" },
    }
    local asks = 0
    run = not case.untrusted
        and function(key, cmd, opts)
          assert(key == "quota" and cmd == "quota-axi --json", "portable local command")
          assert(opts.session == nil, "account quota must stay local")
          assert(opts.ttl >= 60 and opts.timeout <= 30)
          asks = asks + 1
        end
      or nil
    command = function() end
    local ok, err = pcall(function()
      local pane = dofile("info_panel.lua")
      local s = screen(pane.render({ width = width, height = 80 }), {}, width)
      for _, want in ipairs(case.want) do
        contains(s, want)
      end
      if case.absent then
        assert(not s:find(case.absent, 1, true), "fake quota value")
      end
      assert(not s:find("kimi", 1, true), "provider not set up must be omitted")
      for _ = 1, 100 do
        pane.render({ width = width, height = 80 })
      end
      assert(asks == 0, "worker requested in frame loop")
      assert(pane.pure == true, "pure render cache is required")
      pane.on_action("info.quota.refresh")
      assert(asks == (case.untrusted and 0 or 1), "refresh action did not request the worker")
    end)
    if not ok then
      failures = failures + 1
      print("FAIL " .. case.name .. "@" .. width .. ": " .. tostring(err))
    end
  end
end
assert(failures == 0, failures .. " panel cases failed")
print("24 panel cases passed")
