local t = require('harness')
local config = require('nvime.config')
local palette = require('nvime.palette')
local panel = require('nvime.panel')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local NAME = 'chat'

local function panel_opts()
  return {
    name = NAME,
    width = 40,
    prompt_height = 3,
    position = 'right',
    on_submit = function() end,
  }
end

local function open()
  panel.close(NAME)
  config.setup({})
  palette.apply()
  return panel.open(panel_opts())
end

local function current()
  return panel.get(NAME)
end

local function lines()
  return vim.api.nvim_buf_get_lines(current().buf, 0, -1, false)
end

local function marks()
  return vim.api.nvim_buf_get_extmarks(current().buf, panel.NS, 0, -1, { details = true })
end

describe('panel', function()
  it('opens a scrollback and a separate prompt, and closes cleanly', function()
    local self = open()
    ok(panel.is_open(NAME))
    ok(vim.api.nvim_win_is_valid(self.win), 'the scrollback window is open')
    ok(vim.api.nvim_win_is_valid(self.prompt_win), 'the prompt window is open')
    ok(self.buf ~= self.prompt_buf, 'the prompt is a separate buffer')
    eq(40, vim.api.nvim_win_get_width(self.win))
    eq(false, vim.bo[self.buf].modifiable)
    panel.close(NAME)
    ok(not panel.is_open(NAME))
    ok(not vim.api.nvim_buf_is_valid(self.buf), 'buffers are cleaned up')
  end)

  it('reuses the panel instead of stacking splits', function()
    local first = open()
    local windows = #vim.api.nvim_list_wins()
    local second = panel.open(panel_opts())
    eq(first.buf, second.buf)
    eq(windows, #vim.api.nvim_list_wins(), 'a second open must not add windows')
    panel.close(NAME)
  end)

  it('reopens after the prompt split was closed with :q', function()
    local first = open()
    current():append('earlier turn')
    vim.api.nvim_win_close(first.prompt_win, true)
    ok(not vim.api.nvim_win_is_valid(first.prompt_win))

    local second = panel.open(panel_opts())
    eq(first.buf, second.buf, 'the conversation buffer survives')
    ok(vim.api.nvim_win_is_valid(second.prompt_win), 'the prompt split is back')
    ok(vim.api.nvim_win_is_valid(second.win), 'and so is the scrollback')
    eq({ 'earlier turn' }, lines(), 'with the scrollback intact')
    panel.close(NAME)
  end)

  it('reopens after the scrollback split was closed, rather than writing off-screen', function()
    local first = open()
    vim.api.nvim_win_close(first.win, true)
    local second = panel.open(panel_opts())
    ok(vim.api.nvim_win_is_valid(second.win), 'the conversation is displayed again')
    ok(vim.api.nvim_win_is_valid(second.prompt_win))
    eq(second.prompt_win, vim.api.nvim_get_current_win(), 'and the prompt takes focus')
    panel.close(NAME)
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
    panel.close(NAME)
  end)

  it('rebuilds from scratch when a buffer was wiped out from under it', function()
    local first = open()
    vim.api.nvim_buf_delete(first.prompt_buf, { force = true })
    ok(not panel.is_open(NAME), 'half a panel is not an open panel')
    local second = panel.open(panel_opts())
    ok(panel.is_open(NAME))
    ok(second.buf ~= first.buf, 'a fresh pair of buffers')
    ok(vim.api.nvim_buf_is_valid(second.prompt_buf))
    panel.close(NAME)
  end)

  it('stops the spinner of a panel wiped from under it, instead of leaking it', function()
    local self = open()
    self:start_activity()
    ok(self.spinner ~= nil, 'the probe needs a running timer')
    vim.api.nvim_buf_delete(self.buf, { force = true })
    eq(nil, panel.get(NAME), 'the husk is dropped')
    eq(nil, self.spinner, 'and its timer with it — nothing else can reach it afterwards')
    panel.close(NAME)
  end)

  it('renders streamed deltas token by token', function()
    open()
    current():begin_stream('claude')
    current():push_delta('Hel')
    eq('Hel', lines()[#lines()])
    current():push_delta('lo')
    eq('Hello', lines()[#lines()])
    current():push_delta(' there\nand more')
    eq({ 'Hello there', 'and more' }, { lines()[#lines() - 1], lines()[#lines()] })
    current():finish_stream()
    local rendered = lines()
    eq('claude', rendered[1])
    eq('Hello there', rendered[2])
    eq('and more', rendered[3])
    panel.close(NAME)
  end)

  it('never leaves a duplicated tail line behind', function()
    open()
    current():begin_stream('claude')
    current():push_delta('one')
    current():push_delta('\ntwo')
    current():finish_stream()
    eq({ 'claude', 'one', 'two', '' }, lines())
    panel.close(NAME)
  end)

  it('highlights markdown as it streams', function()
    open()
    current():begin_stream('claude')
    current():push_delta('# Heading\n')
    local heading = vim.tbl_filter(function(mark)
      return mark[4].hl_group == 'NvimeHeading'
    end, marks())
    eq(1, #heading)
    current():finish_stream()
    panel.close(NAME)
  end)

  it('keeps a code fence together and marks it as code', function()
    open()
    current():begin_stream('claude')
    current():push_delta('```lua\nlocal x = 1\n```\n')
    current():finish_stream()
    eq({ 'claude', '```lua', 'local x = 1', '```', '' }, lines())
    local code = vim.tbl_filter(function(mark)
      return mark[4].line_hl_group == 'NvimeCode'
    end, marks())
    eq(1, #code)
    panel.close(NAME)
  end)

  it('places a tool line above the text that follows it', function()
    open()
    current():begin_stream('claude')
    current():push_delta('before')
    current():interject('  reading src/foo.py', 'NvimeDim')
    current():push_delta('\nafter')
    current():finish_stream()
    eq({ 'claude', 'before', '  reading src/foo.py', 'after', '' }, lines())
    panel.close(NAME)
  end)

  it('renders a finished markdown message', function()
    open()
    current():append_markdown('# Title\ntext')
    eq({ '# Title', 'text' }, lines())
    panel.close(NAME)
  end)

  it('shows status and runs the activity indicator without blocking', function()
    local self = open()
    current():status('session abcd1234')
    ok(vim.wo[self.win].winbar:find('abcd1234') ~= nil, 'the status reaches the winbar')
    current():start_activity()
    ok(self.spinner ~= nil, 'the spinner timer is running')
    current():stop_activity()
    eq(nil, self.spinner)
    panel.close(NAME)
  end)

  it('anchors treesitter highlights to the rows the code really landed on', function()
    ok(pcall(vim.treesitter.get_string_parser, 'local a = 1', 'lua'), 'needs the bundled lua parser')
    open()
    current():begin_stream('claude')
    current():push_delta('```lua\nlocal a = 1\n')
    -- A tool line lands between the two statements, so the fence is not contiguous.
    current():interject('  reading src/foo.py', 'NvimeDim')
    current():push_delta('local b = 2\n```\n')
    current():finish_stream()

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
    panel.close(NAME)
  end)

  it('tells its owner before it tears the surface down', function()
    local closed = 0
    local opts = panel_opts()
    opts.on_close = function()
      closed = closed + 1
    end
    panel.close(NAME)
    config.setup({})
    panel.open(opts)
    panel.close(NAME)
    eq(1, closed, 'the owner gets one chance to stop a running turn')
    panel.close(NAME)
    eq(1, closed, 'and is not told again once the panel is gone')
  end)

  it('hands out nothing once it is closed, and a second close is harmless', function()
    open()
    panel.close(NAME)
    eq(nil, current())
    panel.close(NAME)
    eq(nil, current())
  end)

  it('keeps two named panels open side by side', function()
    panel.close(NAME)
    panel.close('edit')
    config.setup({})
    local chat = panel.open(panel_opts())
    local edit = panel.open({ name = 'edit', width = 40, position = 'right', prompt = false })
    ok(chat.buf ~= edit.buf, 'each panel owns its own scrollback')
    eq(nil, edit.prompt_buf, 'a read-only panel has no prompt')
    edit:append('editing queue.py')
    eq({ 'editing queue.py' }, vim.api.nvim_buf_get_lines(edit.buf, 0, -1, false))
    eq({ '' }, vim.api.nvim_buf_get_lines(chat.buf, 0, -1, false), 'and writes do not leak between them')
    panel.close('edit')
    ok(panel.is_open(NAME), 'closing one leaves the other open')
    panel.close(NAME)
  end)

  it('still opens, and completion still works, when the root has a malformed .gitignore', function()
    local completion = require('nvime.completion')
    local dir = vim.fs.normalize(vim.fn.tempname())
    vim.fn.mkdir(dir, 'p')
    vim.fn.writefile({ 'x' }, dir .. '/keep.py')
    -- `[]]` is legitimate git syntax (a literal `]`) that this repo's matcher
    -- used to reject at match time, crashing the walk this panel triggers.
    vim.fn.writefile({ '[]]*.txt' }, dir .. '/.gitignore')
    completion.invalidate(dir)

    panel.close(NAME)
    config.setup({})
    palette.apply()
    local opts = panel_opts()
    opts.root = dir
    local self = panel.open(opts)

    ok(panel.is_open(NAME), 'a bad .gitignore pattern must not stop the panel from opening')
    ok(vim.api.nvim_win_is_valid(self.win), 'the scrollback window is open')
    ok(vim.api.nvim_win_is_valid(self.prompt_win), 'the prompt window is open')

    ok(
      vim.wait(3000, function()
        return completion.ready(dir)
      end, 10),
      'completion must recover rather than stay stuck loading'
    )
    ok(vim.tbl_contains(completion.candidates(dir, ''), 'keep.py'), 'completion still works for everything else')

    panel.close(NAME)
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('panel following', function()
  it('stays glued to the tail when one delta commits many lines at once', function()
    local self_ = open()
    vim.api.nvim_win_set_height(self_.win, 5)
    current():begin_stream('claude')
    current():push_delta(('a\nb\nc\nd\ne\nf\ng\nh\n'):rep(4))
    current():push_delta('tail')
    local last = vim.api.nvim_buf_line_count(self_.buf)
    eq(last, vim.api.nvim_win_get_cursor(self_.win)[1], 'a multi-line delta must not unpin the panel')
    current():finish_stream()
    panel.close(NAME)
  end)

  it('stops following once the reader scrolls up, and resumes at the tail', function()
    local self_ = open()
    current():begin_stream('claude')
    current():push_delta(('line\n'):rep(30))
    vim.api.nvim_set_current_win(self_.win)
    vim.api.nvim_win_set_cursor(self_.win, { 2, 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = self_.buf })
    current():push_delta('more\n')
    eq(2, vim.api.nvim_win_get_cursor(self_.win)[1], 'the reader keeps their place')

    vim.api.nvim_win_set_cursor(self_.win, { vim.api.nvim_buf_line_count(self_.buf), 0 })
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = self_.buf })
    current():push_delta('again\n')
    eq(
      vim.api.nvim_buf_line_count(self_.buf),
      vim.api.nvim_win_get_cursor(self_.win)[1],
      'back at the tail means following again'
    )
    current():finish_stream()
    panel.close(NAME)
  end)
end)
