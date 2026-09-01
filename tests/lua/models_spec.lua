local t = require('harness')
local compose = require('nvime.compose')
local config = require('nvime.config')
local models = require('nvime.models')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Invokes the buffer-local normal-mode mapping the user would press.
local function press(buf, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.lhs == lhs and map.callback ~= nil then
      map.callback()
      return true
    end
  end
  return false
end

describe('models.dial', function()
  it('falls back to the configured default when no override is set', function()
    config.setup({ models = { chat = { model = 'claude-opus-5', effort = 'high' } } })
    models.reset_all()
    eq({ model = 'claude-opus-5', effort = 'high' }, models.dial('chat'))
    config.setup(nil)
  end)

  it('prefers a session override over the configured default', function()
    config.setup({ models = { chat = { model = 'claude-opus-5', effort = 'high' } } })
    models.set('chat', 'claude-sonnet-5', 'low')
    eq({ model = 'claude-sonnet-5', effort = 'low' }, models.dial('chat'))
    models.reset('chat')
    eq({ model = 'claude-opus-5', effort = 'high' }, models.dial('chat'), 'reset falls back to config')
    config.setup(nil)
  end)

  it('refuses an unknown lane', function()
    t.throws(function()
      models.dial('nope')
    end, 'unknown lane')
    t.throws(function()
      models.set('nope', 'x', nil)
    end, 'unknown lane')
    t.throws(function()
      models.reset('nope')
    end, 'unknown lane')
  end)

  it('refuses to set a gate lane at effort low — grading is the gate, triage decides what it reviews', function()
    for _, lane in ipairs(config.GATE_LANES) do
      t.throws(function()
        models.set(lane, nil, 'low')
      end, "'low'")
      -- medium/high still work; low is the only refused value.
      models.set(lane, nil, 'high')
      eq('high', models.dial(lane).effort)
      models.reset(lane)
    end
  end)

  it('layers a session override over the config: only the field actually chosen replaces it', function()
    config.setup({ models = { big_grade = { model = 'claude-opus-5', effort = 'high' } } })
    -- Picking only a new model (effort left at 'default', i.e. nil) must not
    -- discard the configured effort.
    models.set('big_grade', 'claude-sonnet-5', nil)
    eq({ model = 'claude-sonnet-5', effort = 'high' }, models.dial('big_grade'), 'the configured effort must survive')
    models.reset('big_grade')

    -- And the other way round: picking only an effort must not discard the
    -- configured model.
    models.set('big_grade', nil, 'medium')
    eq({ model = 'claude-opus-5', effort = 'medium' }, models.dial('big_grade'), 'the configured model must survive')
    models.reset('big_grade')
    config.setup(nil)
  end)
end)

describe('models.active and models.summary', function()
  it('is inactive when neither config nor override names anything', function()
    config.setup(nil)
    models.reset_all()
    eq(false, models.active('chat'))
    eq({}, models.summary())
  end)

  it('is active once either half of the dial is set', function()
    config.setup(nil)
    models.reset_all()
    models.set('big_build', 'claude-opus-5', nil)
    eq(true, models.active('big_build'))
    eq({ 'big_build:claude-opus-5/-' }, models.summary())
    models.reset('big_build')
  end)

  it('lists every active lane, in MODEL_LANES order', function()
    config.setup(nil)
    models.reset_all()
    models.set('explain', 'claude-haiku-5', 'low')
    models.set('chat', nil, 'medium')
    eq({ 'chat:-/medium', 'explain:claude-haiku-5/low' }, models.summary())
    models.reset('chat')
    models.reset('explain')
  end)
end)

describe('models.open (the :Nvime model picker)', function()
  it('lists every lane and, on choosing one, opens a model input', function()
    config.setup(nil)
    models.reset_all()
    local win = models.open()
    ok(win ~= nil and vim.api.nvim_win_is_valid(win), 'the lane picker opened')
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    eq(#config.MODEL_LANES, #lines)
    ok(lines[1]:find('chat', 1, true) ~= nil, lines[1])
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, true, true), 'x', false)
    local float = compose.current()
    ok(float ~= nil, 'choosing a lane opens the model text box')
    compose.dismiss()
  end)

  it('types a model, picks an effort, and commits a session override', function()
    config.setup(nil)
    models.reset_all()
    local win = models.open()
    vim.api.nvim_win_set_cursor(win, { 1, 0 }) -- chat is first
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, true, true), 'x', false)
    local float = compose.current()
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, { 'claude-opus-5' })
    vim.cmd('stopinsert')
    press(float.buf, '<CR>')

    -- The effort picker is now the current window: pick 'high'.
    local effort_win = vim.api.nvim_get_current_win()
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(effort_win), 0, -1, false)
    local target = nil
    for row, line in ipairs(lines) do
      if line == ' high' then
        target = row
      end
    end
    ok(target ~= nil, 'high is offered: ' .. vim.inspect(lines))
    vim.api.nvim_win_set_cursor(effort_win, { target, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, true, true), 'x', false)

    eq({ model = 'claude-opus-5', effort = 'high' }, models.dial('chat'))
    models.reset('chat')
  end)

  it("excludes low from a gate lane's effort choices", function()
    for _, gate_lane in ipairs(config.GATE_LANES) do
      config.setup(nil)
      models.reset_all()
      local win = models.open()
      local gate_row = nil
      for row, lane in ipairs(config.MODEL_LANES) do
        if lane == gate_lane then
          gate_row = row
        end
      end
      vim.api.nvim_win_set_cursor(win, { gate_row, 0 })
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, true, true), 'x', false)
      local float = compose.current()
      vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, { 'default' })
      vim.cmd('stopinsert')
      press(float.buf, '<CR>')

      local effort_win = vim.api.nvim_get_current_win()
      local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(effort_win), 0, -1, false)
      for _, line in ipairs(lines) do
        ok(line ~= ' low', 'low must not be offered for ' .. gate_lane .. ': ' .. line)
      end
      vim.api.nvim_win_close(effort_win, true)
    end
  end)

  it("'reset' clears a session override back to the configured default", function()
    config.setup(nil)
    models.set('chat', 'claude-opus-5', 'high')
    local win = models.open()
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, true, true), 'x', false)
    local float = compose.current()
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, { 'default' })
    vim.cmd('stopinsert')
    press(float.buf, '<CR>')

    local effort_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(effort_win, { 1, 0 }) -- 'reset' is always first
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, true, true), 'x', false)

    eq({ model = nil, effort = nil }, models.dial('chat'))
  end)
end)

models.reset_all()
