local t = require('harness')
local agent = require('nvime.agent')
local config = require('nvime.config')
local health = require('nvime.health')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local PING = vim.json.encode({
  id = 1,
  ok = true,
  result = {
    agentVersion = '0.1.0',
    claudePath = '/opt/homebrew/bin/claude',
    claudeVersion = '2.1.251',
    strippedEnv = { 'ANTHROPIC_API_KEY' },
  },
})

--- Runs `health.check` against a scripted world: no real node, no real sidecar,
--- no `claude`. Returns everything reported and every process it tried to spawn.
--- @param world table built (bool) and respond(cmd) -> completed process result
local function checkhealth(world)
  local reported, spawned = {}, {}
  local real = {
    health = vim.health,
    system = vim.system,
    executable = vim.fn.executable,
    fs_stat = vim.uv.fs_stat,
  }
  local function note(level)
    return function(message, advice)
      reported[#reported + 1] = { level = level, message = tostring(message), advice = advice }
    end
  end

  vim.health =
    { start = note('start'), ok = note('ok'), warn = note('warn'), error = note('error'), info = note('info') }
  vim.fn.executable = function(name)
    return name == config.get().agent.node and 1 or 0
  end
  vim.uv.fs_stat = function(path)
    if path == agent.dist_path() then
      return world.built and { type = 'file' } or nil
    end
    return real.fs_stat(path)
  end
  vim.system = function(cmd, opts)
    spawned[#spawned + 1] = { cmd = cmd, opts = opts }
    local result = world.respond(cmd)
    return {
      write = function() end,
      wait = function()
        return result
      end,
    }
  end

  local okay, err = pcall(health.check)
  vim.health, vim.system, vim.fn.executable, vim.uv.fs_stat = real.health, real.system, real.executable, real.fs_stat
  if not okay then
    error(err, 0)
  end
  return reported, spawned
end

--- node answers a version; anything else is the sidecar answering a ping.
local function healthy_world(built)
  return {
    built = built,
    respond = function(cmd)
      if cmd[2] == '--version' then
        return { code = 0, stdout = 'v22.22.2\n', stderr = '' }
      end
      return { code = 0, stdout = PING .. '\n', stderr = '' }
    end,
  }
end

local function find(reported, pattern)
  for _, entry in ipairs(reported) do
    if entry.message:find(pattern) ~= nil then
      return entry
    end
  end
  return nil
end

local function sidecar_spawn(spawned)
  for _, call in ipairs(spawned) do
    if call.cmd[2] == agent.dist_path() then
      return call
    end
  end
  return nil
end

describe('agent.sidecar_env', function()
  it('is nil when nothing is configured, so the sidecar simply inherits', function()
    config.setup({})
    eq(nil, agent.sidecar_env())
  end)

  it('carries the configured claude path and model', function()
    config.setup({ agent = { claude = '/opt/homebrew/bin/claude', model = 'claude-opus-5' } })
    eq({ NVIME_CLAUDE_PATH = '/opt/homebrew/bin/claude', NVIME_MODEL = 'claude-opus-5' }, agent.sidecar_env())
    config.setup({})
  end)
end)

describe('health.check', function()
  it('reports Neovim, keymaps, node, the build and the sidecar', function()
    config.setup({})
    local reported = checkhealth(healthy_world(true))
    ok(find(reported, '^nvime$') ~= nil, 'the section is started')
    ok(find(reported, 'Neovim') ~= nil)
    ok(find(reported, 'keymaps are leaf%-only') ~= nil)
    ok(find(reported, 'node v22%.22%.2') ~= nil)
    ok(find(reported, 'sidecar built') ~= nil)
    ok(find(reported, 'nvime%-agent 0%.1%.0') ~= nil, 'the ping answer is reported')
    ok(find(reported, 'claude 2%.1%.251') ~= nil)
  end)

  it('probes the sidecar with the configured claude path, not a bare env', function()
    -- The probe used to spawn with no env and report "claude not found" for a
    -- path chat resolves fine — a health check contradicting a working feature.
    config.setup({ agent = { claude = '/opt/homebrew/bin/claude' } })
    local _, spawned = checkhealth(healthy_world(true))
    local probe = sidecar_spawn(spawned)
    ok(probe ~= nil, 'the sidecar was probed')
    eq('/opt/homebrew/bin/claude', (probe.opts.env or {}).NVIME_CLAUDE_PATH)
    config.setup({})
  end)

  it('warns about stripped credentials instead of claiming a clean environment', function()
    config.setup({})
    local reported = checkhealth(healthy_world(true))
    local entry = find(reported, 'ANTHROPIC_API_KEY')
    ok(entry ~= nil, 'a set credential is named')
    eq('warn', entry.level)
  end)

  it('names the exact build command when the sidecar is not built', function()
    config.setup({})
    local reported, spawned = checkhealth(healthy_world(false))
    local entry = find(reported, 'not built')
    ok(entry ~= nil, 'a missing build is an error, not a silent skip')
    eq('error', entry.level)
    ok(entry.advice:find('npm', 1, true) ~= nil, 'and the advice is the command to run')
    eq(nil, sidecar_spawn(spawned), 'and nothing is spawned against a missing file')
  end)

  it('refuses a keymap that is a prefix of another in the same mode', function()
    -- The panel's `q` becomes a prefix of this, so `q` would stall for timeoutlen.
    config.setup({ keymaps = { chat = 'qq' } })
    local reported = checkhealth(healthy_world(true))
    local entry = find(reported, "is a prefix of '")
    ok(entry ~= nil, 'a stalling mapping must be reported')
    eq('error', entry.level)
    config.setup({})
  end)
end)
