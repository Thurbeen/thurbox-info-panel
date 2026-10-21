-- Host data is consumed independently of session selection and transport.
for _, name in ipairs({ "quota", "format" }) do
  package.preload["thurbox-info-panel.lib." .. name] = function()
    return dofile("lib/" .. name .. ".lua")
  end
end
local host_quota = dofile("lib/host_quota.lua")
local f = assert(io.open("tests/fixtures/several.json"))
local report = f:read("a")
f:close()
local function answer(stdout)
  return { state = "done", status = 0, stdout = stdout }
end
local model = host_quota.new()
local hosts = {
  { name = "alpha", platform = "posix" },
  { name = "beta", platform = "windows" },
  { name = "offline", platform = "posix" },
}
local runs = {
  [host_quota.key("alpha")] = answer(report),
  [host_quota.key("beta")] = answer("{broken"),
  [host_quota.key("offline")] = { state = "done", timed_out = true, status = 1 },
}
local now = 1791374400
local groups = model:read(hosts, runs, now, true)
assert(#groups == 3)
assert(groups[1].reading.status == "ready", "healthy host must survive peer failures")
assert(groups[2].reading.status == "unavailable", "malformed report is unknown, not zero")
assert(groups[3].reading.reason:find("timed out", 1, true))
local accounts, windows = {}, {}
for _, row in ipairs(groups[1].reading.rows) do
  accounts[row.provider .. ":" .. row.account] = true
  for _, window in ipairs(row.windows) do
    windows[window.label] = true
  end
end
assert(accounts["claude:personal"] and accounts["claude:work"])
assert(windows["5h session"] and windows["Opus week"])
assert(host_quota.new():read(hosts, {}, now, true)[1].reading.status == "loading")
assert(model:read(hosts, runs, now, false)[1].reading.status == "untrusted")
runs[host_quota.key("beta")] = { state = "done", status = 127 }
assert(model:read(hosts, runs, now, true)[2].reading.status == "missing")
local stale = model:read(hosts, runs, now + 3600, true)[1].reading
for _, row in ipairs(stale.rows) do
  assert(row.status == "stale")
  for _, window in ipairs(row.windows) do
    assert(window.remaining == nil, "stale is never fresh capacity")
  end
end
-- Both bounds are tested with reports that would otherwise decode as ready, so
-- removing either check is caught rather than masked by a parse failure.
runs[host_quota.key("alpha")] = answer(report)
assert(model:read(hosts, runs, now, true)[1].reading.status == "ready")
runs[host_quota.key("alpha")] = answer(report .. string.rep(" ", 131073 - #report))
assert(
  model:read(hosts, runs, now, true)[1].reading.reason == "quota output exceeds safety limits",
  "an oversized report was decoded"
)
local deep = report:gsub("^%s*{", '{"pad":' .. string.rep("[", 40) .. string.rep("]", 40) .. ",", 1)
runs[host_quota.key("alpha")] = answer(deep)
assert(
  model:read(hosts, runs, now, true)[1].reading.reason == "quota output exceeds safety limits",
  "a deeply nested report was decoded"
)
-- Reports that exceed render budgets are rejected as a whole, never pooled
-- or silently shortened into a misleading subset of accounts/windows.
local provider = '{"provider":"codex","state":{"status":"fresh"},"windows":[]}'
local many = '{"schemaVersion":6,"generatedAt":"2026-10-07T12:00:00Z","providers":['
  .. string.rep(provider .. ",", 32)
  .. provider
  .. "]}"
runs[host_quota.key("alpha")] = answer(many)
assert(model:read(hosts, runs, now, true)[1].reading.reason == "too many quota accounts")
local window = '{"label":"week","percentRemaining":50}'
local many_windows = '{"schemaVersion":6,"generatedAt":"2026-10-07T12:00:00Z","providers":['
  .. '{"provider":"codex","state":{"status":"fresh"},"windows":['
  .. string.rep(window .. ",", 32)
  .. window
  .. "]}]}"
runs[host_quota.key("alpha")] = answer(many_windows)
assert(model:read(hosts, runs, now, true)[1].reading.reason == "too many quota windows")
-- Churn must not retain a report/history per past host.
collectgarbage("collect")
local baseline = collectgarbage("count")
for i = 1, 1000 do
  model:read({ { name = "replaced-" .. i } }, {}, now, true)
end
collectgarbage("collect")
assert(collectgarbage("count") < baseline + 64, "host churn retained plugin memory")
assert(#model:read({}, runs, now, true) == 0, "removed hosts must discard obsolete readings")
print("Host quota fixtures passed: identity, failures, stale data, memory")

-- Handler-side reconciliation retires only removed host keys. A quota report
-- already carries every provider/account, so there are no per-refresh keys.
local lifecycle = host_quota.new()
local retained, forgotten = {}, 0
local function forget(key)
  assert(retained[key], "retired the same key more than once")
  retained[key] = nil
  forgotten = forgotten + 1
end
for i = 1, 2000 do
  local configured = { { name = "persistent" }, { name = "rotating-" .. i } }
  lifecycle:reconcile(configured, forget)
  for _, host in ipairs(configured) do
    retained[host_quota.key(host.name)] = true
  end
  -- Re-reading the same set must not retire anything or create a history.
  lifecycle:reconcile(configured, forget)
  local count = 0
  for _ in pairs(retained) do
    count = count + 1
  end
  assert(count == 2, "retained state grew beyond configured hosts")
  local desired_count = 0
  for _ in pairs(lifecycle.desired) do
    desired_count = desired_count + 1
  end
  assert(desired_count == 2, "consumer retained a retired host key")
end
lifecycle:reconcile({}, forget)
assert(next(retained) == nil and forgotten == 2001)
lifecycle:reconcile({}, forget)
-- A different plugin's keyspace is not passed to the forgetting callback.
lifecycle:reconcile({ { name = "replacement" } }, function()
  error("a retired key survived empty reconciliation")
end)
print("Host key reconciliation passed: repeated churn, retirement and bounded desired state")

-- VM rebuilds lose the private desired map while the surviving plugin path
-- can still own answers/queued asks in the kernel snapshot.
local snapshot = {
  quota = { state = "done", status = 0 },
  unrelated = { state = "pending" },
  [host_quota.key("keep")] = { state = "done", status = 0 },
  [host_quota.key("retired-done")] = { state = "done", status = 0 },
  [host_quota.key("retired-failed")] = { state = "failed", error = "offline" },
  [host_quota.key("retired-pending")] = { state = "pending" },
  [host_quota.key("retired-queued")] = { state = "pending" },
}
local after_reset = host_quota.new()
local retired_count = 0
local function retire_snapshot(key)
  assert(snapshot[key], "forgot a key twice during snapshot reconciliation")
  snapshot[key] = nil
  retired_count = retired_count + 1
end
after_reset:reconcile({ { name = "keep" } }, retire_snapshot, snapshot)
assert(retired_count == 4, "VM reset leaked obsolete cached/pending/queued host keys")
assert(snapshot.quota and snapshot.unrelated, "host cleanup removed another pane command")
assert(snapshot[host_quota.key("keep")], "host cleanup removed a desired answer")
after_reset:reconcile({ { name = "keep" } }, retire_snapshot, snapshot)
assert(retired_count == 4, "repeated snapshot reconciliation was not idempotent")
-- A key may exist in both private state and the published snapshot.
after_reset:reconcile({}, retire_snapshot, snapshot)
assert(retired_count == 5, "private and snapshot keys were not deduplicated")
for i = 1, 500 do
  snapshot[host_quota.key("obsolete-" .. i)] = { state = "pending" }
  after_reset = host_quota.new()
  after_reset:reconcile({}, retire_snapshot, snapshot)
  assert(next(after_reset.desired) == nil, "reset retained a history of retired keys")
end
assert(retired_count == 505 and snapshot.quota and snapshot.unrelated)
local remaining = 0
for _ in pairs(snapshot) do
  remaining = remaining + 1
end
assert(remaining == 2, "repeated reloads grew retained own snapshot keys")
print(
  "Host reload reconciliation passed: surviving snapshot, obsolete keys and repeated state loss"
)

-- Identical snapshot content may arrive in newly allocated answer tables.
-- Re-decoding on every refresh defeats the cache even though no data moved.
local decoder = require("thurbox-info-panel.lib.quota")
local real_decode, decodes = decoder.decode, 0
decoder.decode = function(...)
  decodes = decodes + 1
  return real_decode(...)
end
local snapshots = host_quota.new()
for _ = 1, 100 do
  snapshots:read(
    { { name = "stable" } },
    { [host_quota.key("stable")] = answer(report) },
    now,
    true
  )
end
assert(decodes == 1, "identical snapshots repeatedly decoded the same report")
local mutable = answer(report)
snapshots:read({ { name = "stable" } }, { [host_quota.key("stable")] = mutable }, now, true)
mutable.status, mutable.stderr = 1, "credential expired"
local changed = snapshots:read(
  { { name = "stable" } },
  { [host_quota.key("stable")] = mutable },
  now,
  true
)
assert(
  changed[1].reading.status == "unavailable",
  "changed answer fields kept a cached fresh reading"
)
decoder.decode = real_decode
print("Host answer cache passed: identical snapshot reuse and changed-result invalidation")
