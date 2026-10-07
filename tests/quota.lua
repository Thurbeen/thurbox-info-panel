-- Pin the quota-axi 0.1.58 normalized contract, including uncertain scopes.
local q = dofile("lib/quota.lua")
local function read(path)
  local f = assert(io.open(path))
  local s = f:read("a")
  f:close()
  return s
end
local response = { state = "done", status = 0, stdout = read("tests/fixtures/several.json") }
local now = 1791374400
local model = q.parse(response, now)
assert(#model.rows == 8, "one group per subscription")
assert(#model.rows[1].windows == 3, "all subscription windows must be preserved")
assert(model.rows[1].windows[1].remaining == 80)
assert(model.rows[1].windows[2].binding == true)
assert(model.rows[1].windows[3].remaining == 90 and not model.rows[1].windows[3].binding)
assert(model.rows[1].windows[2].remaining == 60 and model.rows[2].windows[2].remaining == 25)
assert(model.rows[1].bindings[1].reset == "2026-10-12T12:00:00Z")
assert(q.parse(response, now + 301).rows[1].status == "stale")
assert(
  q.parse({ state = "done", status = 0, stdout = response.stdout, truncated = true }, now).status
    == "unavailable"
)
assert(q.parse({ state = "done", status = 0, stdout = "{broken" }, now).status == "unavailable")
local unknown =
  [[{"schemaVersion":5,"generatedAt":"2026-10-07T12:00:00Z","providers":[{"provider":"future-provider","accountKeys":["default"],"state":{"status":"fresh"},"windows":[{"id":"credits","percentRemaining":90}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}]]
local u = q.parse({ state = "done", status = 0, stdout = unknown }, now).rows[1]
assert(u.windows[1].remaining == 90 and #u.bindings == 0)
local partial =
  q.parse({ state = "done", status = 0, stdout = read("tests/fixtures/partial.json") }, now).rows[1]
assert(partial.windows[1].remaining == 80)
assert(partial.windows[2].remaining == nil and partial.windows[3].remaining == nil)
assert(#partial.bindings == 0)
local stale = q.parse(response, now + 301).rows[1]
for _, window in ipairs(stale.windows) do
  assert(window.remaining == nil and window.status == "stale")
end
local malformed =
  [[{"schemaVersion":6,"generatedAt":"2026-10-07T12:00:00Z","providers":[{"provider":"codex","state":3}]}]]
assert(
  q.parse({ state = "done", status = 0, stdout = malformed }, now).rows[1].status == "unavailable"
)
local zero =
  [[{"schemaVersion":6,"generatedAt":"2026-10-07T12:00:00Z","providers":[{"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"session","label":"session","percentRemaining":0,"resetsAt":"2026-10-07T16:00:00Z"},{"id":"weekly","label":"week","percentRemaining":0,"resetsAt":"2026-10-12T12:00:00Z"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["session","weekly"],"limitingWindowIds":["session","weekly"]}]}}]}]]
local z = q.parse({ state = "done", status = 0, stdout = zero }, now).rows[1]
assert(
  z.windows[1].remaining == 0
    and z.windows[2].remaining == 0
    and #z.bindings == 2
    and z.bindings[1].reset ~= z.bindings[2].reset
)
assert(
  q.parse({ state = "done", status = 1, stderr = "credential file not found" }, now).status
    == "unavailable"
)
print("Quota contract tests passed")
