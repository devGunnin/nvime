--- The panel engine: a scrollback buffer plus an optional prompt buffer in a
--- vertical split. Streaming text lands line by line — completed lines are
--- committed once and never rewritten, only the volatile tail line is redrawn
--- as deltas arrive, so a long reply stays O(total) rather than O(lines^2).
---
--- Panels are instances keyed by name (`chat`, `edit`, `changeset`), so more
--- than one surface can be open at a time. `M.open` reuses the live panel of
--- that name rather than stacking splits.
local completion = require('nvime.completion')
local markdown = require('nvime.markdown')
local modes = require('nvime.modes')

local M = {}

local NS = vim.api.nvim_create_namespace('nvime.panel')
local SPINNER_MS = 90

--- Under every inline span, which run at the default priority: the line's own
--- ground and its base foreground are what a marker paints over, never the
--- other way round.
local LINE_PRIORITY = 90

local Panel = {}
Panel.__index = Panel

--- Live panels by name. A closed panel is removed, never left as a husk.
local panels = {}

local function write_lines(buf, first, last, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, first, last, false, lines)
  vim.bo[buf].modifiable = false
end

local function apply_spans(buf, row, spans, priority)
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, NS, row, span[1], {
      end_col = span[2],
      hl_group = span[3],
      priority = priority,
      strict = false,
    })
  end
end

--- The line's own foreground, under every inline span on it. A span, not a
--- `line_hl_group`: a line highlight sits OVER an extmark's foreground, so
--- pinning the body colour that way would flatten every heading and marker
--- painted on top of it.
local function apply_body_hl(buf, row, hl, text)
  if hl == nil then
    return
  end
  apply_spans(buf, row, { { 0, #text, hl } }, LINE_PRIORITY)
end

--- Paints `hl` across the whole rendered row, window width included.
local function apply_line_hl(buf, row, hl)
  if hl == nil then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, NS, row, 0, {
    line_hl_group = hl,
    priority = LINE_PRIORITY,
    strict = false,
  })
end

--- Renders the markup's own delimiters as nothing, so `**x**` reads as `x`
--- while the buffer still holds the text a reader might yank. Only the
--- scrollback window sets `conceallevel`; a panel without it just shows them.
local function apply_conceal(buf, row, ranges)
  for _, range in ipairs(ranges or {}) do
    vim.api.nvim_buf_set_extmark(buf, NS, row, range[1], {
      end_col = range[2],
      conceal = '',
      strict = false,
    })
  end
end

local function line_count(buf)
  return vim.api.nvim_buf_line_count(buf)
end

local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function buf_valid(buf)
  return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

--- The panel's live windows, as a dense list. `tbl_filter` iterates with
--- `pairs`, so a prompt-less panel's nil is skipped rather than truncating
--- the list the way `ipairs` over the literal would.
local function live_wins(self)
  return vim.tbl_filter(win_valid, { self.win, self.prompt_win })
end

--- How far from the last line still counts as "reading the tail".
local FOLLOW_SLACK = 2

--- Follows the tail unless the reader has scrolled up to look at something.
---
--- The decision is a remembered flag, not a fresh comparison of the cursor
--- against the line count: a single delta can commit several lines at once,
--- and re-deriving it would then see a cursor more than `FOLLOW_SLACK` behind
--- and unpin the panel for the rest of the run. `unpin_on_move` is what puts
--- the reader back in charge.
local function follow(self)
  -- The window can be showing something else entirely (the user opened a file
  -- over the panel), and its cursor is then no business of ours.
  if not self.pinned or not win_valid(self.win) or vim.api.nvim_win_get_buf(self.win) ~= self.buf then
    return
  end
  vim.api.nvim_win_set_cursor(self.win, { line_count(self.buf), 0 })
end

--- Re-pins whenever the reader's cursor is back at the tail, unpins when it
--- is not. `follow` moves the cursor itself, which lands here and re-pins.
local function unpin_on_move(self)
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = vim.api.nvim_create_augroup('NvimePanel:' .. self.name, { clear = true }),
    buffer = self.buf,
    desc = 'nvime: follow the stream only while the reader is at the tail',
    callback = function()
      if not win_valid(self.win) then
        return
      end
      local cursor = vim.api.nvim_win_get_cursor(self.win)[1]
      self.pinned = cursor >= line_count(self.buf) - FOLLOW_SLACK
    end,
  })
end

--- Appends `text` as a new last line. The very first write replaces the empty
--- line every fresh buffer starts with, so the panel never opens with a gap.
local function append_row(self, text)
  if self.written then
    local row = line_count(self.buf)
    write_lines(self.buf, row, row, { text })
    return row
  end
  self.written = true
  write_lines(self.buf, 0, 1, { text })
  return 0
end

--- What a thematic break is drawn as. A model reaching for `---` means "and
--- now something else"; a rule the width of the panel says far more than that,
--- so it becomes a short gap marker instead.
local function rendered(info, text)
  if info.kind ~= 'rule' then
    return text
  end
  local dot = require('nvime.icons').get().dot
  return '  ' .. dot .. ' ' .. dot .. ' ' .. dot
end

--- Appends one already-classified line and returns the row it landed on.
--- A line the classifier re-renders carries no columns of its own (only a
--- thematic break does, and it has neither spans nor conceal ranges).
local function commit(self, text, info)
  local rendered_text = rendered(info, text)
  local row = append_row(self, rendered_text)
  apply_line_hl(self.buf, row, info.line_hl)
  apply_body_hl(self.buf, row, info.body_hl, rendered_text)
  apply_spans(self.buf, row, info.spans)
  apply_conceal(self.buf, row, info.conceal)
  return row
end

--- A winbar evaluates `%{expr}` as vimscript on every redraw, and the status
--- text carries a session title the user typed or pasted.
--- @param text string
--- @return string
function M.escape_winbar(text)
  return (tostring(text):gsub('%%', '%%%%'))
end

local function set_winbar(self)
  if not win_valid(self.win) then
    return
  end
  local spinner = ''
  if self.spinner ~= nil then
    -- Wrapped, not indexed: the icon set can change under a running spinner.
    local frames = require('nvime.icons').get().spinner
    spinner = frames[(self.spinner_frame - 1) % #frames + 1] .. ' '
  end
  local shape = require('nvime.text')
  local hint = self.status_hint or ''
  -- Where the surface is goes left, what to press goes right, and the title is
  -- cut rather than allowed to push the keys off the bar.
  local room = vim.api.nvim_win_get_width(self.win) - vim.fn.strdisplaywidth(hint) - 5
  local title = shape.ellipsise(self.status_text or self.title, math.max(room, 10))
  vim.wo[self.win].winbar = '%#NvimeBar# '
    .. spinner
    .. M.escape_winbar(title)
    .. ' %=%#NvimeBarDim#'
    .. M.escape_winbar(hint)
    .. ' '
end

--- Reclaims a leftover buffer of the same name (the user wiped half a panel);
--- `nvim_buf_set_name` refuses a duplicate, which would brick every reopen.
--- The name has no `scheme://`, so it resolves as a real relative path —
--- `buftype == 'nofile'` is what tells nvime's own scratch buffer apart from
--- a real file a user happens to have open under the same name.
local function drop_stale(name)
  local existing = vim.fn.bufnr('^' .. name .. '$')
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) and vim.bo[existing].buftype == 'nofile' then
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end
end

local function make_buffer(name, filetype)
  drop_stale(name)
  local buf = vim.api.nvim_create_buf(false, true)
  -- `drop_stale` now leaves a real file's buffer alone, so the plain name can
  -- still be taken — nvim then refuses the duplicate (E95). Falling back to
  -- the `nvime://` scheme, which can never collide with a real path, keeps
  -- the panel opening instead of raising mid-open — but a leftover fallback
  -- buffer from an earlier collision needs the same reclaim, and the
  -- fallback set itself needs the same pcall guard, or a second collision
  -- raises unguarded.
  if not pcall(vim.api.nvim_buf_set_name, buf, name) then
    local fallback = 'nvime://' .. name
    drop_stale(fallback)
    pcall(vim.api.nvim_buf_set_name, buf, fallback)
  end
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  return buf
end

local function bind(buf, mode, lhs, fn, desc)
  vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
end

--- Which modes a prompt key is bound in. The prompt is left in insert after
--- every send, so a key advertised on that window has to answer there too —
--- but only a control chord may: binding a literal key (`]o`, `s`) in insert
--- would shadow the user's own typing.
--- @param lhs string
--- @return string[]
function M.prompt_modes(lhs)
  assert(type(lhs) == 'string' and lhs ~= '', 'panel.prompt_modes needs a key')
  if lhs:match('^<[Cc]%-[^>]+>$') == nil then
    return { 'n' }
  end
  return modes.PROMPT
end

--- Prompt text, then clear it ready for the next message.
local function take_prompt(self)
  local lines = vim.api.nvim_buf_get_lines(self.prompt_buf, 0, -1, false)
  local text = vim.trim(table.concat(lines, '\n'))
  write_lines(self.prompt_buf, 0, -1, { '' })
  vim.bo[self.prompt_buf].modifiable = true
  return text
end

--- Hands an unsent prompt back to the box — `take_prompt`'s counterpart, for a
--- prompt that was taken but never delivered.
--- Only when the box is empty: the user may have typed something else since,
--- and that must win.
--- @param text string
--- @return boolean whether the text is now in the box
function Panel:restore_prompt(text)
  assert(type(text) == 'string', 'panel:restore_prompt needs text')
  if self.prompt_buf == nil or not vim.api.nvim_buf_is_valid(self.prompt_buf) then
    return false
  end
  local current = vim.trim(table.concat(vim.api.nvim_buf_get_lines(self.prompt_buf, 0, -1, false), '\n'))
  if current ~= '' then
    return false
  end
  write_lines(self.prompt_buf, 0, -1, vim.split(text, '\n', { plain = true }))
  vim.bo[self.prompt_buf].modifiable = true
  return true
end

--- One space of left gutter, and a wrapped line that keeps its own indent —
--- the difference between a wall of text and something laid out.
---
--- Not 2: a tool/detail/status line opens with a literal two-space indent of
--- its own, and a wrapped continuation landing there reads as another one.
local WRAP_SHIFT = 4
M.WRAP_SHIFT = WRAP_SHIFT
local function tune_window(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].breakindent = true
  vim.wo[win].breakindentopt = 'shift:' .. WRAP_SHIFT
  vim.wo[win].statuscolumn = ' '
  vim.wo[win].fillchars = 'eob: '
  vim.wo[win].winhighlight = 'CursorLine:NvimeCursorLine'
  -- Explicit: `split` copies the window it splits from, so the prompt would
  -- otherwise inherit the scrollback's conceal and hide the reader's own `**`
  -- as they type it.
  vim.wo[win].conceallevel = 0
end

--- Scrollback only. `concealcursor` covers every mode: without it the line the
--- cursor sits on renders its markers again, and the cursor follows the stream
--- — so the newest line would be the one line spelling out its own `**`.
local function tune_scrollback(win)
  vim.wo[win].conceallevel = 2
  vim.wo[win].concealcursor = 'nvic'
end

local function open_windows(self)
  vim.cmd(self.position == 'left' and 'topleft vsplit' or 'botright vsplit')
  self.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.win, self.buf)
  vim.api.nvim_win_set_width(self.win, self.width)
  tune_window(self.win)
  tune_scrollback(self.win)

  if self.prompt_buf == nil then
    return
  end
  vim.cmd('belowright split')
  self.prompt_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.prompt_win, self.prompt_buf)
  vim.api.nvim_win_set_height(self.prompt_win, self.prompt_height)
  tune_window(self.prompt_win)
  vim.wo[self.prompt_win].winbar = '%#NvimeBarDim# ' .. M.escape_winbar(self.prompt_hint) .. ' %=%#NvimeBarDim# '
end

--- Rebuilds the layout when the user closed one split with `:q`. Both windows
--- are redrawn together so the two halves cannot end up in unrelated places.
--- nvim refuses to close a tab's last window, so a lone survivor can still be
--- open after this loop; `stale` tracks it so it can be closed once
--- `open_windows` has given the tab a sibling, instead of being left behind
--- showing the same buffer a second time.
local function ensure_windows(self)
  if win_valid(self.win) and (self.prompt_buf == nil or win_valid(self.prompt_win)) then
    return
  end
  local stale = nil
  for _, win in ipairs(live_wins(self)) do
    if not pcall(vim.api.nvim_win_close, win, true) then
      stale = win
    end
  end
  self.win, self.prompt_win = nil, nil
  open_windows(self)
  if win_valid(stale) then
    pcall(vim.api.nvim_win_close, stale, true)
  end
end

local DEFAULT_PROMPT_HINT = 'prompt · <CR> send (i_<C-s>) · <C-c> stop'

--- Opens the panel named `opts.name`, or focuses it when already open.
--- @param opts table name, width, position, title; prompt_height/prompt_hint/
---   on_submit for a panel with a prompt; keys (mode, lhs, fn, desc, where);
---   on_close, and `prompt = false` for a read-only surface.
--- @return table the panel handle
function M.open(opts)
  assert(type(opts) == 'table', 'panel.open needs an options table')
  assert(type(opts.name) == 'string' and opts.name ~= '', 'panel.open needs a name')
  local wants_prompt = opts.prompt ~= false
  assert(not wants_prompt or type(opts.on_submit) == 'function', 'a prompt panel needs on_submit')

  local live = M.get(opts.name)
  if live ~= nil then
    ensure_windows(live)
    set_winbar(live)
    live:focus()
    return live
  end

  local self = setmetatable({
    name = opts.name,
    title = opts.title or ('nvime ' .. opts.name),
    width = opts.width or 80,
    position = opts.position or 'right',
    prompt_height = opts.prompt_height or 3,
    prompt_hint = opts.prompt_hint or DEFAULT_PROMPT_HINT,
    -- No `scheme://`: this name is what the tabline and the statusline show.
    -- Filetype `nvime` on purpose: nvime classifies every scrollback line
    -- itself, and `markdown` here let vim's own syntax paint on top of it —
    -- a literal strikethrough rule through `~~x~~`, list markers and `---` in
    -- a colour of their own, and a partial line highlighted differently from
    -- the finished one. There is no syntax file for `nvime`, which is the point.
    buf = make_buffer('nvime-' .. opts.name, opts.filetype or 'nvime'),
    prompt_buf = nil,
    status_text = nil,
    status_hint = opts.status_hint,
    written = false,
    --- Whether new output scrolls the scrollback. Cleared when the reader
    --- scrolls up, set again when they come back to the tail.
    pinned = true,
    spinner = nil,
    spinner_frame = 1,
    stream = nil,
    --- Callbacks queued by `after_stream` while a stream is open; run once,
    --- in order, the moment `finish_stream` closes it.
    stream_waiters = nil,
    on_close = opts.on_close,
  }, Panel)
  if wants_prompt then
    self.prompt_buf = make_buffer('nvime-' .. opts.name .. '-prompt', 'markdown')
    -- `@file`/`@dir` completion, scoped to the root THIS panel captured — never
    -- re-derived from the prompt buffer's own (fake) path.
    if type(opts.root) == 'string' then
      vim.b[self.prompt_buf].nvime_root = opts.root
      vim.bo[self.prompt_buf].completefunc = "v:lua.require('nvime.completion').completefunc"
      vim.bo[self.prompt_buf].omnifunc = "v:lua.require('nvime.completion').completefunc"
      -- A completion problem must never stop the panel from opening: the
      -- walk guards itself, but this catches anything that still escapes.
      local ok, err = pcall(completion.refresh, opts.root)
      if not ok then
        vim.notify('nvime: completion unavailable for this panel: ' .. tostring(err), vim.log.levels.WARN)
      end
    end
  end
  vim.bo[self.buf].modifiable = false
  open_windows(self)
  unpin_on_move(self)

  if wants_prompt then
    local function submit()
      local text = take_prompt(self)
      if text ~= '' then
        opts.on_submit(text)
      end
    end
    -- <CR> sends from normal mode only; in insert it still inserts a newline,
    -- so a multi-line prompt stays possible. <C-s> is the insert-mode send.
    bind(self.prompt_buf, 'n', '<CR>', submit, 'nvime: send the prompt')
    bind(self.prompt_buf, 'i', '<C-s>', submit, 'nvime: send the prompt')
  end
  for _, key in ipairs(opts.keys or {}) do
    for _, buf in ipairs(self:_key_buffers(key.where)) do
      local mode = buf == self.prompt_buf and M.prompt_modes(key.lhs) or key.mode
      bind(buf, mode, key.lhs, key.fn, key.desc)
    end
  end
  bind(self.buf, 'n', 'q', function()
    self:close()
  end, 'nvime: close the panel')

  panels[opts.name] = self
  set_winbar(self)
  self:focus()
  return self
end

--- @param where string|nil 'scrollback' (default), 'prompt', or 'both'
function Panel:_key_buffers(where)
  if where == 'prompt' then
    return self.prompt_buf == nil and {} or { self.prompt_buf }
  end
  if where == 'both' and self.prompt_buf ~= nil then
    return { self.buf, self.prompt_buf }
  end
  return { self.buf }
end

--- The live panel named `name`, or nil. A half-wiped panel is dead: its
--- buffers are gone, so it is dropped here rather than handed out broken.
--- @param name string
--- @return table|nil
function M.get(name)
  local self = panels[name]
  if self == nil then
    return nil
  end
  local alive = vim.api.nvim_buf_is_valid(self.buf)
    and (self.prompt_buf == nil or vim.api.nvim_buf_is_valid(self.prompt_buf))
  if alive then
    return self
  end
  -- Dropped without this, its spinner keeps firing every SPINNER_MS for the
  -- rest of the session: `M.close` finds nothing left to stop it through.
  self:stop_activity()
  panels[name] = nil
  return nil
end

--- @param name string
--- @return boolean
function M.is_open(name)
  return M.get(name) ~= nil
end

--- Closes the panel named `name` if it is open. Safe to call repeatedly.
function M.close(name)
  local self = panels[name]
  if self ~= nil then
    self:close()
  end
  panels[name] = nil
end

--- A prompt panel keeps insert mode — that window is for typing. A panel
--- without one is driven by normal-mode keys, so it must not inherit the
--- insert mode of whatever the user was in when it opened.
function Panel:focus()
  local win = win_valid(self.prompt_win) and self.prompt_win or self.win
  if not win_valid(win) then
    return
  end
  vim.api.nvim_set_current_win(win)
  if win ~= self.prompt_win then
    modes.normal()
  end
end

function Panel:close()
  if panels[self.name] ~= self then
    return
  end
  panels[self.name] = nil
  -- The owner may still have a turn running; tell it before the surface goes.
  if self.on_close ~= nil then
    self.on_close()
  end
  self:stop_activity()
  for _, win in ipairs(live_wins(self)) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  for _, buf in ipairs(vim.tbl_filter(buf_valid, { self.buf, self.prompt_buf })) do
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- @param text string
--- @param hl string|nil highlight group for the whole line
function Panel:append(text, hl)
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local spans = hl == nil and {} or { { 0, #line, hl } }
    commit(self, line, { spans = spans })
  end
  follow(self)
end

function Panel:blank()
  self:append('', nil)
end

--- Replaces the whole scrollback. Used by surfaces that re-render a list
--- rather than stream (the changeset view), never mid-stream.
--- @param lines string[]
--- @param marks table[]|nil each { row = 0-based, hl = group } for a whole-line
---   highlight, plus `col`/`end_col` for a span within that row
function Panel:replace(lines, marks)
  assert(self.stream == nil, 'panel:replace cannot run while a stream is open')
  vim.api.nvim_buf_clear_namespace(self.buf, NS, 0, -1)
  write_lines(self.buf, 0, -1, #lines == 0 and { '' } or lines)
  self.written = #lines > 0
  for _, mark in ipairs(marks or {}) do
    if mark.col == nil then
      apply_line_hl(self.buf, mark.row, mark.hl)
    else
      apply_spans(self.buf, mark.row, { { mark.col, mark.end_col, mark.hl } })
    end
  end
end

--- Appends already-laid-out lines together with the spans that colour them —
--- the one primitive for a block a caller composed itself (a spec, a choice),
--- as against `append`, which paints a whole line one colour.
--- @param lines string[]
--- @param marks table[] each { row = 1-based index into `lines`, col, end_col, hl }
--- @return integer the 0-based scrollback row `lines[1]` landed on
function Panel:append_marked(lines, marks)
  assert(self.stream == nil, 'panel:append_marked cannot run while a stream is open')
  assert(#lines > 0, 'panel:append_marked needs at least one line')
  local first = self.written and line_count(self.buf) or 0
  for _, line in ipairs(lines) do
    append_row(self, line)
  end
  for _, mark in ipairs(marks) do
    apply_spans(self.buf, first + mark.row - 1, { { mark.col, mark.end_col, mark.hl } })
  end
  follow(self)
  return first
end

--- Rewrites a run of already-committed rows in place, marks and all. Used by a
--- choice block redrawing itself as the reader toggles a selection; never while
--- a stream is open, which owns the tail row.
--- @param row integer 0-based first row of the run
--- @param lines string[] as many lines as the run holds
--- @param marks table[] each { row = 1-based index into `lines`, col, end_col, hl }
function Panel:rewrite(row, lines, marks)
  assert(self.stream == nil, 'panel:rewrite cannot run while a stream is open')
  assert(type(row) == 'number' and row >= 0, 'panel:rewrite needs a 0-based row')
  local last = row + #lines
  assert(last <= line_count(self.buf), 'panel:rewrite would run past the end of the scrollback')
  vim.api.nvim_buf_clear_namespace(self.buf, NS, row, last)
  write_lines(self.buf, row, last, lines)
  for _, mark in ipairs(marks) do
    apply_spans(self.buf, row + mark.row - 1, { { mark.col, mark.end_col, mark.hl } })
  end
end

--- @param row integer 0-based scrollback row
--- @param hl string highlight group applied to the whole row
function Panel:highlight_row(row, hl)
  apply_spans(self.buf, row, { { 0, #(vim.api.nvim_buf_get_lines(self.buf, row, row + 1, false)[1] or ''), hl } })
end

--- @return table markdown render context: the carried fence state, plus
---   whether the fence currently open is an options block being swallowed
local function new_ctx(line_hl)
  return { md = markdown.new_state(), swallow = false, line_hl = line_hl }
end

--- Commits one finished markdown line into the scrollback, or swallows it when
--- it belongs to an options block: that block's JSON is a payload for the
--- reader's choice widget, never something to read.
local function commit_md(self, ctx, text)
  local info = markdown.scan(text, ctx.md)
  if info.kind == 'fence_open' and info.lang == markdown.OPTIONS_LANG then
    ctx.swallow = true
    return
  end
  if ctx.swallow then
    ctx.swallow = info.kind ~= 'fence_close'
    return
  end
  if info.line_hl == nil then
    info.line_hl = ctx.line_hl
  end
  commit(self, text, info)
end

--- Renders a complete markdown message (a resumed turn, or a one-shot reply).
function Panel:append_markdown(text, line_hl)
  assert(type(text) == 'string', 'panel:append_markdown needs text')
  assert(line_hl == nil or type(line_hl) == 'string', 'panel:append_markdown highlight must be a string')
  local ctx = new_ctx(line_hl)
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    commit_md(self, ctx, line)
  end
  follow(self)
end

--- Opens a streaming assistant message. Deltas append to it until `finish_stream`.
--- @param speaker string|nil header line; nil for a stream with no header
function Panel:begin_stream(speaker, line_hl)
  assert(speaker == nil or type(speaker) == 'string', 'panel:begin_stream speaker must be a string')
  assert(line_hl == nil or type(line_hl) == 'string', 'panel:begin_stream highlight must be a string')
  if speaker ~= nil then
    self:append(speaker, 'NvimeAgent')
  end
  self.stream = { pending = '', ctx = new_ctx(line_hl), tail_row = nil, swallow_newline = false }
end

--- @return boolean whether a stream currently owns the tail row
function Panel:is_streaming()
  return self.stream ~= nil
end

--- Runs `fn` now if nothing is streaming, otherwise queues it to run once the
--- open stream closes. Lets a caller that must write a whole block at once —
--- `append_marked`/`rewrite` never run mid-stream — wait for the tail row
--- rather than raising or corrupting it.
--- @param fn fun()
function Panel:after_stream(fn)
  if self.stream == nil then
    fn()
    return
  end
  self.stream_waiters = self.stream_waiters or {}
  self.stream_waiters[#self.stream_waiters + 1] = fn
end

--- Rewrites the volatile tail line; completed lines above it are never touched.
--- The tail is classified by exactly the call that will classify it again when
--- it commits, against a COPY of the fence state — so the groups a line is
--- painted with never change as it goes from volatile to final.
local function draw_tail(self, text)
  if self.stream.ctx.swallow then
    return
  end
  local probe = vim.deepcopy(self.stream.ctx.md)
  local info = markdown.scan(text, probe)
  local rendered_text = rendered(info, text)
  local row = self.stream.tail_row
  if row == nil then
    row = append_row(self, rendered_text)
    self.stream.tail_row = row
  else
    write_lines(self.buf, row, row + 1, { rendered_text })
  end
  vim.api.nvim_buf_clear_namespace(self.buf, NS, row, row + 1)
  apply_line_hl(self.buf, row, info.line_hl)
  apply_body_hl(self.buf, row, info.body_hl, rendered_text)
  apply_spans(self.buf, row, info.spans)
  apply_conceal(self.buf, row, info.conceal)
end

--- Drops the volatile tail line so the next write commits a final one.
local function clear_tail(self)
  if self.stream.tail_row == nil then
    return
  end
  write_lines(self.buf, self.stream.tail_row, self.stream.tail_row + 1, {})
  self.stream.tail_row = nil
end

--- @param text string one streamed delta, which may span line boundaries
function Panel:push_delta(text)
  if self.stream == nil then
    return
  end
  self.stream.pending = self.stream.pending .. text
  if self.stream.swallow_newline and vim.startswith(self.stream.pending, '\n') then
    -- An interjection already ended that line; do not emit a blank one for it.
    self.stream.pending = self.stream.pending:sub(2)
    self.stream.swallow_newline = false
  end
  local newline = self.stream.pending:find('\n', 1, true)
  while newline ~= nil do
    local line = self.stream.pending:sub(1, newline - 1)
    self.stream.pending = self.stream.pending:sub(newline + 1)
    clear_tail(self)
    commit_md(self, self.stream.ctx, line)
    newline = self.stream.pending:find('\n', 1, true)
  end
  if self.stream.pending ~= '' then
    draw_tail(self, self.stream.pending)
  end
  follow(self)
end

--- Flushes any partial line and closes the streaming message.
function Panel:finish_stream()
  if self.stream == nil then
    return
  end
  clear_tail(self)
  if self.stream.pending ~= '' then
    commit_md(self, self.stream.ctx, self.stream.pending)
  end
  self.stream = nil
  self:blank()
  local waiters = self.stream_waiters
  self.stream_waiters = nil
  for _, fn in ipairs(waiters or {}) do
    fn()
  end
end

--- Inserts a line into a message that is still streaming (a tool one-liner).
--- The partial tail is committed first so ordering stays truthful.
function Panel:interject(text, hl)
  local stream = self.stream
  if stream ~= nil then
    clear_tail(self)
    if stream.pending ~= '' then
      commit_md(self, stream.ctx, stream.pending)
      stream.pending = ''
      stream.swallow_newline = true
    end
  end
  self:append(text, hl)
end

--- @param text string where this surface is
--- @param hint string|nil the keys, right-aligned on the same bar
function Panel:status(text, hint)
  self.status_text = text
  if hint ~= nil then
    self.status_hint = hint
  end
  set_winbar(self)
end

function Panel:start_activity()
  if self.spinner ~= nil then
    return
  end
  self.spinner = vim.uv.new_timer()
  self.spinner:start(0, SPINNER_MS, function()
    vim.schedule(function()
      if panels[self.name] ~= self or self.spinner == nil then
        return
      end
      self.spinner_frame = self.spinner_frame % #require('nvime.icons').get().spinner + 1
      set_winbar(self)
    end)
  end)
end

function Panel:stop_activity()
  if self.spinner == nil then
    return
  end
  self.spinner:stop()
  self.spinner:close()
  self.spinner = nil
  set_winbar(self)
end

M.NS = NS
M.Panel = Panel

return M
