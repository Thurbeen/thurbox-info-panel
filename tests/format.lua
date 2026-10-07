-- Pin the compact duration format at its boundaries.
local format = dofile("lib/format.lua")
local M, H, D = 60, 3600, 86400
local cases = {
  { -5, "now" },
  { 0, "now" },
  { 1, "<1m" },
  { 59, "<1m" },
  { M, "1m" },
  { M + 59, "1m" },
  { 59 * M, "59m" },
  { 59 * M + 59, "59m" },
  { H, "1h" },
  { H + M, "1h 1m" },
  { 23 * H + 59 * M, "23h 59m" },
  { 23 * H + 59 * M + 59, "23h 59m" },
  { D, "1d" },
  { D + 59 * M, "1d" },
  { D + 5 * H, "1d 5h" },
  { D + 5 * H + 59 * M, "1d 5h" },
  { 10 * D, "10d" },
  { 10 * D + 3 * H, "10d 3h" },
}
for _, case in ipairs(cases) do
  local got = format.duration(case[1])
  assert(got == case[2], case[1] .. "s: want " .. case[2] .. ", got " .. tostring(got))
end
assert(format.duration(nil) == nil, "no instant, no duration")
-- The widest any duration gets, which is what a reset column is sized to.
assert(utf8.len(format.duration(99 * D + 23 * H)) <= format.WIDEST)
print(#cases .. " duration cases passed")
