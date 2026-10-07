-- JSON decoder adapted from thurbox-auto-continue (MIT).
-- Provider semantics follow quota-axi 0.1.58 schema 5/6.
local quota = {}
local function object(value)
  return type(value) == "table" and value or {}
end

local ESCAPES =
  { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

--- Decode one JSON document. `null` reads as absent (nil), which is how every
--- caller here treats it. Returns nil and a reason for anything that is not
--- exactly one JSON value.
function quota.decode(text)
  if type(text) ~= "string" then
    return nil, "no output"
  end
  local pos = 1
  local function fail(what)
    error({ json = what .. " at byte " .. pos }, 0)
  end
  local function skip()
    pos = text:find("[^ \t\r\n]", pos) or (#text + 1)
  end
  local value
  local function str()
    local out = {}
    pos = pos + 1
    while true do
      local c = text:sub(pos, pos)
      if c == "" then
        fail("unterminated string")
      elseif c == '"' then
        pos = pos + 1
        return table.concat(out)
      elseif c == "\\" then
        local e = text:sub(pos + 1, pos + 1)
        if e == "u" then
          local hex = text:sub(pos + 2, pos + 5)
          local code = tonumber(hex, 16)
          if not code or #hex ~= 4 then
            fail("bad \\u escape")
          end
          pos = pos + 6
          -- A surrogate pair is one character.
          if code >= 0xD800 and code <= 0xDBFF and text:sub(pos, pos + 1) == "\\u" then
            local low = tonumber(text:sub(pos + 2, pos + 5), 16)
            if low and low >= 0xDC00 and low <= 0xDFFF then
              code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
              pos = pos + 6
            end
          end
          out[#out + 1] = utf8.char(code)
        elseif ESCAPES[e] then
          out[#out + 1] = ESCAPES[e]
          pos = pos + 2
        else
          fail("bad escape")
        end
      else
        local stop = text:find('["\\]', pos) or (#text + 1)
        out[#out + 1] = text:sub(pos, stop - 1)
        pos = stop
      end
    end
  end
  value = function()
    skip()
    local c = text:sub(pos, pos)
    if c == "{" then
      local obj = {}
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "}" then
        pos = pos + 1
        return obj
      end
      while true do
        skip()
        if text:sub(pos, pos) ~= '"' then
          fail("expected a key")
        end
        local key = str()
        skip()
        if text:sub(pos, pos) ~= ":" then
          fail("expected :")
        end
        pos = pos + 1
        obj[key] = value()
        skip()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "}" then
          return obj
        elseif d ~= "," then
          fail("expected , or }")
        end
      end
    elseif c == "[" then
      local arr, n = {}, 0
      pos = pos + 1
      skip()
      if text:sub(pos, pos) == "]" then
        pos = pos + 1
        return arr
      end
      while true do
        n = n + 1
        arr[n] = value()
        skip()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "]" then
          return arr
        elseif d ~= "," then
          fail("expected , or ]")
        end
      end
    elseif c == '"' then
      return str()
    elseif text:sub(pos, pos + 3) == "true" then
      pos = pos + 4
      return true
    elseif text:sub(pos, pos + 4) == "false" then
      pos = pos + 5
      return false
    elseif text:sub(pos, pos + 3) == "null" then
      pos = pos + 4
      return nil
    else
      local num = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
      if not num or num == "" or num == "-" then
        fail("unexpected character")
      end
      pos = pos + #num
      return tonumber(num) or fail("bad number")
    end
  end
  local ok, result = pcall(function()
    local v = value()
    skip()
    if pos <= #text then
      fail("trailing characters")
    end
    return v
  end)
  if not ok then
    return nil, type(result) == "table" and result.json or tostring(result)
  end
  if result == nil then
    return nil, "null"
  end
  return result
end

-- ISO timestamps in quota-axi are UTC. Gregorian civil date to epoch seconds.
local function epoch(s)
  if type(s) ~= "string" then
    return nil
  end
  local y, m, d, h, minute, sec = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y or not s:match("Z$") then
    return nil
  end
  y, m, d = tonumber(y), tonumber(m), tonumber(d)
  y = y - (m <= 2 and 1 or 0)
  local era = math.floor(y / 400)
  local yo = y - era * 400
  local mp = m + (m > 2 and -3 or 9)
  local days = era * 146097
    + yo * 365
    + math.floor(yo / 4)
    - math.floor(yo / 100)
    + math.floor((153 * mp + 2) / 5)
    + d
    - 1
    - 719468
  return days * 86400 + tonumber(h) * 3600 + tonumber(minute) * 60 + tonumber(sec)
end

local function unavailable(reason)
  return { status = "unavailable", reason = reason, rows = {} }
end

-- The first non-blank line of a stream, trimmed.
local function first_line(s)
  return type(s) == "string" and s:match("^%s*([^\r\n]-)%s*[\r\n]") or nil
end

--- `timeout` is the one the run was asked with, so a timeout can say how long.
function quota.parse(answer, now, timeout)
  if not answer or answer.state == "pending" then
    return { status = "loading", rows = {} }
  end
  if answer.state ~= "done" then
    -- Thurbox's own reason; it names an empty session id with a double space.
    local why = type(answer.error) == "string" and answer.error:gsub("%s+", " ") or nil
    return unavailable(why or "not finished")
  end
  if answer.status == 127 or answer.status == 9009 then
    return { status = "missing", rows = {} }
  end
  if answer.timed_out then
    return unavailable(timeout and ("timed out after " .. timeout .. "s") or "timed out")
  end
  if answer.truncated then
    return unavailable("output truncated")
  end
  if answer.status == nil then
    return unavailable("killed by a signal")
  end
  if answer.status ~= 0 then
    local line = first_line((answer.stderr or "") .. "\n")
    return unavailable("exit " .. answer.status .. ((line and line ~= "") and (": " .. line) or ""))
  end
  local data, err = quota.decode(answer.stdout)
  if type(data) ~= "table" then
    return unavailable("unreadable output: " .. tostring(err))
  end
  if data.schemaVersion ~= 5 and data.schemaVersion ~= 6 then
    return unavailable("unsupported schemaVersion " .. tostring(data.schemaVersion))
  end
  if type(data.providers) ~= "table" then
    return unavailable("no providers in output")
  end
  local at = epoch(data.generatedAt)
  local aged = not at or (now and now - at > 300)
  local rows = {}
  for _, p in ipairs(data.providers) do
    if type(p) == "table" and not p.notSetUp and type(p.provider) == "string" then
      local st = object(p.state)
      local status = (aged or st.stale or st.status == "stale") and "stale"
        or st.status
        or "unavailable"
      local account = p.accountKey or object(p.accountKeys)[1]
      account = type(account) == "string" and account or "default"
      local bindings, limiting, untrusted = {}, {}, {}
      for _, id in ipairs(object(st.untrustedWindowIds)) do
        untrusted[id] = true
      end
      for _, raw_scope in ipairs(object(object(p.quotaSemantics).effectiveAvailability)) do
        local scope = object(raw_scope)
        local trusted = scope.status == "known"
        for _, id in ipairs(object(scope.boundedBy)) do
          if untrusted[id] then
            trusted = false
          end
        end
        if trusted then
          for _, id in ipairs(object(scope.limitingWindowIds)) do
            limiting[id] = true
          end
        end
      end
      local windows = {}
      for _, raw_window in ipairs(object(p.windows)) do
        local w = object(raw_window)
        local percent = w.percentRemaining
        local known = status == "fresh"
          and not untrusted[w.id]
          and type(percent) == "number"
          and percent == percent
          and percent >= 0
          and percent <= 100
        local label = type(w.label) == "string" and w.label
          or type(w.id) == "string" and w.id
          or "window"
        local reset = w.resetsAt or w.resetText
        reset = type(reset) == "string" and reset or nil
        local window = {
          label = label,
          remaining = known and percent or nil,
          reset = reset,
          binding = limiting[w.id] == true,
          status = known and "fresh" or (status == "fresh" and "unavailable" or status),
        }
        windows[#windows + 1] = window
        if window.binding then
          bindings[#bindings + 1] = window
        end
      end
      rows[#rows + 1] = {
        provider = p.provider,
        account = account,
        status = status == "fresh" and (#windows > 0 and "fresh" or "unavailable") or status,
        bindings = bindings,
        windows = windows,
      }
    end
  end
  return { status = "ready", rows = rows }
end
return quota
