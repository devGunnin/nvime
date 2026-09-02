--- `nvime.setup()` end to end. Deliberately named to sort LAST: it calls the
--- real `require('nvime').setup`, which pulls in every surface bound to
--- whichever agent module is installed right now — harmless as the final spec,
--- and a cross-spec contaminant anywhere earlier.
local t = require('harness')

local describe, it, eq = t.describe, t.it, t.eq

describe('setup re-sends the debug level to a live sidecar', function()
  -- F14: `init.setup` set the plugin's own level but never told a sidecar that
  -- was already running, so `setup{ debug = { level = 'debug' } }` against a
  -- live sidecar was half-applied, silently.
  it('tells a running sidecar the level setup just installed', function()
    local agent = require('nvime.agent')
    local log = require('nvime.log')
    local real = agent.set_debug_level
    local told = {}
    agent.set_debug_level = function(level)
      told[#told + 1] = level
    end
    -- `command_spec` installs a recorder in place of the module and leaves it
    -- there; this spec needs the real one.
    package.loaded['nvime'] = nil
    local finished, err = pcall(function()
      require('nvime').setup({ debug = { level = 'debug' } })
    end)
    agent.set_debug_level = real
    require('nvime.config').setup()
    log.set_level('off')
    if not finished then
      error(err, 0)
    end
    eq({ 'debug' }, told, 'the level must reach the sidecar half too')
  end)
end)
