local UI = assert(arg[1], "pass a Thurbox ui/ directory")
state = {}
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
    return utf8.len(s) <= n and s or s:sub(1, utf8.offset(s, n) - 1) .. "…"
  end,
  pad = function(s, n)
    return s .. string.rep(" ", math.max(0, n - utf8.len(s)))
  end,
}
local function flatten(node, out)
  if node.type == "text" and type(node.text) == "table" then
    for _, line in ipairs(node.text) do
      local parts = {}
      for _, span in ipairs(line) do
        parts[#parts + 1] = span.text or ""
      end
      out[#out + 1] = table.concat(parts)
    end
  end
  for _, child in ipairs(node.children or {}) do
    flatten(child, out)
  end
  return out
end
local LOCAL_PLACES = {
  { name = "local", detail = "this machine (mux)", backend = "", here = true },
  { name = "herdr/local", detail = "this machine (herdr)", backend = "herdr/local", here = true },
  { name = "mux/devbox", detail = "a mux place", backend = "mux/devbox", here = false },
}
local cases = {
  { name = "default runtime", place = "local", want = "this machine (mux)" },
  { name = "another runtime here", place = "herdr/local", want = "this machine (herdr)" },
  { name = "a place elsewhere", place = "mux/devbox", host = "mux/devbox", want = "a mux place" },
  { name = "places not answered yet", place = "herdr/local", places = false, want = "herdr/local" },
  {
    name = "a remote Fleet's place",
    place = "herdr/local",
    fleet = "box",
    host = "box",
    fleets = {
      { name = "box", places = { { name = "herdr/local", detail = "box itself (herdr)" } } },
    },
    want = "box itself (herdr)",
  },
  {
    name = "a remote Fleet that has not answered",
    place = "local",
    fleet = "box",
    host = "box",
    fleets = { { name = "local", places = LOCAL_PLACES }, { name = "box" } },
    want = "Runtime: local",
  },
  { name = "a Thurbox without place", place = nil, want = nil },
}
local failures = 0
for _, case in ipairs(cases) do
  for _, width in ipairs({ 28, 44 }) do
    store = { selected = "demo" }
    state = {}
    thurbox = {
      taken_at_ms = 1791374400000,
      sessions = {
        {
          id = "demo",
          name = "demo",
          agent = "codex",
          status = "idle",
          cwd = "/w",
          fleet = case.fleet or "local",
          host = case.host,
          place = case.place,
          repos = {},
        },
      },
      hosts = case.places ~= false and LOCAL_PLACES or nil,
      fleets = case.fleets
        or { { name = "local", places = case.places ~= false and LOCAL_PLACES or nil } },
      registry = { settings = {} },
      theme = { roles = {} },
      metrics = {},
      runs = {},
    }
    run = function() end
    command = function() end
    local lines = flatten(dofile("info_panel.lua").render({ width = width, height = 80 }), {})
    local all = table.concat(lines, " "):gsub("%s+", " ")
    local ok
    if case.want then
      ok = all:find("Runtime", 1, true) and all:find(case.want, 1, true)
    else
      ok = not all:find("Runtime", 1, true)
    end
    if not ok then
      failures = failures + 1
      print(("FAIL %s@%d: want %s, got:\n%s"):format(case.name, width, tostring(case.want), all))
    end
  end
end
assert(failures == 0, failures .. " runtime cases failed")
print("Runtime rows match")
