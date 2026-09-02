--- Lifecycle of the one sidecar process per Neovim instance.
---
--- Spawned lazily on first use and reused afterwards. Every failure the plugin
--- can hit before the sidecar is even reachable (no node, no build) is reported
--- as the same structured error shape the sidecar itself uses, so the panel has
--- exactly one way to render trouble.
local config = require('nvime.config')
local log = require('nvime.log')
local rpc = require('nvime.rpc')

local M = {}

local state = {
  client = nil,
  subscribers = {},
  last_exit = nil,
}

--- Repo root, derived from this file's own path so it works from any runtimepath.
function M.plugin_root()
  local source = debug.getinfo(1, 'S').source:sub(2)
  return vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(source))))
end

function M.agent_dir()
  return M.plugin_root() .. '/agent'
end

function M.dist_path()
  return M.agent_dir() .. '/dist/index.js'
end

function M.build_hint()
  return string.format('npm --prefix %s install && npm --prefix %s run build', M.agent_dir(), M.agent_dir())
end

--- @return table|nil error when the sidecar cannot be started at all
local function preflight()
  local opts = config.get()
  if vim.fn.executable(opts.agent.node) == 0 then
    return {
      code = 'node_missing',
      message = string.format("node was not found (looked for '%s')", opts.agent.node),
      detail = 'nvime needs Node >= 20 to run its agent sidecar',
    }
  end
  if vim.uv.fs_stat(M.dist_path()) == nil then
    return {
      code = 'not_built',
      message = 'the nvime sidecar has not been built yet',
      detail = M.build_hint(),
    }
  end
  local organization = opts.organization
  if organization.control_plane_url ~= nil and vim.fn.executable(organization.trust_core) == 0 then
    return {
      code = 'trust_core_missing',
      message = string.format("nvime trust core was not executable (looked for '%s')", organization.trust_core),
      detail = 'install the licensed nvime trust core for this platform, then run :Nvime doctor',
    }
  end
  if organization.control_plane_url ~= nil and vim.fn.executable(organization.github) == 0 then
    return {
      code = 'github_missing',
      message = string.format("GitHub CLI was not executable (looked for '%s')", organization.github),
      detail = 'install gh and run `gh auth login`',
    }
  end
  return nil
end

--- Where big-change sessions and their worktrees live. Under stdpath('data'),
--- so a build worktree is never inside the repo it was built from.
function M.big_root()
  return vim.fs.normalize(vim.fn.stdpath('data') .. '/nvime/big')
end

--- The settings the sidecar reads from its environment. `vim.system` merges
--- this over the inherited environment, so only what nvime configures appears.
--- `:checkhealth` probes with this too, so it cannot contradict a working chat.
function M.sidecar_env()
  local opts = config.get()
  local env = {
    NVIME_APPROVAL_TIMEOUT_MS = tostring(opts.edit.approval_timeout_ms),
    NVIME_BIG_ROOT = M.big_root(),
  }
  if opts.agent.claude ~= nil then
    env.NVIME_CLAUDE_PATH = opts.agent.claude
  end
  if opts.organization.control_plane_url ~= nil then
    env.NVIME_CONTROL_PLANE_URL = opts.organization.control_plane_url
    env.NVIME_TRUST_PATH = opts.organization.trust_core
    env.NVIME_GITHUB_PATH = opts.organization.github
    env.NVIME_IDENTITY_DIR = vim.fs.normalize(vim.fn.stdpath('data') .. '/nvime/identity')
  end
  return env
end

local function dispatch_event(name, params)
  for _, fn in ipairs(state.subscribers) do
    fn(name, params)
  end
end

--- Subscribe to server-pushed events. Returns an unsubscribe function.
--- @param fn fun(name: string, params: table)
function M.on_event(fn)
  assert(type(fn) == 'function', 'agent.on_event needs a function')
  table.insert(state.subscribers, fn)
  return function()
    for i, existing in ipairs(state.subscribers) do
      if existing == fn then
        table.remove(state.subscribers, i)
        return
      end
    end
  end
end

--- Starts the sidecar if it is not already up.
--- @param cb fun(err: table|nil)
function M.ensure(cb)
  assert(type(cb) == 'function', 'agent.ensure needs a callback')
  if state.client ~= nil and state.client:is_running() then
    cb(nil)
    return
  end
  local err = preflight()
  if err ~= nil then
    cb(err)
    return
  end
  local client = rpc.new({
    cmd = { config.get().agent.node, M.dist_path() },
    cwd = M.plugin_root(),
    env = M.sidecar_env(),
    on_event = dispatch_event,
    on_exit = function(code, stderr)
      state.client = nil
      state.last_exit = { code = code, stderr = stderr }
    end,
  })
  local started, start_err = client:start()
  if not started then
    cb({ code = 'spawn_failed', message = 'could not start the nvime sidecar', detail = start_err })
    return
  end
  state.client = client
  state.last_exit = nil
  -- A sidecar that starts while the log is on must mirror into it from its
  -- first frame, or half the timeline is missing exactly when it matters. A
  -- fresh sidecar is already off, so an off log costs it no frame at all.
  if log.level() ~= 'off' then
    M.set_debug_level(log.level())
  end
  cb(nil)
end

--- Tells the sidecar which level to mirror into the shared log file. A no-op
--- when the sidecar is not up: `ensure` sends it again on the next spawn.
--- @param level string one of `nvime.log`'s levels
function M.set_debug_level(level)
  assert(vim.tbl_contains(log.LEVELS, level), 'agent.set_debug_level needs a known level')
  if state.client == nil or not state.client:is_running() then
    return
  end
  -- A directory and this process's id, never a path: the sidecar builds the
  -- file name itself so it can refuse anything but its own.
  local params = { level = level, dir = vim.fs.dirname(log.path()), pid = vim.uv.os_getpid() }
  state.client:request('debug.set', params, function(err)
    if err ~= nil then
      vim.notify('nvime: the sidecar refused the debug level: ' .. tostring(err.message), vim.log.levels.WARN)
    end
  end, config.get().agent.request_timeout_ms)
end

--- Ensures the sidecar is up, then sends one request. Control requests carry
--- the configured deadline; only a streaming turn opts out of one.
--- @param method string
--- @param params table|nil
--- @param cb fun(err: table|nil, result: any)
--- @param opts table|nil on_sent(request_id) and no_deadline (a streaming turn)
function M.request(method, params, cb, opts)
  assert(type(cb) == 'function', 'agent.request needs a callback')
  opts = opts or {}
  local timeout_ms = nil
  if not opts.no_deadline then
    timeout_ms = config.get().agent.request_timeout_ms
  end
  M.ensure(function(err)
    if err ~= nil then
      cb(err, nil)
      return
    end
    local id = state.client:request(method, params, cb, timeout_ms)
    if id ~= nil and opts.on_sent ~= nil then
      opts.on_sent(id)
    end
  end)
end

function M.is_running()
  return state.client ~= nil and state.client:is_running()
end

function M.last_exit()
  return state.last_exit
end

function M.stop()
  if state.client ~= nil then
    state.client:stop()
    state.client = nil
  end
end

return M
