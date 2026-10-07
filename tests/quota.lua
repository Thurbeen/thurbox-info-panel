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
-- The instants the display counts down to and ages from, as epoch seconds.
assert(model.rows[1].bindings[1].resets_at == 1791806400)
assert(model.generated_at == now)
-- An explicit offset is the same instant; a reset given only as text is kept.
local offsets =
  [[{"schemaVersion":6,"generatedAt":"2026-10-07T14:00:00+02:00","providers":[{"provider":"codex","state":{"status":"fresh"},"windows":[{"id":"a","percentRemaining":5,"resetsAt":"2026-10-07T12:30:00-01:30"},{"id":"b","percentRemaining":5,"resetText":"in 3 hours"}]}]}]]
local o = q.parse({ state = "done", status = 0, stdout = offsets }, now)
assert(o.generated_at == now, "offset generatedAt")
assert(o.rows[1].windows[1].resets_at == now + 2 * 3600, "offset resetsAt")
assert(o.rows[1].windows[2].resets_at == nil and o.rows[1].windows[2].reset == "in 3 hours")
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
-- Every way a run can fail says why, rather than a bare "unavailable".
local function reason(answer)
  local r = q.parse(answer, now, 30)
  assert(r.status == "unavailable", "want unavailable, got " .. tostring(r.status))
  return r.reason
end
assert(
  reason({ state = "failed", error = "no session  to run it in" }) == "no session to run it in"
)
assert(reason({ state = "done", stdout = "", timed_out = true }) == "timed out after 30s")
assert(reason({ state = "done", status = 0, stdout = "{", truncated = true }) == "output truncated")
assert(reason({ state = "done", stdout = "" }) == "killed by a signal")
assert(
  reason({ state = "done", status = 2, stdout = "", stderr = "\n  bad flag --json\nusage" })
    == "exit 2: bad flag --json"
)
assert(reason({ state = "done", status = 3, stdout = "", stderr = "" }) == "exit 3")
-- quota-axi reports its own errors on stdout, in TOON.
assert(reason({
  state = "done",
  status = 2,
  stdout = 'error: "unknown argument: --bogus"\ncode: VALIDATION_ERROR\n',
  stderr = "",
}) == "exit 2: unknown argument: --bogus")
-- Terminal escapes are dropped and a long line is cut.
assert(
  reason({ state = "done", status = 1, stdout = "", stderr = "\27[31mError:\27[0m boom\n" })
    == "exit 1: Error: boom"
)
-- quota-axi's own error wins over runtime noise on stderr, and an escape-only
-- line is no reason at all.
assert(reason({
  state = "done",
  status = 1,
  stdout = 'error: "bad token"\n',
  stderr = "(node:42) ExperimentalWarning: Fetch API\n",
}) == "exit 1: bad token")
assert(reason({ state = "done", status = 1, stdout = "x\n", stderr = "\27[0m\n" }) == "exit 1: x")
assert(
  reason({ state = "done", status = 1, stdout = "", stderr = "\27]0;t\7a\tb \27[38:5:1mc" })
    == "exit 1: a b c"
)
local long = reason({ state = "done", status = 1, stdout = "", stderr = string.rep("x", 5000) })
assert(#long <= 128, "reason must be bounded, got " .. #long)
assert(reason({ state = "done", status = 0, stdout = "{broken" }):find("^unreadable output"))
assert(
  reason({ state = "done", status = 0, stdout = [[{"schemaVersion":4,"providers":[]}]] })
    == "unsupported schemaVersion 4"
)
assert(q.parse({ state = "done", status = 127, stdout = "" }, now).status == "missing")
print("Quota contract tests passed")
