-- Compact relative durations, the way fleet's queue pane writes them.
local format = {}

--- Columns the widest duration under a hundred days takes: `23h 59m`, `99d 23h`.
format.WIDEST = 7

--- `seconds` as its two largest units, floored: `<1m`, `45m`, `5h`, `23h 59m`,
--- `1d 5h`, `10d`. A zero second unit is dropped (`1h`, not `1h 0m`), seconds are
--- never shown, and nothing left reads `now`. Nil in, nil out.
function format.duration(seconds)
  if seconds == nil then
    return nil
  end
  seconds = math.floor(seconds)
  if seconds <= 0 then
    return "now"
  elseif seconds < 60 then
    return "<1m"
  end
  local minutes = math.floor(seconds / 60)
  local big, small, big_unit, small_unit
  if minutes < 60 then
    return minutes .. "m"
  elseif minutes < 1440 then
    big, small, big_unit, small_unit = math.floor(minutes / 60), minutes % 60, "h", "m"
  else
    big, small, big_unit, small_unit =
      math.floor(minutes / 1440), math.floor(minutes % 1440 / 60), "d", "h"
  end
  if small == 0 then
    return big .. big_unit
  end
  return big .. big_unit .. " " .. small .. small_unit
end

return format
