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

local QUOTA_ARGS = "--json --no-credential-refresh"

--- A POSIX sh script that runs quota-axi wherever the user's shell would find
--- it. Holds no single quote, so it can travel single-quoted to another machine.
hosts.RESOLVER = table.concat({
  "if ! command -v quota-axi >/dev/null 2>&1; then",
  "  for flags in -lc -ilc; do",
  '    found=$("${SHELL:-/bin/sh}" "$flags" "command -v quota-axi" </dev/null 2>/dev/null | tail -n 1)',
  '    case $found in /*) PATH="${found%/*}:$PATH"; export PATH; break;; esac',
  "  done",
  "fi",
  "command -v quota-axi >/dev/null 2>&1 || {",
  '  echo "quota-axi not found on PATH, nor by ${SHELL:-/bin/sh} as a login or interactive shell" >&2',
  "  exit 127",
  "}",
  "exec quota-axi " .. QUOTA_ARGS,
}, "\n")

hosts.WINDOWS_COMMAND = "quota-axi " .. QUOTA_ARGS

local SSH_NAME = "^[%w_][%w._-]*$"

local function ssh_safe(destination)
  local user, machine = destination:match("^([^@]*)@(.*)$")
  if user then
    return user:match(SSH_NAME) ~= nil and machine:match(SSH_NAME) ~= nil
  end
  return destination:match(SSH_NAME) ~= nil
end

--- The local program that runs the resolver on `destination` over ssh. Only a
--- destination made of name characters is accepted, so nothing in it is ever
--- shell syntax; anything else returns nil.
function hosts.ssh_command(destination)
  if type(destination) ~= "string" or not ssh_safe(destination) then
    return nil
  end
  return "printf '%s\\n' '"
    .. hosts.RESOLVER
    .. "' | ssh -o BatchMode=yes -o ConnectTimeout=10 '"
    .. destination
    .. "' sh -s"
end

--- The machines to read quota on: each non-local Fleet place (`mux/<name>`
--- reached as `ssh <name>`) and each Fleet reached over ssh, one per machine.
--- A Fleet's own destination wins, since it carries the user. A core from
--- before Fleet publishes no `fleets`: its `hosts.toml` hosts are `legacy`,
--- reached through its own transport.
function hosts.targets(snapshot)
  local targets, index = {}, {}
  if snapshot.fleets == nil then
    for _, host in ipairs(snapshot.hosts or {}) do
      if type(host) == "table" and type(host.name) == "string" then
        targets[#targets + 1] = { name = host.name, platform = host.platform, legacy = true }
      end
    end
    return targets
  end
  local function add(name, destination)
    if not name or name == "" then
      return
    end
    local at = index[name]
    if not at then
      index[name] = #targets + 1
      targets[#targets + 1] = { name = name, destination = destination }
    elseif destination:find("@", 1, true) then
      targets[at].destination = destination
    end
  end
  for _, place in ipairs(snapshot.hosts or {}) do
    local name = type(place) == "table" and type(place.name) == "string" and place.name
    local dynamic = type(place) == "table"
      and type(place.detail) == "string"
      and place.detail:find("new machine per session", 1, true)
    local machine = name and not dynamic and name:match("^mux/([^/]+)$")
    if machine then
      add(machine, machine)
    end
  end
  for _, fleet in ipairs(snapshot.fleets or {}) do
    local transport = type(fleet) == "table" and fleet.transport
    local destination = type(transport) == "string" and transport:match("^ssh (%S+)$")
    if destination and ssh_safe(destination) then
      add(destination:match("([^@]+)$"), destination)
    end
  end
  return targets
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
local function offline(answer)
  return answer and (answer.state ~= "done" or answer.timed_out or answer.status == 255)
end

--- One short word or two for a host's title line: ok, checking, offline,
--- auth needed, stale · 3h old, no quota-axi or error. Nil when untrusted.
--- `answer` is the run the reading came from, which says whether it arrived.
function hosts.state(reading, now, answer)
  local status = reading.status
  if status == "loading" then
    return "checking"
  elseif status == "missing" then
    return "no quota-axi"
  elseif status == "unavailable" then
    if offline(answer) then
      return "offline"
    end
    return auth(reading.reason) and "auth needed" or "error"
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
    -- The kernel can retain this mod's answers across a Lua VM rebuild.
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
      local group =
        { host = host, reading = value, drawn = value, state = hosts.state(value, now, answer) }
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
