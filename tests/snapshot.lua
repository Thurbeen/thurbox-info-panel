-- Render snapshots of the quota section for one fixed reading.
--
-- Usage: lua tests/snapshot.lua <thurbox-ui-dir> [--update]
--
-- The section is compared line for line with tests/snapshots/quota-<width>.txt.
-- `--update` rewrites those files instead; review the diff before committing.
local UI = assert(arg[1], "pass a Thurbox ui/ directory")
local UPDATE = arg[2] == "--update"
package.path = UI .. "/?.lua;./?.lua;" .. package.path
package.preload["thurbox-info-panel.lib.quota"] = function()
  return dofile("lib/quota.lua")
end
package.preload["thurbox-info-panel.lib.format"] = function()
  return dofile("lib/format.lua")
end
text = {
  width = function(s)
    return utf8.len(s)
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
  local f = io.open(path)
  if not f then
    return nil
  end
  local s = f:read("a")
  f:close()
  return s
end
local function flatten(node, out)
  if node.type == "text" and type(node.text) == "table" then
    for _, line in ipairs(node.text) do
      local parts = {}
      for _, span in ipairs(line) do
        parts[#parts + 1] = span.text or ""
      end
      out[#out + 1] = table.concat(parts)
    end
  elseif node.type == "text" then
    out[#out + 1] = node.text or ""
  end
  for _, child in ipairs(node.children or {}) do
    flatten(child, out)
  end
  return out
end
--- The rows from the quota heading up to the next section's rule.
local function quota_section(lines)
  local out, inside = {}, false
  for _, line in ipairs(lines) do
    if line:find("^  Quota") then
      inside = true
    elseif inside and line:find("^─") then
      break
    end
    if inside then
      out[#out + 1] = (line:gsub("%s+$", ""))
    end
  end
  while out[#out] == "" do
    out[#out] = nil
  end
  return table.concat(out, "\n") .. "\n"
end
local failures = 0
for _, width in ipairs({ 50, 30 }) do
  store = { selected = "demo" }
  thurbox = {
    -- 2026-10-07T12:00:00Z: three minutes after the fixture was generated.
    taken_at_ms = 1791374400000,
    sessions = { { id = "demo", name = "demo", agent = "codex", status = "idle", cwd = "/w" } },
    registry = { settings = {} },
    theme = { roles = {} },
    metrics = {},
    runs = {
      quota = { state = "done", status = 0, stdout = read("tests/fixtures/display.json") },
    },
  }
  run = function() end
  command = function() end
  local pane = dofile("info_panel.lua")
  local got = quota_section(flatten(pane.render({ width = width, height = 80 }), {}))
  local path = "tests/snapshots/quota-" .. width .. ".txt"
  if UPDATE then
    local f = assert(io.open(path, "w"))
    f:write(got)
    f:close()
    print("wrote " .. path)
  elseif got ~= read(path) then
    failures = failures + 1
    print("FAIL " .. path .. " differs; got:\n" .. got)
  end
end
assert(failures == 0, failures .. " quota snapshots differ")
if not UPDATE then
  print("Quota snapshots match")
end
