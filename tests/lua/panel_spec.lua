local t = require('harness')
local config = require('nvime.config')
local palette = require('nvime.palette')
local panel = require('nvime.panel')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local function panel_opts()
  return {
    width = 40,
    prompt_height = 3,
    position = 'right',
    on_submit = function() end,
    on_cancel = function() end,
    on_history = function() end,
  }
end

local function open()
  panel.close()
  config.setup({})
  palette.apply()
  return panel.open(panel_opts())
end

local function lines()
  return vim.api.nvim_buf_get_lines(panel.current().buf, 0, -1, false)
end

local function marks()
  return vim.api.nvim_buf_get_extmarks(panel.current().buf, panel.NS, 0, -1, { details = true })
end

describe('panel', function()
  it('opens a scrollback and a separate prompt, and closes cleanly', function()
    local self = open()
    ok(panel.is_open())
    ok(vim.api.nvim_win_is_valid(self.win), 'the scrollback window is open')
    ok(vim.api.nvim_win_is_valid(self.prompt_win), 'the prompt window is open')
    ok(self.buf ~= self.prompt_buf, 'the prompt is a separate buffer')
    eq(40, vim.api.nvim_win_get_width(self.win))
    eq(false, vim.bo[self.buf].modifiable)
    panel.close()
    ok(not panel.is_open())
    ok(not vim.api.nvim_buf_is_valid(self.buf), 'buffers are cleaned up')
  end)

  it('reuses the panel instead of stacking splits', function()
    local first = open()
    local windows = #vim.api.nvim_list_wins()
    local second = panel.open(panel_opts())
    eq(first.buf, second.buf)
    eq(windows, #vim.api.nvim_list_wins(), 'a second open must not add windows')
    panel.close()
  end)

  it('renders streamed deltas token by token', function()
    open()
    panel.begin_stream()
    panel.push_delta('Hel')
    eq('Hel', lines()[#lines()])
    panel.push_delta('lo')
    eq('Hello', lines()[#lines()])
    panel.push_delta(' there\nand more')
    eq({ 'Hello there', 'and more' }, { lines()[#lines() - 1], lines()[#lines()] })
    panel.finish_stream()
    local rendered = lines()
    eq('claude', rendered[1])
    eq('Hello there', rendered[2])
    eq('and more', rendered[3])
    panel.close()
  end)

  it('never leaves a duplicated tail line behind', function()
    open()
    panel.begin_stream()
    panel.push_delta('one')
    panel.push_delta('\ntwo')
    panel.finish_stream()
    eq({ 'claude', 'one', 'two', '' }, lines())
    panel.close()
  end)

  it('highlights markdown as it streams', function()
    open()
    panel.begin_stream()
    panel.push_delta('# Heading\n')
    local heading = vim.tbl_filter(function(mark)
      return mark[4].hl_group == 'NvimeHeading'
    end, marks())
    eq(1, #heading)
    panel.finish_stream()
    panel.close()
  end)

  it('keeps a code fence together and marks it as code', function()
    open()
    panel.begin_stream()
    panel.push_delta('```lua\nlocal x = 1\n```\n')
    panel.finish_stream()
    eq({ 'claude', '```lua', 'local x = 1', '```', '' }, lines())
    local code = vim.tbl_filter(function(mark)
      return mark[4].hl_group == 'NvimeCode'
    end, marks())
    eq(1, #code)
    panel.close()
  end)

  it('places a tool line above the text that follows it', function()
    open()
    panel.begin_stream()
    panel.push_delta('before')
    panel.interject('  reading src/foo.py', 'NvimeDim')
    panel.push_delta('\nafter')
    panel.finish_stream()
    eq({ 'claude', 'before', '  reading src/foo.py', 'after', '' }, lines())
    panel.close()
  end)

  it('renders a finished markdown message', function()
    open()
    panel.append_markdown('# Title\ntext')
    eq({ '# Title', 'text' }, lines())
    panel.close()
  end)

  it('shows status and runs the activity indicator without blocking', function()
    local self = open()
    panel.status('session abcd1234')
    ok(vim.wo[self.win].winbar:find('abcd1234') ~= nil, 'the status reaches the winbar')
    panel.start_activity()
    ok(self.spinner ~= nil, 'the spinner timer is running')
    panel.stop_activity()
    eq(nil, self.spinner)
    panel.close()
  end)

  it('ignores writes when it is closed', function()
    panel.close()
    panel.append('nobody home')
    panel.push_delta('nobody home')
    panel.finish_stream()
    eq(nil, panel.current())
  end)
end)
