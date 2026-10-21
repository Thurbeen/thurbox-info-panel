-- Transport-independent host quota model. Execution remains the kernel's job.
local quota = require("thurbox-info-panel.lib.quota")
local format = require("thurbox-info-panel.lib.format")
local hosts = {}
local KEY_PREFIX = "quota.host:"
local MAX_OUTPUT = 131072
local MAX_ROWS, MAX_WINDOWS = 32, 32
local RESULT_FIELDS = { "state", "status", "stdout", "stderr", "error", "timed_out", "truncated" }

local function same_answer(fields, answer)
  for _, name in ipairs(RESULT_FIELDS) do
    if fields[name] ~= (answer and answer[name]) then
      return false
    end
  end
  return true
end

local function answer_fields(answer)
  local fields = {}
  for _, name in ipairs(RESULT_FIELDS) do
    fields[name] = answer and answer[name]
  end
  return fields
end

-- A distinct stable namespace from the existing local `quota` answer.
function hosts.key(name)
  return KEY_PREFIX .. name
end

-- Reject oversized or deeply nested output before invoking the JSON decoder.
-- Brackets inside JSON strings do not contribute to nesting depth.
local function bounded(output)
  if type(output) ~= "string" or #output > MAX_OUTPUT then
    return false
  end
  local depth, quoted, escaped = 0, false, false
  for i = 1, #output do
    local char = output:sub(i, i)
    if quoted then
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == '"' then
        quoted = false
      end
    elseif char == '"' then
      quoted = true
    elseif char == "{" or char == "[" then
      depth = depth + 1
      if depth > 32 then
        return false
      end
    elseif char == "}" or char == "]" then
      depth = depth - 1
    end
  end
  return true
end

local function unavailable(reason)
  return { status = "unavailable", reason = reason, rows = {} }
end

local function reading(answer, now)
  if answer and answer.state == "done" and answer.status == 0 and not bounded(answer.stdout) then
    return unavailable("quota output exceeds safety limits")
  end
  local value = quota.parse(answer, now, 30)
  -- Reject rather than silently omit accounts or windows from a large report.
  if #value.rows > MAX_ROWS then
    return unavailable("too many quota accounts")
  end
  for _, row in ipairs(value.rows) do
    if #row.windows > MAX_WINDOWS then
      return unavailable("too many quota windows")
    end
  end
  return value
end

-- quota-axi's own words for a logged-out account, and an auth row status.
local function auth(text)
  text = type(text) == "string" and text:lower() or ""
  return text:find("auth", 1, true) or text:find("log in", 1, true) or text:find("login", 1, true)
end

-- Unreachable, rather than reachable and failing: the transport's own failure,
-- ssh's 255, or no answer within the per-host timeout.
local function offline(reading)
  local reason = reading.reason or ""
  return reason:find("^timed out") or reason:find("^exit 255") or not reason:find("^exit ")
end

--- One short word or two for a host's title line: ok, checking, offline,
--- auth needed, stale · 3h old, no quota-axi or error. Nil when untrusted.
function hosts.state(reading, now)
  local status = reading.status
  if status == "loading" then
    return "checking"
  elseif status == "missing" then
    return "no quota-axi"
  elseif status == "unavailable" then
    if auth(reading.reason) then
      return "auth needed"
    end
    local reason = reading.reason or ""
    local broken = reason:find("^unreadable") or reason:find("^unsupported")
    return (not broken and offline(reading)) and "offline" or "error"
  elseif status ~= "ready" then
    return nil
  end
  if reading.generated_at and now - reading.generated_at > 300 then
    return "stale · " .. format.duration(now - reading.generated_at) .. " old"
  end
  local fresh, authless = false, false
  for _, row in ipairs(reading.rows) do
    fresh = fresh or row.status == "fresh"
    authless = authless or auth(row.status)
  end
  return (not fresh and authless) and "auth needed" or "ok"
end

function hosts.new()
  -- `last` is each configured host's last ready reading, drawn while the host
  -- cannot answer. Like `cache`, it holds configured hosts only.
  local model = { cache = {}, desired = {}, last = {} }
  -- Call from a handler, never render. The adapter supplies the verified core
  -- run_forget capability; this model does not execute or cancel any command.
  function model:reconcile(configured, forget, answers)
    local desired = {}
    for _, host in ipairs(configured) do
      desired[hosts.key(host.name)] = true
    end
    local retired = {}
    local function retire(key)
      if not desired[key] and not retired[key] then
        forget(key)
        self.cache[key] = nil
        retired[key] = true
      end
    end
    for key in pairs(self.desired) do
      retire(key)
    end
    -- The kernel can retain this plugin's answers across a Lua VM rebuild.
    -- Recover retired host keys from its owned snapshot, including pending
    -- asks, without touching the local quota or other command namespaces.
    for key in pairs(answers or {}) do
      if type(key) == "string" and key:sub(1, #KEY_PREFIX) == KEY_PREFIX then
        retire(key)
      end
    end
    self.desired = desired
  end
  function model:read(configured, answers, now, trusted)
    local groups, cache, last = {}, {}, {}
    for _, host in ipairs(configured) do
      local key = hosts.key(host.name)
      local answer = answers[key]
      local value
      if not trusted then
        value = { status = "untrusted", rows = {} }
      else
        local previous = self.cache[key]
        local minute = math.floor(now / 60)
        if previous and same_answer(previous.fields, answer) and previous.minute == minute then
          value = previous.reading
        else
          value = reading(answer, now)
        end
        cache[key] = { fields = answer_fields(answer), minute = minute, reading = value }
      end
      -- `reading` is this answer; `drawn` is what the panel paints for the host.
      local group = { host = host, reading = value, drawn = value, state = hosts.state(value, now) }
      if value.status == "ready" then
        last[key] = value
      elseif trusted and self.last[key] then
        -- Keep the gauges. A re-check in progress changes nothing; a failure
        -- says why they are old, and how old.
        last[key] = self.last[key]
        group.drawn = last[key]
        if value.status == "loading" then
          group.state = hosts.state(last[key], now)
        else
          local age = format.duration(now - (last[key].generated_at or now))
          group.state = group.state .. " · " .. age .. " old"
        end
      end
      groups[#groups + 1] = group
    end
    -- Only configured hosts survive. No history of removed hosts or reports.
    self.cache, self.last = cache, last
    return groups
  end
  return model
end

return hosts
