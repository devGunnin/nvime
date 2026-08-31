--- `:checkhealth nvime`.
---
--- This is the one place nvime blocks: a health report has to be synchronous,
--- and every probe below is a short, explicitly bounded subprocess. No editing
--- path ever waits on anything.
local agent = require('nvime.agent')
local config = require('nvime.config')
local keymaps = require('nvime.keymaps')

local M = {}

local PROBE_TIMEOUT_MS = 10000

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

local function check_neovim()
  if vim.fn.has('nvim-0.10') == 1 then
    vim.health.ok('Neovim ' .. tostring(vim.version()))
  else
    vim.health.error('nvime needs Neovim 0.10 or newer')
  end
end

local function check_node()
  local node = config.get().agent.node
  if vim.fn.executable(node) == 0 then
    vim.health.error(string.format("node not found (looked for '%s')", node), 'install Node 20 or newer')
    return false
  end
  local version, err = run({ node, '--version' }, PROBE_TIMEOUT_MS)
  if version == nil then
    vim.health.error('could not run node: ' .. tostring(err))
    return false
  end
  local major = tonumber(version:match('^v(%d+)'))
  if major == nil or major < 20 then
    vim.health.error('node ' .. version .. ' is too old', 'nvime needs Node 20 or newer')
    return false
  end
  vim.health.ok('node ' .. version)
  return true
end

local function check_build()
  local dist = agent.dist_path()
  if vim.uv.fs_stat(dist) == nil then
    vim.health.error('the sidecar is not built (' .. dist .. ' is missing)', agent.build_hint())
    return false
  end
  vim.health.ok('sidecar built: ' .. dist)
  return true
end

--- @param info table the sidecar's ping result
local function report_claude(info)
  if info.claudePath == nil then
    vim.health.error('the claude CLI was not found on PATH', 'install Claude Code and run `claude` once to sign in')
    return
  end
  vim.health.ok(string.format('claude %s at %s', tostring(info.claudeVersion), info.claudePath))
  if #(info.strippedEnv or {}) > 0 then
    vim.health.warn(
      'these variables are set and are being stripped: ' .. table.concat(info.strippedEnv, ', '),
      'nvime is subscription-only and never forwards an API key'
    )
  else
    vim.health.ok('subscription auth: no API key in the environment')
  end
  local running = agent.is_running()
  if running then
    vim.health.info('a sidecar is already running for this Neovim instance')
  end
  -- The login is only truly proven by a turn, so report what has been observed
  -- rather than guessing from credential files.
  vim.health.info('claude login is confirmed by the first chat turn; run `:Nvime chat` to verify it')
end

--- Starts the sidecar, pings it, and shuts it down again. Uses the same env as
--- a real spawn, or the probe would deny a `claude` that chat resolves fine.
local function check_sidecar()
  local node = config.get().agent.node
  local ok, proc = pcall(vim.system, { node, agent.dist_path() }, {
    stdin = true,
    text = true,
    env = agent.sidecar_env(),
  })
  if not ok then
    vim.health.error('could not start the sidecar: ' .. tostring(proc))
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
    vim.health.error('the sidecar did not answer a ping', vim.trim(done.stderr or ''))
    return
  end
  vim.health.ok('sidecar answers: nvime-agent ' .. tostring(ping.result.agentVersion))
  report_claude(ping.result)
end

local function check_keymaps()
  local conflicts = keymaps.conflicts(keymaps.all(config.get()))
  if #conflicts == 0 then
    vim.health.ok('keymaps are leaf-only (no mapping is a prefix of another)')
    return
  end
  for _, clash in ipairs(conflicts) do
    vim.health.error(
      string.format("'%s' is a prefix of '%s' in mode %s", clash.short.lhs, clash.long.lhs, clash.short.mode),
      'change one of them, or the shorter mapping stalls for timeoutlen'
    )
  end
end

function M.check()
  vim.health.start('nvime')
  check_neovim()
  check_keymaps()
  local exit = agent.last_exit()
  if exit ~= nil and exit.code ~= 0 then
    vim.health.warn('the sidecar exited with code ' .. tostring(exit.code), exit.stderr)
  end
  if check_node() and check_build() then
    check_sidecar()
  end
end

return M
