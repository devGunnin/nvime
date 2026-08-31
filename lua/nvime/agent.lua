--- Lifecycle of the one sidecar process per Neovim instance.
---
--- Spawned lazily on first use and reused afterwards. Every failure the plugin
--- can hit before the sidecar is even reachable (no node, no build) is reported
--- as the same structured error shape the sidecar itself uses, so the panel has
--- exactly one way to render trouble.
local config = require('nvime.config')
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
  return nil
end

local function sidecar_env()
  local opts = config.get()
  local env = {}
  if opts.agent.claude ~= nil then
    env.NVIME_CLAUDE_PATH = opts.agent.claude
  end
  if opts.agent.model ~= nil then
    env.NVIME_MODEL = opts.agent.model
  end
  return next(env) == nil and nil or env
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
    env = sidecar_env(),
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
  cb(nil)
end

--- Ensures the sidecar is up, then sends one request.
--- @param method string
--- @param params table|nil
--- @param cb fun(err: table|nil, result: any)
--- @param on_sent fun(request_id: integer)|nil receives the id, for cancellation
function M.request(method, params, cb, on_sent)
  M.ensure(function(err)
    if err ~= nil then
      cb(err, nil)
      return
    end
    local id = state.client:request(method, params, cb)
    if id ~= nil and on_sent ~= nil then
      on_sent(id)
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
