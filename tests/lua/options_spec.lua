local t = require('harness')
local config = require('nvime.config')
local options = require('nvime.options')
local palette = require('nvime.palette')
local panel = require('nvime.panel')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local NAME = 'chat'

local function open()
  panel.close(NAME)
  config.setup({})
  palette.apply()
  return panel.open({
    name = NAME,
    width = 60,
    prompt_height = 3,
    position = 'right',
    on_submit = function() end,
  })
end

local function lines(self)
  return vim.api.nvim_buf_get_lines(self.buf, 0, -1, false)
end

--- A block of `count` choices, as the sidecar would have handed it over.
local function raw(count, extra)
  local list = {}
  for index = 1, count do
    list[index] = { label = 'choice ' .. index }
  end
  return vim.tbl_extend('force', { prompt = 'pick one', options = list }, extra or {})
end

describe('options.parse', function()
  it('takes a well-formed block, defaulting what the model left out', function()
    local block = options.parse({ options = { { label = 'a' }, { label = 'b', detail = 'why b' } } })
    eq('a', block.options[1].label)
    eq('why b', block.options[2].detail)
    eq(nil, block.options[1].detail)
    eq(false, block.multi)
    eq(nil, block.prompt)
  end)

  it('accepts a bare string as a label, which is what a terse model sends', function()
    eq(
      { 'a', 'b' },
      vim.tbl_map(function(option)
        return option.label
      end, options.parse({ options = { 'a', 'b' } }).options)
    )
  end)

  --- The block crosses a process boundary, so every one of these is a payload
  --- the panel could actually be handed. None of them may raise.
  it('refuses anything it cannot render, rather than half-rendering it', function()
    eq(nil, options.parse(nil))
    eq(nil, options.parse('choose'))
    eq(nil, options.parse({}))
    eq(nil, options.parse({ options = 'a, b' }))
    eq(nil, options.parse({ options = {} }), 'no choices is not a choice')
    eq(nil, options.parse({ options = { { label = 'only' } } }), 'one choice is not a choice')
    eq(nil, options.parse({ options = { { label = 'a' }, { label = '  ' } } }), 'an unlabelled entry')
    eq(nil, options.parse({ options = { { label = 'a' }, 7 } }), 'a non-entry')
    eq(nil, options.parse(raw(options.MAX_OPTIONS + 1)), 'more than a reader can take in')
    ok(options.parse(raw(options.MAX_OPTIONS)) ~= nil, 'exactly the cap is still fine')
  end)
end)

describe('options.lines', function()
  it('numbers the choices and names the keys that answer them', function()
    local block = options.parse(raw(3))
    local rendered = options.lines(block)
    eq({
      '  pick one',
      '  1  choice 1',
      '  2  choice 2',
      '  3  choice 3',
      '  1-3 picks · o for something else',
    }, rendered)
  end)

  it('puts a detail on its own dim line, aligned under the label it explains', function()
    local block = options.parse({ options = { { label = 'a', detail = 'what a means' }, { label = 'b' } } })
    local rendered, marks = options.lines(block)
    eq('  1  a', rendered[1])
    eq('     what a means', rendered[2])
    eq('NvimeDim', marks[3].hl)
    eq(2, marks[3].row)

    -- A toggle box widens the key, so the detail has to move with it.
    local multi =
      options.parse({ options = { { label = 'a', detail = 'what a means' }, { label = 'b' } }, multi = true })
    local toggled = options.lines(multi)
    eq('  1    a', toggled[1])
    eq('       what a means', toggled[2])
    eq(toggled[1]:find('a'), toggled[2]:find('what'), 'the detail aligns under the label')
  end)

  --- Only nine choices can have a single-keypress binding, so a longer list
  --- has to say how the rest are reached rather than silently not working.
  it('tells the reader how to reach a choice past the ninth', function()
    local hint = options.lines(options.parse(raw(11)))[13]
    ok(hint:match('1%-9 picks') ~= nil, hint)
    ok(hint:match('type a number for the rest') ~= nil, hint)
  end)

  it('marks a toggled choice as chosen, and keeps the labels aligned either way', function()
    local block = options.parse(raw(2, { multi = true }))
    local off = options.lines(block)
    local on = options.lines(block, { [1] = true })
    eq('  1    choice 1', off[2])
    eq('  1 ✓  choice 1', on[2])
    eq(vim.fn.strdisplaywidth(off[2]), vim.fn.strdisplaywidth(on[2]), 'a tick must not shift the label')
    eq('NvimeOptionKey', select(2, options.lines(block))[2].hl)
    eq('NvimeSelected', select(2, options.lines(block, { [1] = true }))[2].hl)
  end)

  it('says <CR> sends only when more than one choice can be picked', function()
    ok(options.hint(options.parse(raw(2, { multi = true }))):match('<CR> sends') ~= nil)
    eq(nil, options.hint(options.parse(raw(2))):match('<CR> sends'))
  end)
end)

describe('options.reply and options.pick_from_text', function()
  it('reads back as the choice, not as the number that made it', function()
    local block = options.parse({ options = { { label = 'keep the schema' }, { label = 'add options' } } })
    eq('2: add options', options.reply(block, { 2 }))
    eq('→ 2: add options', options.echo(options.reply(block, { 2 })))
  end)

  it('takes a typed number as the pick it plainly is', function()
    local block = options.parse(raw(3))
    eq('2: choice 2', options.pick_from_text(block, '2'))
    eq('2: choice 2', options.pick_from_text(block, ' 2 '))
  end)

  it('sends anything else as the reader’s own words', function()
    local block = options.parse(raw(3))
    eq(nil, options.pick_from_text(block, 'none of those'))
    eq(nil, options.pick_from_text(block, '4'), 'a number outside the list is not a pick')
    eq(nil, options.pick_from_text(block, '0'))
    eq(nil, options.pick_from_text(block, '2.5'))
    eq(nil, options.pick_from_text(block, ''))
    eq(nil, options.pick_from_text(block, '1 2'), 'several picks need a multi block')
  end)

  it('takes several typed numbers on a multi block, in the offered order', function()
    local block = options.parse(raw(4, { multi = true }))
    eq('1: choice 1, 3: choice 3', options.pick_from_text(block, '3, 1'))
    eq(nil, options.pick_from_text(block, '1 1'), 'a repeat is not a list')
  end)
end)

describe('options.attach', function()
  it('writes the block, then answers on a digit and gives the keys back', function()
    local self = open()
    local block = options.parse(raw(2))
    local answered = nil
    options.attach(self, block, function(reply)
      answered = reply
    end, function() end)
    ok(vim.tbl_contains(lines(self), '  1  choice 1'), 'the choices are in the scrollback')

    local before = #lines(self)
    vim.api.nvim_win_set_buf(self.win, self.buf)
    vim.api.nvim_set_current_win(self.win)
    vim.api.nvim_feedkeys('1', 'x', false)
    eq('1: choice 1', answered)
    eq(before, #lines(self), 'answering must not append another copy of the block')
    ok(vim.fn.maparg('1', 'n') == '', 'the digit keys are released once answered')
    panel.close(NAME)
  end)

  it('toggles a multi block in place and sends the picks on <CR>', function()
    local self = open()
    local block = options.parse(raw(3, { multi = true }))
    local answered = nil
    local handle = options.attach(self, block, function(reply)
      answered = reply
    end, function() end)
    vim.api.nvim_set_current_win(self.win)

    vim.api.nvim_feedkeys('3', 'x', false)
    vim.api.nvim_feedkeys('1', 'x', false)
    eq({ [1] = true, [3] = true }, handle.chosen)
    ok(vim.tbl_contains(lines(self), '  1 ✓  choice 1'), 'the toggled row shows it')
    eq(nil, answered, 'a toggle is not an answer')

    vim.api.nvim_feedkeys('\r', 'x', false)
    eq('1: choice 1, 3: choice 3', answered)
    panel.close(NAME)
  end)

  it('sends nothing when <CR> comes with nothing toggled', function()
    local self = open()
    local answered = false
    options.attach(self, options.parse(raw(2, { multi = true })), function()
      answered = true
    end, function() end)
    vim.api.nvim_set_current_win(self.win)
    vim.api.nvim_feedkeys('\r', 'x', false)
    eq(false, answered)
    panel.close(NAME)
  end)

  it('hands the reader back to the prompt on o, without answering', function()
    local self = open()
    local answered, other = false, false
    options.attach(self, options.parse(raw(2)), function()
      answered = true
    end, function()
      other = true
    end)
    vim.api.nvim_set_current_win(self.win)
    vim.api.nvim_feedkeys('o', 'x', false)
    eq(true, other)
    eq(false, answered)
    ok(vim.fn.maparg('o', 'n') == '', 'the keys go back once the reader takes over')
    panel.close(NAME)
  end)

  it('detaches without answering, so a new turn cannot be answered by an old block', function()
    local self = open()
    local answered = false
    local handle = options.attach(self, options.parse(raw(2)), function()
      answered = true
    end, function() end)
    handle.detach()
    vim.api.nvim_set_current_win(self.win)
    vim.api.nvim_feedkeys('1', 'x', false)
    eq(false, answered)
    panel.close(NAME)
  end)

  it('binds only the nine digits a keypress can reach', function()
    local self = open()
    options.attach(self, options.parse(raw(11)), function() end, function() end)
    vim.api.nvim_set_current_win(self.win)
    ok(vim.fn.maparg('9', 'n') ~= '', 'the ninth choice has a key')
    -- There is no tenth digit; the reader types the number in the prompt.
    eq(options.DIGIT_KEYS, 9)
    panel.close(NAME)
  end)
end)
