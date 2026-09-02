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
  -- `wait` answers nil when the deadline passes: it waits, SIGKILLs, waits
  -- again, and hands back a result that was never filled in. Indexing that is
  -- how `:Nvime doctor` crashed on a hung binary.
  local done = proc:wait(timeout_ms)
  if done == nil then
    return nil, string.format('timed out after %dms', timeout_ms)
  end
  if done.code ~= 0 then
    return nil, vim.trim((done.stderr or '') .. (done.stdout or ''))
  end
  return vim.trim(done.stdout or ''), nil
end

--- A probe error worth reporting as such. An unset git value answers with an
--- empty string and an empty error; only an unrunnable probe has a message.
--- @param err string|nil
--- @return string|nil
local function timeout_error(err)
  if err == nil or err == '' then
    return nil
  end
  return err
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

--- @class NodeProbe
--- @field found boolean whether the configured node is on PATH at all
--- @field version string|nil
--- @field err string|nil

--- Renders what a node probe found. Pure: the same reporting whether the
--- probe blocked (`run`) or ran off the main thread (`run_async`).
--- @param probed NodeProbe
--- @return string|nil the version, so the bundle reports it without a second
--- probe of its own
local function report_node(entries, probed)
  if not probed.found then
    local node = config.get().agent.node
    fail(entries, string.format("node not found (looked for '%s')", node), 'install Node 20 or newer')
    return nil
  end
  if probed.version == nil then
    fail(entries, 'could not run node: ' .. tostring(probed.err))
    return nil
  end
  local major = tonumber(probed.version:match('^v(%d+)'))
  if major == nil or major < 20 then
    fail(entries, 'node ' .. probed.version .. ' is too old', 'nvime needs Node 20 or newer')
    return nil
  end
  ok(entries, 'node ' .. probed.version)
  return probed.version
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

local function report_organization(entries, frame)
  assert(config.get().organization.control_plane_url ~= nil, 'managed report needs an endpoint')
  if type(frame) ~= 'table' then
    fail(entries, 'organization control plane did not answer the policy probe')
    return
  end
  if frame.ok ~= true then
    local err = frame.error or {}
    fail(entries, 'organization assurance is unavailable: ' .. (err.message or 'unknown control-plane error'))
    return
  end
  local policy = frame.result or {}
  if type(policy.policyId) ~= 'string' or type(policy.threshold) ~= 'number' then
    fail(entries, 'organization control plane returned an invalid policy')
    return
  end
  assert(policy.policyId ~= '', 'validated managed policy ID must not be empty')
  ok(entries, string.format('managed policy %s · pass mark %d', policy.policyId, policy.threshold))
  ok(entries, 'licensed trust core and GitHub CLI are executable')
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
  if config.get().organization.control_plane_url ~= nil then
    proc:write('{"id":3,"method":"organization.policy","params":{}}\n')
  end
  proc:write('{"id":2,"method":"shutdown","params":{}}\n')
  proc:write(nil)
  local done = proc:wait(PROBE_TIMEOUT_MS)
  local ping = nil
  local organization = nil
  for _, line in ipairs(vim.split(done.stdout or '', '\n', { plain = true, trimempty = true })) do
    local decoded_ok, frame = pcall(vim.json.decode, line)
    if decoded_ok and type(frame) == 'table' and frame.id == 1 then
      ping = frame
    elseif decoded_ok and type(frame) == 'table' and frame.id == 3 then
      organization = frame
    end
  end
  if ping == nil or ping.ok ~= true then
    fail(entries, 'the sidecar did not answer a ping', vim.trim(done.stderr or ''))
    return
  end
  ok(entries, 'sidecar answers: nvime-agent ' .. tostring(ping.result.agentVersion))
  report_claude(entries, ping.result)
  if config.get().organization.control_plane_url ~= nil then
    report_organization(entries, organization)
  else
    info(entries, 'community mode: no organization control plane configured')
  end
end

--- A big change's local merge writes a commit; with no identity configured
--- that write fails outright (the P4 gate-reviewer refusal this exists for).
--- Skipped, not failed, outside a git repository — there is nothing to check.
--- @class GitProbe
--- @field root string|nil the repository root, or nil outside one
--- @field name string|nil
--- @field email string|nil
--- @field err string|nil why the probe could not answer at all

--- @param entries DiagnosticEntry[]
--- @param probed GitProbe
local function report_git_identity(entries, probed)
  if probed.root == nil then
    info(entries, 'not inside a git repository — nothing to check for identity')
    return
  end
  -- A probe that never answered is a different problem with a different fix
  -- from a repository that genuinely has no identity set.
  if probed.err ~= nil then
    fail(entries, 'git identity could not be read: ' .. probed.err, 'check that `git` responds: git config user.name')
    return
  end
  if probed.name == nil or probed.name == '' or probed.email == nil or probed.email == '' then
    fail(
      entries,
      'git has no identity configured for ' .. probed.root,
      "git config user.name '<name>' && git config user.email '<email>'"
    )
    return
  end
  ok(entries, string.format('git identity: %s <%s>', probed.name, probed.email))
end

--- Lists every lane whose model/effort dial is not the CLI default, config or
--- a session-scoped `:Nvime model` override alike — informational, since a
--- non-default dial is a deliberate choice, not a problem to fix.
local function check_model_dial(entries)
  local active = models.summary()
  if #active == 0 then
    local floors = {}
    for _, lane in ipairs(config.GATE_LANES) do
      floors[#floors + 1] = string.format('%s (effort %s)', lane, config.defaults.models[lane].effort)
    end
    info(entries, 'model dial: CLI default everywhere except ' .. table.concat(floors, ', '))
    return
  end
  info(entries, 'model dial: ' .. table.concat(active, '  '))
end

--- The debug log's own row: what a bug report can be asked to attach. A log
--- that could not be opened is a WARNING that names the file — reporting it as
--- plain "off" reads as a user setting rather than as the failure it is.
--- @return DiagnosticEntry
function M.log_entry()
  local status = require('nvime.log').status()
  if status.broken ~= nil then
    return {
      level = 'warn',
      message = string.format(
        'debug log: stopped — %s (%s)',
        status.broken_reason or 'the file could not be opened',
        status.broken
      ),
      advice = 'check the directory exists and is writable, then :Nvime debug on',
    }
  end
  if status.level == 'off' then
    return {
      level = 'info',
      message = 'debug log: off — :Nvime debug on starts one at ' .. status.path,
    }
  end
  return {
    level = 'info',
    message = string.format('debug log: level %s · %s · %d bytes', status.level, status.path, status.size),
  }
end

--- Runs a probe the way every check here does: bounded, and answering the
--- error rather than raising it. BLOCKING — `:Nvime bundle` uses
--- `probe_async` instead, since the binary it asks about may be the hung one.
--- @param cmd string[]
--- @param timeout_ms integer|nil
--- @return string|nil output, string|nil error
function M.probe(cmd, timeout_ms)
  assert(type(cmd) == 'table' and #cmd > 0, 'diagnostics.probe needs a command')
  return run(cmd, timeout_ms or PROBE_TIMEOUT_MS)
end

--- The same probe without the wait: `cb(output, err)` is called exactly once,
--- on the reply or on the deadline. A binary that never answers costs
--- `timeout_ms`, not the editor.
--- @param cmd string[]
--- @param timeout_ms integer
--- @param cb fun(output: string|nil, err: string|nil)
function M.probe_async(cmd, timeout_ms, cb)
  assert(type(cmd) == 'table' and #cmd > 0, 'diagnostics.probe_async needs a command')
  assert(type(timeout_ms) == 'number' and timeout_ms > 0, 'diagnostics.probe_async needs a deadline')
  assert(type(cb) == 'function', 'diagnostics.probe_async needs a callback')
  local settled, timer = false, nil
  local function settle(output, err)
    if settled then
      return
    end
    settled = true
    if timer ~= nil then
      timer:stop()
      timer:close()
      timer = nil
    end
    cb(output, err)
  end
  local spawned, proc = pcall(vim.system, cmd, { text = true }, function(done)
    vim.schedule(function()
      if done.code ~= 0 then
        settle(nil, vim.trim((done.stderr or '') .. (done.stdout or '')))
        return
      end
      settle(vim.trim(done.stdout or ''), nil)
    end)
  end)
  if not spawned then
    settle(nil, tostring(proc))
    return
  end
  -- The deadline has to be ours: `vim.system`'s own `timeout` waits for the
  -- child's pipes to close, and a grandchild still holding them (`sh -c` that
  -- spawned something) never lets that happen. Answering `nil, nil` is what
  -- tells the caller this was a deadline, not a failure it can quote.
  timer = vim.uv.new_timer()
  timer:start(timeout_ms, 0, function()
    vim.schedule(function()
      -- SIGKILL, and only the direct child: this is a version probe, not a
      -- teardown, and a shim that backgrounded something keeps running.
      pcall(function()
        proc:kill('sigkill')
      end)
      settle(nil, nil)
    end)
  end)
end

--- Everything the checks need from the machine, gathered on the main thread.
--- @param root string
--- @param timeout_ms integer
--- @return table { node = NodeProbe, git = GitProbe }
local function probe_machine(root, timeout_ms, git)
  local node = config.get().agent.node
  local probed = { node = { found = vim.fn.executable(node) == 1 }, git = { root = vim.fs.root(root, { '.git' }) } }
  if probed.node.found then
    probed.node.version, probed.node.err = run({ node, '--version' }, timeout_ms)
  end
  if probed.git.root ~= nil then
    local name, name_err = run({ git, '-C', probed.git.root, 'config', 'user.name' }, timeout_ms)
    local email, email_err = run({ git, '-C', probed.git.root, 'config', 'user.email' }, timeout_ms)
    probed.git.name, probed.git.email = name, email
    -- An unset identity answers with an empty value and an empty error; only a
    -- probe that could not run at all reports one.
    probed.git.err = timeout_error(name_err) or timeout_error(email_err)
  end
  return probed
end

--- The same, without the wait: three probes at once, `cb(probed)` when the
--- last has answered or missed its deadline. What `:Nvime bundle` uses, since
--- the binary it is asking about is the one most likely to be hung.
--- @param root string
--- @param timeout_ms integer
--- @param cb fun(probed: table)
local function probe_machine_async(root, timeout_ms, cb, git)
  local node = config.get().agent.node
  local probed = { node = { found = vim.fn.executable(node) == 1 }, git = { root = vim.fs.root(root, { '.git' }) } }
  local wanted = {}
  if probed.node.found then
    wanted[#wanted + 1] = { cmd = { node, '--version' }, into = probed.node, key = 'version' }
  end
  if probed.git.root ~= nil then
    for _, field in ipairs({ 'name', 'email' }) do
      wanted[#wanted + 1] = {
        cmd = { git, '-C', probed.git.root, 'config', 'user.' .. field },
        into = probed.git,
        key = field,
      }
    end
  end
  local outstanding = #wanted
  if outstanding == 0 then
    cb(probed)
    return
  end
  for _, probe in ipairs(wanted) do
    M.probe_async(probe.cmd, timeout_ms, function(output, err)
      probe.into[probe.key] = output
      if probe.key == 'version' then
        probe.into.err = err or 'timed out'
      elseif output == nil then
        probe.into.err = probe.into.err or timeout_error(err) or nil
      end
      outstanding = outstanding - 1
      if outstanding == 0 then
        cb(probed)
      end
    end)
  end
end

--- Reports the sidecar this editor already has, without starting one. What
--- `:Nvime bundle` gets instead of a second spawn: the diagnostic question
--- there is "what is the sidecar I am talking to doing", not "can one start".
local function report_live_sidecar(entries)
  if agent().is_running() then
    ok(entries, 'sidecar: running for this Neovim instance (not probed — no second one was started)')
    return
  end
  info(entries, 'sidecar: not running for this Neovim instance')
end

--- Renders every check from what the probes found. No I/O of its own beyond
--- cheap stats — and the sidecar spawn, which `skip_sidecar` leaves out.
--- @return DiagnosticEntry[]
--- @return table facts
local function assemble(probed, skip_sidecar)
  local entries, facts = {}, {}
  check_neovim(entries)
  check_keymaps(entries)
  local exit = agent().last_exit()
  if exit ~= nil and exit.code ~= 0 then
    warn(entries, 'the sidecar exited with code ' .. tostring(exit.code), exit.stderr)
  end
  facts.node = report_node(entries, probed.node)
  if facts.node ~= nil and check_build(entries) then
    if skip_sidecar then
      report_live_sidecar(entries)
    else
      check_sidecar(entries)
    end
  end
  check_login_file(entries)
  report_git_identity(entries, probed.git)
  check_model_dial(entries)
  entries[#entries + 1] = M.log_entry()
  return entries, facts
end

--- Runs every check and returns what each found, in the order a reader should
--- see them. BLOCKING, like `:checkhealth` — both callers are a user
--- deliberately asking "why doesn't this work". Never raises: a probe that
--- cannot run is a failure of that probe, not a crash of the command.
--- @param root string|nil where to check git identity from; defaults to cwd
--- @param opts table|nil skip_sidecar, probe_timeout_ms, and `git` (the binary
--- to ask, so a test can point it at a shim)
--- @return DiagnosticEntry[]
--- @return table facts machine-readable values the probes already paid for
function M.run(root, opts)
  opts = opts or {}
  local timeout_ms = opts.probe_timeout_ms or PROBE_TIMEOUT_MS
  local probed = probe_machine(root or vim.uv.cwd(), timeout_ms, opts.git or 'git')
  return assemble(probed, opts.skip_sidecar == true)
end

--- The same checks with nothing on the main thread. Always skips the sidecar
--- spawn — that one genuinely blocks, and the only caller (`:Nvime bundle`)
--- must not start a second sidecar anyway.
--- @param root string|nil
--- @param timeout_ms integer
--- @param cb fun(entries: DiagnosticEntry[], facts: table)
function M.run_async(root, timeout_ms, cb)
  assert(type(cb) == 'function', 'diagnostics.run_async needs a callback')
  probe_machine_async(root or vim.uv.cwd(), timeout_ms, function(probed)
    cb(assemble(probed, true))
  end, 'git')
end

return M
