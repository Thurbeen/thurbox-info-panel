-- End to end: the program the pane hands `run()`, executed as thurbox's kernel
-- executes it (`sh -c`, thurbox's own PATH), then rendered by the pane.
local UI = assert(arg[1], "pass a Thurbox ui/ directory")
package.path = UI .. "/?.lua;./?.lua;" .. package.path
for _, name in ipairs({ "quota", "format", "host_quota" }) do
  package.preload["thurbox-info-panel.lib." .. name] = function()
    return dofile("lib/" .. name .. ".lua")
  end
end
thurbox = {}
text = {
  width = function(s)
    return utf8.len(s)
  end,
  truncate = function(s, n)
    if utf8.len(s) <= n then
      return s
    end
    return s:sub(1, (utf8.offset(s, math.max(1, n)) or 1) - 1) .. "…"
  end,
  pad = function(s, n)
    return s .. string.rep(" ", math.max(0, n - utf8.len(s)))
  end,
}

local function sh(command)
  local pipe = assert(io.popen(command))
  local out = pipe:read("a")
  local _, _, code = pipe:close()
  return out, code
end

local function write(path, content, mode)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  if mode then
    assert(os.execute("chmod " .. mode .. " '" .. path .. "'"))
  end
end

local function read(path)
  local f = io.open(path)
  if not f then
    return ""
  end
  local s = f:read("a")
  f:close()
  return s
end

local scratch = sh("mktemp -d"):gsub("%s+$", "")
local report = read("tests/fixtures/several.json")

local function fake_home(name, with_quota_axi)
  local home = scratch .. "/" .. name
  assert(os.execute("mkdir -p '" .. home .. "/node/bin' '" .. home .. "/bin'"))
  write(home .. "/report.json", report)
  if with_quota_axi then
    write(
      home .. "/node/bin/quota-axi",
      '#!/bin/sh\n[ "$*" = "--json --no-credential-refresh" ] || { echo "error: bad args $*"; exit 2; }\n'
        .. 'cat "$HOME/report.json"\n',
      "+x"
    )
    write(home .. "/.profile", 'PATH="$HOME/node/bin:$PATH"\nexport PATH\n')
  end
  return home
end

local function kernel_run(program, home, extra_path)
  local file = scratch .. "/program"
  write(file, program)
  local errors = scratch .. "/stderr"
  local stdout, code = sh(
    "env -i HOME='"
      .. home
      .. "' SHELL=/bin/sh PATH='"
      .. (extra_path and (extra_path .. ":") or "")
      .. "/usr/bin:/bin' sh -c \"$(cat '"
      .. file
      .. "')\" 2>'"
      .. errors
      .. "'"
  )
  return { state = "done", status = code, ok = code == 0, stdout = stdout, stderr = read(errors) }
end

local function flatten(node, lines)
  if node.type == "text" and type(node.text) == "table" then
    for _, line in ipairs(node.text) do
      local parts = {}
      for _, span in ipairs(line) do
        parts[#parts + 1] = span.text or ""
      end
      lines[#lines + 1] = table.concat(parts)
    end
  end
  for _, child in ipairs(node.children or {}) do
    flatten(child, lines)
  end
  return lines
end

local function pane_with(snapshot)
  store, state = {}, {}
  thurbox = snapshot
  local asked = {}
  run = function(key, program, opts)
    asked[key] = { program = program, opts = opts }
  end
  run_forget = function() end
  command = function() end
  local pane = dofile("info_panel.lua")
  pane.on_action("info.quota.refresh")
  return pane, asked
end

local function render(pane)
  local flat = table.concat(flatten(pane.render({ width = 80, height = 400 }), {}), "\n")
  return flat:gsub("%s*\n%s*", " ")
end

local function snapshot(extra)
  local s = {
    taken_at_ms = 1791374400000,
    sessions = {},
    hosts = { { name = "local" } },
    fleets = { { name = "local", transport = "local Fleet", remote = false } },
    registry = { settings = {} },
    theme = { roles = {} },
    metrics = {},
    platform = { os = "linux" },
    runs = {},
  }
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end

-- Local: quota-axi is on PATH only in the user's login shell.
local home = fake_home("local", true)
local pane, asked = pane_with(snapshot())
assert(asked.quota, "the pane asked for no local quota")
assert(asked.quota.opts.machine == "local", "local quota must run on this machine")
thurbox.runs.quota = kernel_run(asked.quota.program, home)
local screen = render(pane)
assert(
  not screen:find("npm install", 1, true),
  "install hint while quota-axi is installed:\n" .. screen
)
assert(screen:find("codex", 1, true), "local quota missing:\n" .. screen)
assert(not screen:find("remote", 1, true), "the local place is not a remote host:\n" .. screen)
print("Local quota-axi found through the login shell")

-- Local: really missing says so precisely.
local bare = fake_home("bare", false)
pane, asked = pane_with(snapshot())
thurbox.runs.quota = kernel_run(asked.quota.program, bare)
screen = render(pane)
assert(screen:find("quota-axi not found", 1, true), "missing tool not named:\n" .. screen)
assert(
  screen:find("npm install -g quota-axi", 1, true),
  "missing tool has no install hint:\n" .. screen
)
print("A missing quota-axi is reported precisely")

-- Remote: a place and an ssh Fleet naming the same machine are one host.
local remote = fake_home("remote", true)
local fake_ssh = scratch .. "/sshbin"
assert(os.execute("mkdir -p '" .. fake_ssh .. "'"))
write(
  fake_ssh .. "/ssh",
  '#!/bin/sh\nprintf "%s\\n" "$@" > "$SSH_ARGS"\n'
    .. 'case "$SSH_MODE" in offline) echo "ssh: connect to host: timed out" >&2; exit 255;; esac\n'
    .. 'HOME="$REMOTE_HOME" exec sh -s\n',
  "+x"
)
local remote_snapshot = snapshot({
  hosts = { { name = "local" }, { name = "mux/devbox" } },
  fleets = {
    { name = "local", transport = "local Fleet", remote = false },
    { name = "devbox", transport = "ssh me@devbox", remote = true },
    { name = "evil", transport = "ssh $(touch${IFS}pwned)", remote = true },
  },
})
pane, asked = pane_with(remote_snapshot)
local key = "quota.host:devbox"
assert(asked[key], "no quota asked for devbox")
assert(asked[key].opts.machine == "local", "a remote host is reached by a local ssh run")
local count = 0
for k in pairs(asked) do
  count = count + 1
  assert(not k:find("evil", 1, true) and not k:find("local", 1, true), "unexpected run " .. k)
end
assert(count == 2, "expected the local run and one de-duplicated host run")
local args_file = scratch .. "/ssh-args"
local wrapper = "export SSH_ARGS='"
  .. args_file
  .. "' REMOTE_HOME='"
  .. remote
  .. "' PATH='"
  .. fake_ssh
  .. ":/usr/bin:/bin'; "
thurbox.runs.quota = kernel_run(asked.quota.program, home)
thurbox.runs[key] = kernel_run(wrapper .. asked[key].program, bare)
local ssh_args = read(args_file)
assert(ssh_args:find("BatchMode=yes", 1, true), "ssh must not prompt: " .. ssh_args)
assert(ssh_args:find("ConnectTimeout=10", 1, true), "ssh needs a connect timeout: " .. ssh_args)
assert(ssh_args:find("\nme@devbox\n", 1, true), "ssh destination: " .. ssh_args)
screen = render(pane)
assert(screen:find("devbox", 1, true), "remote host not labelled:\n" .. screen)
assert(not screen:find("evil", 1, true), "an unsafe destination became a host:\n" .. screen)
local _, codex = screen:gsub("codex", "")
assert(codex == 2, "expected local and remote quotas:\n" .. screen)
assert(not io.open(scratch .. "/pwned"), "unsafe host name reached the shell")
print("Remote quota runs over ssh with the same resolver")

thurbox.runs[key] = kernel_run("export SSH_MODE=offline; " .. wrapper .. asked[key].program, bare)
screen = render(pane)
assert(screen:find("offline", 1, true), "unreachable host not offline:\n" .. screen)
print("An unreachable host reads offline")

os.execute("rm -rf '" .. scratch .. "'")
