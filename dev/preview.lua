-- Render the pane outside thurbox, against a fabricated snapshot.
--
-- WHY THIS EXISTS. A pane can only fail at runtime. `selene` checks the sandbox
-- and `stylua` the formatting, but neither calls `render`, and the kernel's own
-- `Metrics` has no setters — so an integration test cannot populate the agent,
-- usage or per-session resource sections at all. Everything below the "Agent"
-- heading is therefore reachable only from here.
--
-- It has already earned its place twice: it caught an assignment to a `for`
-- variable (an error in Lua 5.4, which is what the kernel embeds) and two rows
-- whose width budget had forgotten the frame's own two columns.
--
-- Usage, from the repository root:
--
--     lua dev/preview.lua <thurbox-ui-dir> [width] [scenario]
--
-- `<thurbox-ui-dir>` is an interface directory — `~/.config/thurbox/ui` or a
-- checkout's `ui/` — because the pane requires `lib.theme`, `lib.widgets` and
-- `lib.panels` from it. Scenarios: `full` (default),
-- `no-session`, `bare`.
--
-- `width` is the column's width — the rect `layout.lua` gives the `info` slot,
-- which is what the pane is handed and what every width budget inside it is
-- measured against.
--
-- A row wider than the pane is flagged: the renderer would clip it silently, and
-- silent clipping is what wrapping and `clip` exist to prevent.

local UI = arg[1]
local WIDTH = tonumber(arg[2]) or 44
local SCENARIO = arg[3] or "full"

if not UI then
  io.stderr:write("usage: lua dev/preview.lua <thurbox-ui-dir> [width] [scenario]\n")
  os.exit(2)
end
package.path = UI .. "/?.lua;" .. package.path

local SESSION = "s1-0000-0000-0000-000000000000"

-- The globals the kernel injects. Only the fields this pane reads are here; the
-- shape follows `LuaHost::publish` in the thurbox repository.
thurbox = {
  taken_at_ms = 1700000000000,
  registry = { settings = {} },
  theme = {
    name = "preview",
    roles = {
      accent = "#89b4fa",
      accent_bright = "#b4befe",
      text_muted = "#6c7086",
      text_primary = "#cdd6f4",
      text_secondary = "#bac2de",
      status_idle = "#a6e3a1",
      status_working = "#f9e2af",
      status_blocked = "#f38ba8",
      status_done = "#89b4fa",
      status_error = "#f38ba8",
      status_unreachable = "#585b70",
      danger = "#f38ba8",
      border_unfocused = "#45475a",
      border_focused = "#89b4fa",
      branch_name = "#94e2d5",
      keybind_hint = "#f5c2e7",
    },
  },
  sessions = {
    {
      id = SESSION,
      name = "fix-osc52-tmux",
      agent = "claude",
      status = "working",
      backend = "ssh:devbox",
      repo = "thurbox",
      branch = "fix/osc52",
      base_branch = "main",
      host = "devbox",
      parent = "p1",
      repos = { "thurbox", "website", "docs-site" },
      activity = "Editing src/agent/transport.rs and running the tmux control-mode probe",
      notification = "Claude needs approval to run `git push --force-with-lease origin fix/osc52`",
      git = {
        files = 7,
        insertions = 214,
        deletions = 38,
        untracked = 3,
        dirty = true,
        ahead = 2,
        behind = 1,
      },
    },
    { id = "p1", name = "lead-session", agent = "claude", status = "idle", repos = {} },
  },
  metrics = {
    system = {
      cpu_percent = 63.4,
      memory_used = 15603 * 1048576,
      memory_total = 32017 * 1048576,
    },
    sessions = {
      [SESSION] = {
        cpu_percent = 187.5,
        memory_bytes = 812 * 1048576,
        agent = {
          model = "Opus 5",
          cli_version = "2.1.4",
          cost_usd = 0.8342,
          duration_ms = 4521000,
          api_duration_ms = 1880000,
          input_tokens = 1284000,
          output_tokens = 48210,
          context_window = 200000,
          context_used_percent = 71,
          lines_added = 412,
          lines_removed = 96,
          cache_read_tokens = 980000,
          cache_creation_tokens = 120000,
        },
        usage = {
          plan = "max",
          windows = {
            { label = "5h", used_percent = 42.0, resets_at = 1700000000 + 7200 },
            { label = "Week", used_percent = 88.5, resets_at = 1700000000 + 331200 },
            -- No reset time: the group budget must not stop at this hole.
            { label = "Opus", used_percent = 12.0 },
          },
        },
      },
    },
  },
  automations = {
    {
      id = 1,
      name = "shepherd-tick",
      schedule = "*/10 * * * *",
      enabled = true,
      last_outcome = "ok",
      runs = {},
    },
    {
      id = 2,
      name = "renovate-tick",
      schedule = "0 3 * * 1",
      enabled = true,
      last_outcome = "failed",
      runs = {},
    },
    { id = 3, name = "off-one", schedule = "@daily", enabled = false, runs = {} },
  },
}
store = { selected = SESSION }
function command() end

if SCENARIO == "no-session" then
  store.selected = nil
elseif SCENARIO == "bare" then
  -- The first frame after a spawn: nothing sampled, nothing scheduled.
  thurbox.metrics = {}
  thurbox.automations = {}
  thurbox.sessions = {
    { id = SESSION, name = "new-session", agent = "codex", status = "idle", repos = {} },
  }
elseif SCENARIO ~= "full" then
  io.stderr:write("unknown scenario: " .. SCENARIO .. "\n")
  os.exit(2)
end

local pane = dofile("info_panel.lua")

--- Flatten a node tree to the lines it would paint.
local function flatten(node, out)
  if type(node) ~= "table" then
    return out
  end
  if node.type == "text" then
    local text = node.text
    if type(text) == "string" then
      out[#out + 1] = text
    elseif type(text) == "table" then
      if text.text ~= nil then
        out[#out + 1] = tostring(text.text)
      else
        for _, line in ipairs(text) do
          if type(line) == "string" then
            out[#out + 1] = line
          elseif line.text ~= nil then
            out[#out + 1] = tostring(line.text)
          else
            local parts = {}
            for _, run in ipairs(line) do
              parts[#parts + 1] = tostring(run.text or "")
            end
            out[#out + 1] = table.concat(parts)
          end
        end
      end
    end
  end
  for _, child in ipairs(node.children or {}) do
    flatten(child, out)
  end
  return out
end

-- The centre's tree, standing in for the agent terminal the panel sits beside.
local ok, node = pcall(pane.render, { width = WIDTH, height = 60, focused = false })
if not ok then
  io.stderr:write("RENDER ERROR: " .. tostring(node) .. "\n")
  os.exit(1)
end

local lines = flatten(node, {})
local inner = WIDTH - 2
local title = (node.frame and node.frame.title) or "?"
local overflow = 0
print(string.format("%s  column=%d  scenario=%s", title, WIDTH, SCENARIO))
print("+" .. string.rep("-", inner) .. "+")
for _, line in ipairs(lines) do
  local len = utf8.len(line) or #line
  local note = ""
  if len > inner then
    note = "  <<< OVERFLOW by " .. (len - inner)
    overflow = overflow + 1
  end
  print("|" .. line .. string.rep(" ", math.max(0, inner - len)) .. "|" .. note)
end
print("+" .. string.rep("-", inner) .. "+")
if overflow > 0 then
  io.stderr:write(string.format("%d row(s) wider than the pane\n", overflow))
  os.exit(1)
end
