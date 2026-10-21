-- Tens of hosts, mixed online/offline/slow/auth/stale, through the real pane.
-- No transport: answers are injected into the snapshot the kernel would own.
local UI = assert(arg[1], "pass a Thurbox ui/ directory")
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
local function flatten(node, lines, width)
  if node.type == "text" and type(node.text) == "string" then
    lines[#lines + 1] = node.text
  elseif node.type == "text" then
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
  for _, child in ipairs(node.children or {}) do
    flatten(child, lines, width)
  end
end
local host_quota = require("thurbox-info-panel.lib.host_quota")
local f = assert(io.open("tests/fixtures/several.json"))
local report = f:read("a")
f:close()
local now = 1791374400
local function done(stdout, status)
  return { state = "done", status = status or 0, stdout = stdout }
end
local auth_report = report:gsub('"status": "fresh"', '"status": "auth_required"')
local stale_report = report:gsub("2026%-10%-07T12:00:00Z", "2026-10-07T09:00:00Z")

-- Each kind of host, and what its title line must say. `cached` hosts answered
-- once and then went offline: their last reading stays, with its age.
local KINDS = {
  { kind = "ok", state = "ok", answer = done(report) },
  {
    kind = "down",
    state = "offline",
    answer = { state = "failed", error = "ssh: connect timed out" },
  },
  { kind = "unreachable", state = "offline", answer = done("", 255) },
  { kind = "slow", state = "offline", answer = { state = "done", status = 1, timed_out = true } },
  { kind = "pending", state = "checking", answer = { state = "pending" } },
  { kind = "auth", state = "auth needed", answer = done(auth_report) },
  {
    kind = "login",
    state = "auth needed",
    answer = done('error: "not logged in: run claude login"', 1),
  },
  { kind = "old", state = "stale · 3h old", answer = done(stale_report) },
  { kind = "bare", state = "no quota-axi", answer = { state = "done", status = 127 } },
  { kind = "broken", state = "error", answer = done("{broken") },
}
local N = 40
local configured, runs, expect = {}, {}, {}
for i = 1, N do
  local spec = KINDS[(i - 1) % #KINDS + 1]
  local name = string.format("%s-%02d", spec.kind, i)
  configured[i] = { name = name, platform = "posix" }
  runs[host_quota.key(name)] = spec.answer
  expect[name] = spec.state
end
runs.quota = done(report)

-- Model: every host classified on its own, whatever its neighbours do.
local model = host_quota.new()
local groups = model:read(configured, runs, now, true)
assert(#groups == N, "every configured host must be read, got " .. #groups)
for _, group in ipairs(groups) do
  assert(
    group.state == expect[group.host.name],
    group.host.name .. " read as " .. tostring(group.state)
  )
end

-- Per-host cache: a host that answered keeps that reading when it drops off,
-- marked offline with the reading's age, and its neighbours are unaffected.
local cached = host_quota.new()
cached:read({ { name = "flaky" }, { name = "steady" } }, {
  [host_quota.key("flaky")] = done(report),
  [host_quota.key("steady")] = done(report),
}, now, true)
local later = cached:read({ { name = "flaky" }, { name = "steady" } }, {
  [host_quota.key("flaky")] = { state = "failed", error = "ssh: connect timed out" },
  [host_quota.key("steady")] = done(report),
}, now + 720, true)
assert(later[1].state == "offline · 12m old", "cached host state: " .. tostring(later[1].state))
assert(later[1].drawn.status == "ready", "a cached reading must still be drawn")
assert(not later[2].state:find("offline", 1, true), "a neighbour inherited the drop")
-- The cache follows hosts.toml: a removed host's reading is gone.
cached:read({ { name = "steady" } }, {}, now, true)
local back = cached:read({ { name = "flaky" } }, {
  [host_quota.key("flaky")] = { state = "failed", error = "down" },
}, now, true)
assert(back[1].state == "offline" and back[1].drawn.status ~= "ready", "removed host was kept")
print("Host states passed: " .. N .. " mixed hosts, per-host cache with age")

-- Pane: one request per host with a per-host timeout, then every host and its
-- state reachable by scrolling, with non-ok hosts kept to a compact block.
state, store = {}, {}
thurbox = {
  taken_at_ms = now * 1000,
  sessions = {},
  hosts = configured,
  runs = {},
  registry = { settings = {} },
  theme = { roles = {} },
  metrics = {},
  platform = { os = "linux" },
}
local asked = {}
run = function(key, _, opts)
  assert(opts.timeout and opts.timeout <= 30, "each host needs its own bounded timeout")
  asked[#asked + 1] = key
end
run_forget = function() end
command = function() end
local pane = dofile("info_panel.lua")
pane.on_action("info.quota.refresh")
assert(#asked == N + 1, "expected one ask per host plus local, got " .. #asked)
thurbox.runs = runs
for _, width in ipairs({ 28, 44 }) do
  state = {}
  local lines = {}
  flatten(pane.render({ width = width, height = 10000 }), lines, width)
  local body = table.concat(lines, "\n")
  for name, want in pairs(expect) do
    local title
    for _, line in ipairs(lines) do
      if line:find(name, 1, true) then
        title = line
        break
      end
    end
    assert(title, name .. " missing at width " .. width)
    -- The state may be shortened at 28 columns, never dropped.
    local short = want:sub(1, 6)
    assert(title:find(short, 1, true), name .. " title lacks its state: " .. title)
  end
  -- Compact: an offline host is its title and one reason line.
  for i, line in ipairs(lines) do
    if line:find("down-02", 1, true) then
      assert(lines[i + 2]:find("unreachable-03", 1, true), "offline host took more than two lines")
    end
  end
  assert(body:find("80%", 1, true), "healthy hosts lost their gauges")
end

-- The same panel at a normal height is scrolled, never paged or cropped.
state = {}
local seen = {}
for _ = 1, 3000 do
  local lines = {}
  flatten(pane.render({ width = 44, height = 30 }), lines, 44)
  for _, line in ipairs(lines) do
    seen[#seen + 1] = line
  end
  pane.on_scroll({ up = false })
end
local all = table.concat(seen, "\n")
for name in pairs(expect) do
  assert(all:find(name, 1, true), name .. " not reachable by scrolling")
end
print("Many-host panel passed: " .. N .. " hosts, per-host asks, states, compact, scrolling")
