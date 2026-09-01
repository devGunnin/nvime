local t = require('harness')
local config = require('nvime.config')

local describe, it, eq = t.describe, t.it, t.eq

describe('config.setup', function()
  it('returns the defaults when given nothing', function()
    local opts = config.setup(nil)
    eq(80, opts.panel.width)
    eq(false, opts.keymaps.enabled)
    eq('node', opts.agent.node)
  end)

  it('merges nested tables rather than replacing them', function()
    local opts = config.setup({ panel = { width = 120 } })
    eq(120, opts.panel.width)
    eq(3, opts.panel.prompt_height, 'untouched keys keep their default')
  end)

  it('is the single source of truth for the live options', function()
    config.setup({ panel = { width = 55 } })
    eq(55, config.get().panel.width)
  end)

  it('defaults project instructions to on', function()
    local opts = config.setup(nil)
    eq(true, opts.project_instructions.enabled)
  end)

  it('lets project instructions be turned off', function()
    local opts = config.setup({ project_instructions = { enabled = false } })
    eq(false, opts.project_instructions.enabled)
    config.setup(nil)
  end)

  it('rejects out-of-range and wrongly-typed options', function()
    t.throws(function()
      config.setup({ panel = { width = 5 } })
    end, 'panel.width')
    t.throws(function()
      config.setup({ panel = { position = 'above' } })
    end, 'panel.position')
    t.throws(function()
      config.setup({ keymaps = { enabled = 'yes' } })
    end, 'keymaps.enabled')
    t.throws(function()
      config.setup({ context = { max_file_bytes = 10 } })
    end, 'max_file_bytes')
    t.throws(function()
      config.setup({ agent = { request_timeout_ms = 10 } })
    end, 'request_timeout_ms')
    t.throws(function()
      config.setup('nope')
    end, 'expected a table')
    t.throws(function()
      config.setup({ project_instructions = { enabled = 'yes' } })
    end, 'project_instructions.enabled')
  end)

  it('leaves the previous options in place when validation fails', function()
    config.setup({ panel = { width = 90 } })
    pcall(config.setup, { panel = { width = -1 } })
    eq(90, config.get().panel.width)
  end)
end)

describe('the models table', function()
  it('defaults every lane to the CLI default model, and every effort too — except the gate lanes', function()
    local opts = config.setup(nil)
    local gate = {}
    for _, lane in ipairs(config.GATE_LANES) do
      gate[lane] = true
    end
    for _, lane in ipairs(config.MODEL_LANES) do
      eq(nil, opts.models[lane].model, lane)
      if gate[lane] then
        -- The gate lanes never nil-inherit an ambient effort: unset means
        -- 'medium', not "whatever the CLI would otherwise pick".
        eq('medium', opts.models[lane].effort, lane)
      else
        eq(nil, opts.models[lane].effort, lane)
      end
    end
  end)

  it('rejects the dead `agent.model` key rather than silently ignoring it', function()
    t.throws(function()
      config.setup({ agent = { model = 'claude-haiku-5' } })
    end, 'agent%.model')
    config.setup(nil)
  end)

  it('sets one lane without disturbing the others', function()
    local opts = config.setup({ models = { big_build = { model = 'claude-opus-5', effort = 'high' } } })
    eq('claude-opus-5', opts.models.big_build.model)
    eq('high', opts.models.big_build.effort)
    eq(nil, opts.models.chat.model, 'an untouched lane keeps the default')
    config.setup(nil)
  end)

  it('takes any of the three efforts, and nothing else', function()
    for _, effort in ipairs(config.EFFORTS) do
      eq(effort, config.setup({ models = { chat = { effort = effort } } }).models.chat.effort)
    end
    t.throws(function()
      config.setup({ models = { chat = { effort = 'xhigh' } } })
    end, 'models%.chat%.effort')
    t.throws(function()
      config.setup({ models = { chat = { model = 5 } } })
    end, 'models%.chat%.model')
    config.setup(nil)
  end)

  it('refuses the gate lanes at effort low — grading is the gate, and triage decides what it reviews', function()
    for _, lane in ipairs(config.GATE_LANES) do
      t.throws(function()
        config.setup({ models = { [lane] = { effort = 'low' } } })
      end, lane)
      -- medium/high still work; low is the only refused value.
      eq('high', config.setup({ models = { [lane] = { effort = 'high' } } }).models[lane].effort)
      config.setup(nil)
    end
  end)
end)

describe('the gate difficulty', function()
  it('defaults to medium, as the design fixed', function()
    config.setup()
    eq('medium', config.get().big.difficulty)
    eq(false, config.get().big.cleanup_on_merge, 'the build clone is kept unless asked otherwise')
  end)

  it('takes any of the four the sidecar knows, and nothing else', function()
    for _, level in ipairs(config.DIFFICULTIES) do
      eq(level, config.setup({ big = { difficulty = level } }).big.difficulty)
    end
    t.throws(function()
      config.setup({ big = { difficulty = 'impossible' } })
    end, 'big.difficulty')
    t.throws(function()
      config.setup({ big = { difficulty = 90 } })
    end, 'big.difficulty')
    t.throws(function()
      config.setup({ big = { cleanup_on_merge = 'yes' } })
    end, 'cleanup_on_merge')
    config.setup()
  end)
end)
