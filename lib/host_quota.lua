-- Transport-independent host quota model. Execution remains the kernel's job.
local quota = require("thurbox-info-panel.lib.quota")
local hosts = {}
local PAGE_SIZE = 3
local MAX_OUTPUT = 131072
local MAX_ROWS, MAX_WINDOWS = 32, 32

-- A distinct stable namespace from the existing local `quota` answer.
function hosts.key(name)
  return "quota.host:" .. name
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

function hosts.pages(configured)
  return math.max(1, math.ceil(#configured / PAGE_SIZE))
end

function hosts.new()
  local model = { cache = {}, desired = {} }
  -- Call from a handler, never render. The adapter supplies the verified core
  -- run_forget capability; this model does not execute or cancel any command.
  function model:reconcile(configured, forget)
    local desired = {}
    for _, host in ipairs(configured) do
      desired[hosts.key(host.name)] = true
    end
    for key in pairs(self.desired) do
      if not desired[key] then
        forget(key)
        self.cache[key] = nil
      end
    end
    self.desired = desired
  end
  function model:read(configured, answers, now, trusted, page)
    page = math.max(1, math.min(page or 1, hosts.pages(configured)))
    local groups, cache = {}, {}
    for i = (page - 1) * PAGE_SIZE + 1, math.min(page * PAGE_SIZE, #configured) do
      local host = configured[i]
      local key = hosts.key(host.name)
      local answer = answers[key]
      local value
      if not trusted then
        value = { status = "untrusted", rows = {} }
      else
        local previous = self.cache[key]
        local minute = math.floor(now / 60)
        if previous and rawequal(previous.answer, answer) and previous.minute == minute then
          value = previous.reading
        else
          value = reading(answer, now)
        end
        cache[key] = { answer = answer, minute = minute, reading = value }
      end
      groups[#groups + 1] = { host = host, reading = value }
    end
    -- Only the current page survives. No history of removed hosts or reports.
    self.cache = cache
    return groups
  end
  return model
end

return hosts
