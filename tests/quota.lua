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
assert(#model.rows == 8)
assert(model.rows[1].remaining == 60 and model.rows[2].remaining == 25)
assert(model.rows[1].bindings[1].reset == "2026-10-12T12:00:00Z")
assert(q.parse(response, now + 301).rows[1].status == "stale")
assert(
  q.parse({ state = "done", status = 0, stdout = response.stdout, truncated = true }, now).status
    == "unavailable"
)
assert(q.parse({ state = "done", status = 0, stdout = "{broken" }, now).status == "unavailable")
local unknown =
  [[{"schemaVersion":5,"generatedAt":"2026-10-07T12:00:00Z","providers":[{"provider":"future-provider","accountKeys":["default"],"state":{"status":"fresh"},"windows":[{"id":"credits","percentRemaining":90}],"quotaSemantics":{"status":"unknown","effectiveAvailability":[]}}]}]]
assert(q.parse({ state = "done", status = 0, stdout = unknown }, now).rows[1].remaining == nil)
local malformed =
  [[{"schemaVersion":6,"generatedAt":"2026-10-07T12:00:00Z","providers":[{"provider":"codex","state":3}]}]]
assert(
  q.parse({ state = "done", status = 0, stdout = malformed }, now).rows[1].status == "unavailable"
)
local zero =
  [[{"schemaVersion":6,"generatedAt":"2026-10-07T12:00:00Z","providers":[{"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"session","label":"session","resetsAt":"2026-10-07T16:00:00Z"},{"id":"weekly","label":"week","resetsAt":"2026-10-12T12:00:00Z"}],"quotaSemantics":{"effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":0,"boundedBy":["session","weekly"],"limitingWindowIds":["session","weekly"]}]}}]}]]
local z = q.parse({ state = "done", status = 0, stdout = zero }, now).rows[1]
assert(z.remaining == 0 and #z.bindings == 2 and z.bindings[1].reset ~= z.bindings[2].reset)
print("Quota contract tests passed")
