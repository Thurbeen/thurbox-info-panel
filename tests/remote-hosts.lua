-- Regression: configured hosts must be visible independently of session sharing.
-- Uses the real pane and installed interface libraries; no provider/network access.
local UI = assert(arg[1], "pass a Thurbox ui/ directory")
local PANE = arg[2] or "info_panel.lua"
package.path = UI .. "/?.lua;./?.lua;" .. package.path
for _, name in ipairs({ "quota", "format" }) do
  package.preload["thurbox-info-panel.lib." .. name] = function()
    return dofile("lib/" .. name .. ".lua")
  end
end
package.preload["thurbox-info-panel.lib.host_quota"] = function()
  return dofile("lib/host_quota.lua")
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
local function flatten(node, lines, width)
  if node.type == "text" then
    if type(node.text) == "string" then
      lines[#lines + 1] = node.text
    else
      for _, line in ipairs(node.text or {}) do
        local parts = {}
        for _, span in ipairs(line) do
          parts[#parts + 1] = span.text or ""
        end
        local value = table.concat(parts)
        assert(text.width(value) <= width - 2, "row exceeds panel width")
        lines[#lines + 1] = value
      end
    end
  end
  for _, child in ipairs(node.children or {}) do
    flatten(child, lines, width)
  end
end
local fixture = assert(io.open("tests/fixtures/several.json"))
local report = fixture:read("a")
fixture:close()
for _, width in ipairs({ 28, 44, 80 }) do
  store = { selected = "local-session" }
  state = {}
  thurbox = {
    taken_at_ms = 1791374400000,
    sessions = {
      { id = "local-session", name = "local", status = "idle", cwd = "/work" },
      { id = "remote-session", name = "remote", host = "remote-active", cwd = "/work" },
    },
    -- Both a host with a session and hosts without any session must be listed.
    -- Session sharing is deliberately irrelevant to the configured host list.
    hosts = {
      { name = "remote-active", backend = "ssh:remote-active", platform = "posix" },
      { name = "remote-private", backend = "ssh:remote-private", platform = "windows" },
      { name = "remote-offline", backend = "ssh:remote-offline", platform = "posix" },
    },
    registry = { settings = {} },
    theme = { roles = {} },
    metrics = {},
    platform = { os = "linux" },
    runs = { quota = { state = "done", status = 0, stdout = report } },
  }
  local requests = 0
  run = function()
    requests = requests + 1
  end
  command = function() end
  local pane = dofile(PANE)
  local lines = {}
  flatten(pane.render({ width = width, height = 80 }), lines, width)
  local rendered = table.concat(lines, "\n")
  assert(rendered:find("codex", 1, true), "local quotas must be retained")
  assert(requests == 0, "render must never request work")
  for _, host in ipairs(thurbox.hosts) do
    assert(
      rendered:find(host.name, 1, true),
      "configured host missing from quota panel: " .. host.name .. " at width " .. width
    )
  end
end
print("Configured remote hosts appear at all panel widths")

-- Old cores must report a missing API honestly, even if a report with the
-- plugin's future remote key happens to be present in the snapshot.
run_forget = nil
thurbox.hosts = { { name = "unsupported", platform = "posix" } }
thurbox.runs["quota.host:unsupported"] = thurbox.runs.quota
state = {}
local unsupported_lines = {}
flatten(dofile(PANE).render({ width = 80, height = 200 }), unsupported_lines, 80)
local unsupported = table.concat(unsupported_lines, "\n")
assert(unsupported:find("host quota API unavailable", 1, true), "missing core API looked available")
assert(not unsupported:find("loading", 1, true), "unsupported API pretended to fetch")
run_forget = function()
  error("render must never forget work")
end

-- Drive the actual pane's viewport with a healthy remote, stale cache,
-- missing tool, malformed report and timeout, without invoking any transport.
local host_quota = require("thurbox-info-panel.lib.host_quota")
for _, width in ipairs({ 28, 44, 80 }) do
  state = {}
  store = {}
  local function done(stdout)
    return { state = "done", status = 0, stdout = stdout }
  end
  local hosts = {
    { name = "healthy", platform = "posix" },
    { name = "offline", platform = "windows" },
    { name = "missing", platform = "posix" },
    { name = "malformed", platform = "posix" },
    { name = "stale", platform = "posix" },
  }
  local stale = assert(io.open("tests/fixtures/stale.json"))
  local stale_report = stale:read("a")
  stale:close()
  thurbox = {
    taken_at_ms = 1791374400000,
    sessions = {},
    hosts = hosts,
    registry = { settings = {} },
    theme = { roles = {} },
    metrics = {},
    runs = {
      quota = done(report),
      [host_quota.key("healthy")] = done(report),
      [host_quota.key("offline")] = { state = "done", status = 1, timed_out = true },
      [host_quota.key("missing")] = { state = "done", status = 127 },
      [host_quota.key("malformed")] = done("{broken"),
      [host_quota.key("stale")] = done(stale_report),
    },
  }
  run = function()
    error("viewport operations must not ask for work")
  end
  local pane = dofile(PANE)
  local captured = {}
  for _ = 1, 2 do
    for _ = 1, 100 do
      local lines = {}
      flatten(pane.render({ width = width, height = 14 }), lines, width)
      assert(#lines <= 13, "viewport built more lines than its height")
      captured[#captured + 1] = table.concat(lines, "\n")
      pane.on_scroll({ up = false })
    end
    pane.on_action("info.quota.next")
  end
  -- Repeated downward wheel ticks at the bottom must not accumulate overshoot.
  for _ = 1, 200 do
    pane.on_scroll({ up = false })
    pane.render({ width = width, height = 14 })
  end
  local bottom = {}
  flatten(pane.render({ width = width, height = 14 }), bottom, width)
  pane.on_scroll({ up = true })
  local above = {}
  flatten(pane.render({ width = width, height = 14 }), above, width)
  assert(
    table.concat(bottom, "\n") ~= table.concat(above, "\n"),
    "scroll stuck after bottom overshoot"
  )
  local all = table.concat(captured, "\n"):gsub("%s*\n%s*", " ")
  for _, want in ipairs({
    "healthy",
    "offline",
    "missing",
    "malformed",
    "stale",
    "timed out",
    "unreadable",
    "npm install -g quota-axi",
    "personal",
    "work",
    "Opus",
    "80%",
    "90%",
    "↻ 3h",
  }) do
    assert(all:find(want, 1, true), "scrolled quota panel missing " .. want)
  end
  assert(not all:find("0% left", 1, true), "unknown host capacity became zero")
  -- Local and remote reports retain separate provider/account lanes.
  local _, count = all:gsub("claude", "")
  assert(count > 1, "provider identity was collapsed across hosts")
  assert(pane.pure == true)
end
print("Remote quota viewport fixtures passed: narrow scrolling, accounts, failures and stale cache")
