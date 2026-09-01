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

  --- The panel names its buffer `nvime-<name>` with no `scheme://`, so the
  --- name resolves as a real relative path. If the user happens to have a
  --- file open under that exact name (e.g. `nvime-chat` in the project
  --- root), opening the panel used to force-delete their buffer — discarding
  --- unsaved edits — because the old reclaim logic could not tell nvime's
  --- own scratch buffer apart from a real one sharing its name.
  it('never force-deletes a real file the user has open under the panel’s own name', function()
    panel.close(NAME)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local before_cwd = vim.fn.getcwd()
    vim.fn.writefile({ 'the user is editing this real file' }, dir .. '/nvime-' .. NAME)
    vim.cmd.cd(dir)
    vim.cmd.edit('nvime-' .. NAME)
    local user_buf = vim.api.nvim_get_current_buf()
    vim.bo[user_buf].modifiable = true
    vim.api.nvim_buf_set_lines(user_buf, -1, -1, false, { 'UNSAVED WORK the user just typed' })
    ok(vim.bo[user_buf].modified, 'the probe needs a genuinely unsaved buffer')

    config.setup({})
    palette.apply()
    panel.open(panel_opts())

    ok(vim.api.nvim_buf_is_valid(user_buf), "the user's buffer must survive opening the panel")
    eq(
      { 'the user is editing this real file', 'UNSAVED WORK the user just typed' },
      vim.api.nvim_buf_get_lines(user_buf, 0, -1, false)
    )

    panel.close(NAME)
    vim.cmd.cd(before_cwd)
  end)

  --- With the real file still open, the panel's buffer falls back to the
  --- `nvime://` scheme (above). That fallback buffer is `bufhidden = 'hide'`,
  --- so it survives when the registry is dropped without a proper close (a
  --- `:bd` on the prompt buffer does this — `M.get` sees the invalid prompt
  --- and drops the whole entry). The next open collides on the plain name
  --- again, falls back again, and used to raise E95 unguarded because the
  --- surviving fallback buffer still held that name.
  it('does not raise when a second collision hits the nvime:// fallback name too', function()
    panel.close(NAME)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local before_cwd = vim.fn.getcwd()
    vim.fn.writefile({ 'the user is editing this real file' }, dir .. '/nvime-' .. NAME)
    vim.cmd.cd(dir)
    vim.cmd.edit('nvime-' .. NAME)
    local user_buf = vim.api.nvim_get_current_buf()

    config.setup({})
    palette.apply()
    local first = panel.open(panel_opts())
    ok(vim.api.nvim_buf_is_valid(first.buf), 'the fallback-named buffer opened')

    -- Drops the registry entry without deleting `first.buf`, which survives
    -- (bufhidden = 'hide') and still holds the fallback name.
    vim.api.nvim_buf_delete(first.prompt_buf, { force = true })
    ok(not panel.is_open(NAME), 'a half-wiped panel is treated as closed')
    ok(vim.api.nvim_buf_is_valid(first.buf), 'the survivor buffer is still there to collide with')

    local second = panel.open(panel_opts())
    ok(panel.is_open(NAME), 'the panel must still open on a second collision')
    ok(vim.api.nvim_buf_is_valid(second.buf))
    ok(vim.api.nvim_buf_is_valid(user_buf), "the user's real buffer is still untouched")

    panel.close(NAME)
    vim.cmd.cd(before_cwd)
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

  it('keeps a message surface behind prose without flattening code blocks', function()
    open()
    current():append_markdown('plain\n```lua\nlocal x = 1\n```', 'NvimeAgentBody')
    local prose, code = 0, 0
    for _, mark in ipairs(marks()) do
      prose = prose + (mark[4].line_hl_group == 'NvimeAgentBody' and 1 or 0)
      code = code + (mark[4].line_hl_group == 'NvimeCode' and 1 or 0)
    end
    eq(1, prose, 'ordinary prose has the agent surface')
    eq(1, code, 'the fenced body keeps the stronger code surface')
    panel.close(NAME)
  end)

  it('extends a streaming message surface across every completed line', function()
    open()
    current():begin_stream('claude', 'NvimeAgentBody')
    current():push_delta('first\nsecond')
    current():finish_stream()
    local surfaced = vim.tbl_filter(function(mark)
      return mark[4].line_hl_group == 'NvimeAgentBody'
    end, marks())
    eq(2, #surfaced)
    eq({ 'first', 'second' }, { lines()[2], lines()[3] })
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

  --- A code block is set apart by its GROUND, not by a grammar applied once
  --- the fence closes: that re-highlight was the one thing that changed a
  --- line's colour after it had already been read, which is what this whole
  --- surface now forbids. A tool line still lands mid-fence without breaking
  --- the block's classification.
  it('keeps a fence interrupted by a tool line as one code block, uncoloured by a grammar', function()
    open()
    current():begin_stream('claude')
    current():push_delta('```lua\nlocal a = 1\n')
    current():interject('  reading src/foo.py', 'NvimeDim')
    current():push_delta('local b = 2\n```\n')
    current():finish_stream()

    eq({ 'claude', '```lua', 'local a = 1', '  reading src/foo.py', 'local b = 2', '```', '' }, lines())
    local code = vim.tbl_filter(function(mark)
      return mark[4].line_hl_group == 'NvimeCode'
    end, marks())
    eq(2, #code, 'both code lines keep the code ground')
    for _, mark in ipairs(marks()) do
      ok(
        mark[4].hl_group == nil or mark[4].hl_group:sub(1, 1) ~= '@',
        'no grammar group may appear: ' .. tostring(mark[4].hl_group)
      )
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

--- Everything the operator reported about the conversation surface, pinned.
describe('panel — the calm surface', function()
  --- Every extmark on one row, as plain comparable data.
  local function row_marks(row)
    local out = {}
    for _, mark in
      ipairs(vim.api.nvim_buf_get_extmarks(current().buf, panel.NS, { row, 0 }, { row, -1 }, {
        details = true,
      }))
    do
      local details = mark[4]
      out[#out + 1] = {
        col = mark[3],
        end_col = details.end_col,
        hl = details.hl_group,
        line_hl = details.line_hl_group,
        conceal = details.conceal,
      }
    end
    table.sort(out, function(a, b)
      return (a.col == b.col) and tostring(a.hl) < tostring(b.hl) or a.col < b.col
    end)
    return out
  end

  --- No vim syntax paints the scrollback: nvime classifies every line itself,
  --- and `markdown` here let `htmlStrike` put a line through `~~x~~` and
  --- markdownRule colour a `---` under nvime's own fg-only extmarks.
  it('gives the scrollback a filetype with no syntax of its own', function()
    local self = open()
    eq('nvime', vim.bo[self.buf].filetype)
    eq('markdown', vim.bo[self.prompt_buf].filetype)
    -- Concealing markers is right for rendered output and wrong for a prompt
    -- the reader is typing markdown into.
    eq(2, vim.wo[self.win].conceallevel)
    eq('nvic', vim.wo[self.win].concealcursor)
    eq(0, vim.wo[self.prompt_win].conceallevel)
    panel.close(NAME)
  end)

  it('draws a thematic break as a short gap, never a rule across the panel', function()
    local self = open()
    self:append_markdown('before\n---\nafter')
    eq({ 'before', '  · · ·', 'after' }, lines())
    panel.close(NAME)
  end)

  --- The hard rule: a line must not change colour as it stops being volatile.
  it('paints a streamed line exactly as it paints the committed one', function()
    local self = open()
    local text = '## Heading with **bold**, `code` and ~~struck~~ text'
    self:begin_stream('claude')
    self:push_delta(text)
    local streamed_row = self.stream.tail_row
    local streamed = row_marks(streamed_row)
    ok(#streamed > 0, 'a streamed line carries marks of its own')
    self:push_delta('\n')
    self:finish_stream()
    eq(streamed, row_marks(streamed_row), 'the groups changed when the line committed')
    panel.close(NAME)
  end)

  it('keeps a code line the same group before and after its fence closes', function()
    local self = open()
    self:begin_stream(nil)
    self:push_delta('```lua\nlocal x = 1')
    local row = self.stream.tail_row
    local streaming = row_marks(row)
    self:push_delta('\n```\n')
    self:finish_stream()
    eq(streaming, row_marks(row), 'closing the fence re-coloured the code above it')
    panel.close(NAME)
  end)

  --- The choice block's JSON is a payload for the widget, never something to
  --- read: the panel swallows the fence whole, streaming or replayed.
  it('swallows an options fence rather than showing its JSON', function()
    local self = open()
    self:append_markdown('pick one\n```nvime-options\n{"options":[{"label":"a"},{"label":"b"}]}\n```\ndone')
    eq({ 'pick one', 'done' }, lines())
    panel.close(NAME)
  end)

  it('swallows an options fence as it streams, one delta at a time', function()
    local self = open()
    self:begin_stream(nil)
    for _, chunk in ipairs({ 'pick one\n```nvime-o', 'ptions\n{"options":', '[]}\n``', '`\ndone' }) do
      self:push_delta(chunk)
    end
    self:finish_stream()
    eq({ 'pick one', 'done', '' }, lines())
    panel.close(NAME)
  end)

  it('appends composed lines with their own spans in one pass', function()
    local self = open()
    local row = self:append_marked({ 'goal  ship it', 'note' }, {
      { row = 1, col = 0, end_col = 6, hl = 'NvimeDim' },
      { row = 1, col = 6, end_col = 13, hl = 'NvimeBody' },
    })
    eq(0, row)
    eq({ 'goal  ship it', 'note' }, lines())
    eq(
      { 'NvimeDim', 'NvimeBody' },
      vim.tbl_map(function(mark)
        return mark.hl
      end, row_marks(0))
    )
    panel.close(NAME)
  end)

  it('rewrites a committed run in place instead of appending a second copy', function()
    local self = open()
    self:append_marked({ '1  a', '2  b' }, { { row = 1, col = 0, end_col = 1, hl = 'NvimeOptionKey' } })
    self:rewrite(0, { '1 x a', '2   b' }, { { row = 1, col = 0, end_col = 3, hl = 'NvimeSelected' } })
    eq({ '1 x a', '2   b' }, lines())
    eq({ { col = 0, end_col = 3, hl = 'NvimeSelected', line_hl = nil, conceal = nil } }, row_marks(0))
    panel.close(NAME)
  end)

  it('refuses to rewrite past the end of the scrollback', function()
    local self = open()
    self:append_marked({ 'only' }, {})
    t.throws(function()
      self:rewrite(0, { 'a', 'b' }, {})
    end, 'past the end')
    panel.close(NAME)
  end)

  --- `append_marked` writes several rows at once, like `replace`/`rewrite` —
  --- mid-stream it would land in the middle of the volatile tail row those
  --- two already refuse to touch.
  it('refuses to append a marked block while a stream is open, like replace and rewrite do', function()
    local self = open()
    self:begin_stream(nil)
    t.throws(function()
      self:append_marked({ 'only' }, {})
    end, 'stream is open')
    self:finish_stream()
    panel.close(NAME)
  end)

  it('runs an after_stream callback right away when nothing is streaming', function()
    local self = open()
    local ran = false
    self:after_stream(function()
      ran = true
    end)
    eq(true, ran)
    panel.close(NAME)
  end)

  it('queues an after_stream callback until the open stream closes', function()
    local self = open()
    self:begin_stream(nil)
    eq(true, self:is_streaming())
    local ran = false
    self:after_stream(function()
      ran = true
    end)
    eq(false, ran, 'must not run while the stream is still open')
    self:push_delta('mid-stream text')
    eq(false, ran, 'a delta alone must not release it')
    self:finish_stream()
    eq(false, self:is_streaming())
    eq(true, ran, 'released the moment the stream closes')
    panel.close(NAME)
  end)
end)

--- A `line_hl_group` sits OVER an extmark's foreground, so pinning the body
--- colour that way silently flattened every heading, marker and struck span on
--- the line. The body colour is a low-priority span for exactly that reason.
describe('panel — the body colour never eats its own markup', function()
  local function groups_on(row)
    local out = {}
    for _, mark in
      ipairs(vim.api.nvim_buf_get_extmarks(current().buf, panel.NS, { row, 0 }, { row, -1 }, {
        details = true,
      }))
    do
      if mark[4].hl_group ~= nil then
        out[#out + 1] = { mark[4].hl_group, mark[4].priority }
      end
    end
    return out
  end

  it('leaves a heading its accent and a struck span its own strikethrough group', function()
    local self = open()
    self:append_markdown('## Findings')
    self:append_markdown('the ~~simplest~~ option')
    eq({ { 'NvimeBody', 90 }, { 'NvimeDim', 4096 }, { 'NvimeHeading', 4096 } }, groups_on(0))
    eq({ { 'NvimeBody', 90 }, { 'NvimeStrike', 4096 } }, groups_on(1))
    panel.close(NAME)
  end)
end)
