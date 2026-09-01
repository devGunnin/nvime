--- The full preflight, computed once and rendered by two surfaces:
--- `:checkhealth nvime` (`health.lua`, through `vim.health.*`) and
--- `:Nvime doctor` (`doctor.lua`, its own pass/warn/fail list). Neither calls
--- the other, so the two cannot silently drift apart.
---
--- Every probe here is a short, explicitly bounded subprocess — this is the
--- one place nvime blocks, and only because both callers are a user
--- deliberately asking "why doesn't this work", never an editing path.
local config = require('nvime.config')
local keymaps = require('nvime.keymaps')
local models = require('nvime.models')

-- Not a top-level `local agent = require(...)`: several specs replace
-- `package.loaded['nvime.agent']` with a fake for the span of their own
-- file. A capture taken here at first-require time would pin diagnostics to
-- whichever fake happened to be installed the first time anything pulled
-- this module in — `require()` below always resolves the module current
-- right now.
local function agent()
  return require('nvime.agent')
end

local M = {}

local PROBE_TIMEOUT_MS = 10000

--- @alias DiagnosticLevel 'ok'|'warn'|'error'|'info'
--- @class DiagnosticEntry
--- @field level DiagnosticLevel
--- @field message string
--- @field advice string|nil the fix, meaningful for `warn`/`error`

local function run(cmd, timeout_ms)
  local ok, proc = pcall(vim.system, cmd, { text = true })
  if not ok then
    return nil, tostring(proc)
  end
  local done = proc:wait(timeout_ms)
  if done.code ~= 0 then
    return nil, vim.trim((done.stderr or '') .. (done.stdout or ''))
  end
  return vim.trim(done.stdout or ''), nil
end

--- @param entries DiagnosticEntry[]
local function ok(entries, message)
  entries[#entries + 1] = { level = 'ok', message = message }
end

--- @param entries DiagnosticEntry[]
local function warn(entries, message, advice)
  entries[#entries + 1] = { level = 'warn', message = message, advice = advice }
end

--- @param entries DiagnosticEntry[]
local function fail(entries, message, advice)
  entries[#entries + 1] = { level = 'error', message = message, advice = advice }
end

--- @param entries DiagnosticEntry[]
local function info(entries, message)
  entries[#entries + 1] = { level = 'info', message = message }
end

local function check_neovim(entries)
  ok(entries, 'nvime ' .. require('nvime.version'))
  if vim.fn.has('nvim-0.10') == 1 then
    ok(entries, 'Neovim ' .. tostring(vim.version()))
  else
    fail(entries, 'nvime needs Neovim 0.10 or newer')
  end
end

local function check_keymaps(entries)
  local conflicts = keymaps.conflicts(keymaps.all(config.get()))
  if #conflicts == 0 then
    ok(entries, 'keymaps are leaf-only (no mapping is a prefix of another)')
    return
  end
  for _, clash in ipairs(conflicts) do
    fail(
      entries,
      string.format("'%s' is a prefix of '%s' in mode %s", clash.short.lhs, clash.long.lhs, clash.short.mode),
      'change one of them, or the shorter mapping stalls for timeoutlen'
    )
  end
end

--- Best-effort: the CLI's on-disk credential file, when it has one. A
--- Keychain-based login (macOS) leaves no such file, so absence is a nudge,
--- never proof of "not logged in" — only a turn proves that.
local function check_login_file(entries)
  local home = vim.uv.os_homedir()
  if home == nil then
    return
  end
  local path = home .. '/.claude/.credentials.json'
  if vim.uv.fs_stat(path) ~= nil then
    ok(entries, 'found a claude credentials file at ' .. path)
    return
  end
  warn(
    entries,
    'no claude credentials file at ' .. path,
    'run `claude` in a terminal and sign in — harmless to see if login uses the system keychain instead'
  )
end

local function check_node(entries)
  local node = config.get().agent.node
  if vim.fn.executable(node) == 0 then
    fail(entries, string.format("node not found (looked for '%s')", node), 'install Node 20 or newer')
    return false
  end
  local version, err = run({ node, '--version' }, PROBE_TIMEOUT_MS)
  if version == nil then
    fail(entries, 'could not run node: ' .. tostring(err))
    return false
  end
  local major = tonumber(version:match('^v(%d+)'))
  if major == nil or major < 20 then
    fail(entries, 'node ' .. version .. ' is too old', 'nvime needs Node 20 or newer')
    return false
  end
  ok(entries, 'node ' .. version)
  return true
end

local function check_build(entries)
  local dist = agent().dist_path()
  if vim.uv.fs_stat(dist) == nil then
    fail(entries, 'the sidecar is not built (' .. dist .. ' is missing)', agent().build_hint())
    return false
  end
  ok(entries, 'sidecar built: ' .. dist)
  return true
end

--- @param entries DiagnosticEntry[]
--- @param claude table the sidecar's ping result
local function report_claude(entries, claude)
  if claude.claudePath == nil then
    fail(entries, 'the claude CLI was not found on PATH', 'install Claude Code and run `claude` once to sign in')
    return
  end
  ok(entries, string.format('claude %s at %s', tostring(claude.claudeVersion), claude.claudePath))
  if #(claude.strippedEnv or {}) > 0 then
    warn(
      entries,
      'these variables are set and are being stripped: ' .. table.concat(claude.strippedEnv, ', '),
      'nvime is subscription-only and never forwards an API key'
    )
  else
    ok(entries, 'subscription auth: no API key in the environment')
  end
  if agent().is_running() then
    info(entries, 'a sidecar is already running for this Neovim instance')
  end
  info(entries, 'claude login is confirmed by the first chat turn; run `:Nvime chat` to verify it')
end

--- Starts the sidecar, pings it, and shuts it down again. Uses the same env as
--- a real spawn, or the probe would deny a `claude` that chat resolves fine.
local function check_sidecar(entries)
  local node = config.get().agent.node
  local ok_spawn, proc = pcall(vim.system, { node, agent().dist_path() }, {
    stdin = true,
    text = true,
    env = agent().sidecar_env(),
  })
  if not ok_spawn then
    fail(entries, 'could not start the sidecar: ' .. tostring(proc))
    return
  end
  proc:write('{"id":1,"method":"ping","params":{}}\n')
  proc:write('{"id":2,"method":"shutdown","params":{}}\n')
  proc:write(nil)
  local done = proc:wait(PROBE_TIMEOUT_MS)
  local ping = nil
  for _, line in ipairs(vim.split(done.stdout or '', '\n', { plain = true, trimempty = true })) do
    local decoded_ok, frame = pcall(vim.json.decode, line)
    if decoded_ok and type(frame) == 'table' and frame.id == 1 then
      ping = frame
    end
  end
  if ping == nil or ping.ok ~= true then
    fail(entries, 'the sidecar did not answer a ping', vim.trim(done.stderr or ''))
    return
  end
  ok(entries, 'sidecar answers: nvime-agent ' .. tostring(ping.result.agentVersion))
  report_claude(entries, ping.result)
end

--- A big change's local merge writes a commit; with no identity configured
--- that write fails outright (the P4 gate-reviewer refusal this exists for).
--- Skipped, not failed, outside a git repository — there is nothing to check.
--- @param entries DiagnosticEntry[]
--- @param root string a directory to start looking from
local function check_git_identity(entries, root)
  local git_root = vim.fs.root(root, { '.git' })
  if git_root == nil then
    info(entries, 'not inside a git repository — nothing to check for identity')
    return
  end
  local name = run({ 'git', '-C', git_root, 'config', 'user.name' }, PROBE_TIMEOUT_MS)
  local email = run({ 'git', '-C', git_root, 'config', 'user.email' }, PROBE_TIMEOUT_MS)
  if name == nil or name == '' or email == nil or email == '' then
    fail(
      entries,
      'git has no identity configured for ' .. git_root,
      "git config user.name '<name>' && git config user.email '<email>'"
    )
    return
  end
  ok(entries, string.format('git identity: %s <%s>', name, email))
end

--- Lists every lane whose model/effort dial is not the CLI default, config or
--- a session-scoped `:Nvime model` override alike — informational, since a
--- non-default dial is a deliberate choice, not a problem to fix.
local function check_model_dial(entries)
  local active = models.summary()
  if #active == 0 then
    info(entries, 'model dial: every lane uses the CLI default')
    return
  end
  info(entries, 'model dial: ' .. table.concat(active, '  '))
end

--- Runs every check and returns what each found, in the order a reader should
--- see them. Never raises — a probe that cannot even run is reported as a
--- failure of that probe, not a crash of the command that asked for this.
--- @param root string|nil where to check git identity from; defaults to cwd
--- @return DiagnosticEntry[]
function M.run(root)
  local entries = {}
  check_neovim(entries)
  check_keymaps(entries)
  local exit = agent().last_exit()
  if exit ~= nil and exit.code ~= 0 then
    warn(entries, 'the sidecar exited with code ' .. tostring(exit.code), exit.stderr)
  end
  if check_node(entries) and check_build(entries) then
    check_sidecar(entries)
  end
  check_login_file(entries)
  check_git_identity(entries, root or vim.uv.cwd())
  check_model_dial(entries)
  return entries
end

return M
