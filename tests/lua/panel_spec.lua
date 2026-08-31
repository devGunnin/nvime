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

  it('reopens after the prompt split was closed with :q', function()
    local first = open()
    panel.append('earlier turn')
    vim.api.nvim_win_close(first.prompt_win, true)
    ok(not vim.api.nvim_win_is_valid(first.prompt_win))

    local second = panel.open(panel_opts())
    eq(first.buf, second.buf, 'the conversation buffer survives')
    ok(vim.api.nvim_win_is_valid(second.prompt_win), 'the prompt split is back')
    ok(vim.api.nvim_win_is_valid(second.win), 'and so is the scrollback')
    eq({ 'earlier turn' }, lines(), 'with the scrollback intact')
    panel.close()
  end)

  it('reopens after the scrollback split was closed, rather than writing off-screen', function()
    local first = open()
    vim.api.nvim_win_close(first.win, true)
    local second = panel.open(panel_opts())
    ok(vim.api.nvim_win_is_valid(second.win), 'the conversation is displayed again')
    ok(vim.api.nvim_win_is_valid(second.prompt_win))
    eq(second.prompt_win, vim.api.nvim_get_current_win(), 'and the prompt takes focus')
    panel.close()
  end)

  it('reopens without doubling a buffer when the survivor is the tab last window', function()
    local first = open()
    vim.api.nvim_win_close(first.win, true)
    -- Close every other window in the tab so the prompt split becomes the
    -- last one — nvim refuses to close a tab's only window.
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if win ~= first.prompt_win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    eq(1, #vim.api.nvim_tabpage_list_wins(0), 'the prompt split really is the last window')

    local second = panel.open(panel_opts())
    eq(2, #vim.api.nvim_tabpage_list_wins(0), 'no stale window is left showing the old buffer twice')
    ok(vim.api.nvim_win_is_valid(second.win))
    ok(vim.api.nvim_win_is_valid(second.prompt_win))
    panel.close()
  end)

  it('rebuilds from scratch when a buffer was wiped out from under it', function()
    local first = open()
    vim.api.nvim_buf_delete(first.prompt_buf, { force = true })
    ok(not panel.is_open(), 'half a panel is not an open panel')
    local second = panel.open(panel_opts())
    ok(panel.is_open())
    ok(second.buf ~= first.buf, 'a fresh pair of buffers')
    ok(vim.api.nvim_buf_is_valid(second.prompt_buf))
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

  it('anchors treesitter highlights to the rows the code really landed on', function()
    ok(pcall(vim.treesitter.get_string_parser, 'local a = 1', 'lua'), 'needs the bundled lua parser')
    open()
    panel.begin_stream()
    panel.push_delta('```lua\nlocal a = 1\n')
    -- A tool line lands between the two statements, so the fence is not contiguous.
    panel.interject('  reading src/foo.py', 'NvimeDim')
    panel.push_delta('local b = 2\n```\n')
    panel.finish_stream()

    local rendered = lines()
    eq({ 'claude', '```lua', 'local a = 1', '  reading src/foo.py', 'local b = 2', '```', '' }, rendered)
    for _, mark in ipairs(marks()) do
      if mark[4].hl_group == '@keyword' then
        ok(
          rendered[mark[2] + 1]:find('local', 1, true) ~= nil,
          'a keyword highlight landed on ' .. vim.inspect(rendered[mark[2] + 1])
        )
      end
    end
    panel.close()
  end)

  it('tells its owner before it tears the surface down', function()
    local closed = 0
    local opts = panel_opts()
    opts.on_close = function()
      closed = closed + 1
    end
    panel.close()
    config.setup({})
    panel.open(opts)
    panel.close()
    eq(1, closed, 'the owner gets one chance to stop a running turn')
    panel.close()
    eq(1, closed, 'and is not told again once the panel is gone')
  end)

  it('ignores writes when it is closed', function()
    panel.close()
    panel.append('nobody home')
    panel.push_delta('nobody home')
    panel.finish_stream()
    eq(nil, panel.current())
  end)
end)
