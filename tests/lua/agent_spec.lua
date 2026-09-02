local t = require('harness')
local config = require('nvime.config')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local real_agent = require('nvime.agent')
local real_rpc = package.loaded['nvime.rpc']

--- A client that records requests instead of speaking to a process, so the
--- lifecycle layer can be driven without node and without a login.
local spawned = {}
package.loaded['nvime.rpc'] = {
  new = function(opts)
    local client = { opts = opts, requests = {} }
    function client:start()
      return true, nil
    end
    function client:is_running()
      return true
    end
    function client:request(method, _params, _cb, timeout_ms)
      self.requests[#self.requests + 1] = { method = method, timeout_ms = timeout_ms }
      return 100 + #self.requests
    end
    function client:stop() end
    spawned[#spawned + 1] = client
    return client
  end,
}
package.loaded['nvime.agent'] = nil
local agent = require('nvime.agent')

--- Runs `fn` with the sidecar reported as built, whether or not it is.
local function with_build(fn)
  local real_stat = vim.uv.fs_stat
  vim.uv.fs_stat = function(path)
    if path == agent.dist_path() then
      return { type = 'file' }
    end
    return real_stat(path)
  end
  local okay, err = pcall(fn)
  vim.uv.fs_stat = real_stat
  agent.stop()
  spawned = {}
  if not okay then
    error(err, 0)
  end
end

local function client()
  eq(1, #spawned, 'exactly one sidecar per Neovim instance')
  return spawned[1]
end

describe('agent paths', function()
  it('finds the repo from this file, not from the cwd', function()
    local root = agent.plugin_root()
    ok(vim.uv.fs_stat(root .. '/lua/nvime/agent.lua') ~= nil, 'got ' .. root)
    eq(root .. '/agent/dist/index.js', agent.dist_path())
    ok(agent.build_hint():find('npm', 1, true) ~= nil, 'the hint is a runnable command')
  end)
end)

describe('agent.sidecar_env', function()
  it('carries the approval deadline and omits the overrides that are unset', function()
    config.setup({})
    local env = agent.sidecar_env()
    eq('60000', env.NVIME_APPROVAL_TIMEOUT_MS, 'the sidecar must not invent its own approval deadline')
    eq(nil, env.NVIME_CLAUDE_PATH)
  end)

  it('passes only public managed endpoints and local executable paths', function()
    config.setup({
      organization = {
        control_plane_url = 'http://127.0.0.1:4817',
        trust_core = '/bin/true',
        github = '/bin/true',
      },
    })
    local env = agent.sidecar_env()
    eq('http://127.0.0.1:4817', env.NVIME_CONTROL_PLANE_URL)
    eq('/bin/true', env.NVIME_TRUST_PATH)
    eq('/bin/true', env.NVIME_GITHUB_PATH)
    ok(env.NVIME_IDENTITY_DIR:match('/nvime/identity$') ~= nil, env.NVIME_IDENTITY_DIR)
    eq(nil, env.NVIME_SUBMIT_TOKEN, 'no shared attestation secret enters the editor process')
    config.setup({})
  end)

  it('reaches the spawned sidecar', function()
    config.setup({ agent = { claude = '/opt/homebrew/bin/claude' } })
    with_build(function()
      agent.request('ping', nil, function() end)
      eq('/opt/homebrew/bin/claude', client().opts.env.NVIME_CLAUDE_PATH)
    end)
    config.setup({})
  end)
end)

describe('agent.request', function()
  it('gives a control request the configured deadline', function()
    config.setup({ agent = { request_timeout_ms = 4321 } })
    with_build(function()
      agent.request('chat.list', { root = '/x' }, function() end)
      eq(4321, client().requests[1].timeout_ms)
    end)
    config.setup({})
  end)

  it('leaves a streaming turn without one', function()
    config.setup({})
    with_build(function()
      agent.request('chat.send', { root = '/x' }, function() end, { no_deadline = true })
      eq(nil, client().requests[1].timeout_ms, 'a turn may take minutes; only the user stops it')
    end)
  end)

  it('hands the request id back for cancellation', function()
    config.setup({})
    with_build(function()
      local seen = nil
      agent.request('chat.send', nil, function() end, {
        no_deadline = true,
        on_sent = function(id)
          seen = id
        end,
      })
      eq(101, seen)
    end)
  end)

  it('reports a missing build as a structured error, never a crash', function()
    config.setup({})
    local real_stat = vim.uv.fs_stat
    vim.uv.fs_stat = function(path)
      if path == agent.dist_path() then
        return nil
      end
      return real_stat(path)
    end
    local seen = nil
    agent.request('ping', nil, function(err)
      seen = err
    end)
    vim.uv.fs_stat = real_stat
    ok(seen ~= nil, 'the callback fires rather than the caller hanging')
    eq('not_built', seen.code)
    eq(0, #spawned, 'and nothing was spawned')
  end)
end)

package.loaded['nvime.rpc'] = real_rpc
package.loaded['nvime.agent'] = real_agent

describe('setup reaches a sidecar that is already running', function()
  local t2 = require('harness')

  --- `require('nvime')` pulls in every surface, binding each to whichever
  --- `nvime.*` modules are loaded right now — and other specs leave fakes
  --- there. Snapshot the whole namespace and put it back, so this spec cannot
  --- decide what a later one sees. (Round 2, G16: `setup()` is idempotent at
  --- runtime; it was only ever the harness that needed the isolation.)
  local function with_isolated_modules(fn)
    local snapshot = {}
    for name, module in pairs(package.loaded) do
      if name == 'nvime' or name:match('^nvime%.') ~= nil then
        snapshot[name] = module
      end
    end
    local finished, err = pcall(fn)
    for name in pairs(package.loaded) do
      if name == 'nvime' or name:match('^nvime%.') ~= nil then
        package.loaded[name] = nil
      end
    end
    for name, module in pairs(snapshot) do
      package.loaded[name] = module
    end
    if not finished then
      error(err, 0)
    end
  end

  -- F14 (round 1): `init.setup` installed the plugin's own level but never
  -- told a sidecar that was already up, so `setup{ debug = { level = ... } }`
  -- was half-applied, silently.
  t2.it('tells a running sidecar the level setup just installed', function()
    local told = {}
    with_isolated_modules(function()
      local live = require('nvime.agent')
      local real = live.set_debug_level
      live.set_debug_level = function(level)
        told[#told + 1] = level
      end
      local finished, err = pcall(function()
        require('nvime').setup({ debug = { level = 'debug' } })
      end)
      live.set_debug_level = real
      require('nvime.log').set_level('off')
      require('nvime.config').setup()
      if not finished then
        error(err, 0)
      end
    end)
    t2.eq({ 'debug' }, told, 'the level must reach the sidecar half too')
  end)
end)
