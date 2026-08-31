--- The chat surface: a scrollback buffer plus a separate prompt buffer in a
--- vertical split. Streaming text lands line by line — completed lines are
--- committed once and never rewritten, only the volatile tail line is redrawn
--- as deltas arrive, so a long reply stays O(total) rather than O(lines^2).
local markdown = require('nvime.markdown')

local M = {}

local NS = vim.api.nvim_create_namespace('nvime.panel')
local SPINNER = { '·', '‥', '…', '‥' }
local SPINNER_MS = 140

local panel = nil

local function write_lines(buf, first, last, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, first, last, false, lines)
  vim.bo[buf].modifiable = false
end

local function apply_spans(buf, row, spans)
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, NS, row, span[1], {
      end_col = span[2],
      hl_group = span[3],
      strict = false,
    })
  end
end

local function line_count(buf)
  return vim.api.nvim_buf_line_count(buf)
end

--- Follows the tail unless the reader has scrolled up to look at something.
local function follow(self)
  if self.win == nil or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local last = line_count(self.buf)
  local cursor = vim.api.nvim_win_get_cursor(self.win)[1]
  if cursor >= last - 2 then
    vim.api.nvim_win_set_cursor(self.win, { last, 0 })
  end
end

--- Highlights a completed fenced block with the real grammar for its language.
--- Best-effort: an unknown or unavailable parser leaves the plain code colour.
--- `rows[n]` is the buffer row holding `lines[n]`; a tool line interjected mid
--- fence makes those non-contiguous, so parsed rows are never added to a base.
local function highlight_fence(buf, rows, lines, lang)
  if lang == nil or #lines == 0 then
    return
  end
  local source = table.concat(lines, '\n')
  local ok, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok or parser == nil then
    return
  end
  local query = vim.treesitter.query.get(lang, 'highlights')
  if query == nil then
    return
  end
  local trees = parser:parse()
  if trees == nil or trees[1] == nil then
    return
  end
  for id, node in query:iter_captures(trees[1]:root(), source, 0, -1) do
    local srow, scol, erow, ecol = node:range()
    local start_row, end_row = rows[srow + 1], rows[erow + 1]
    if start_row ~= nil and end_row ~= nil then
      pcall(vim.api.nvim_buf_set_extmark, buf, NS, start_row, scol, {
        end_row = end_row,
        end_col = ecol,
        hl_group = '@' .. query.captures[id],
        priority = 120,
        strict = false,
      })
    end
  end
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

--- Appends one already-classified line and returns the row it landed on.
local function commit(self, text, info)
  local row = append_row(self, text)
  apply_spans(self.buf, row, info.spans)
  return row
end

local function set_winbar(self)
  if self.win == nil or not vim.api.nvim_win_is_valid(self.win) then
    return
  end
  local left = self.spinner == nil and '' or (SPINNER[self.spinner_frame] .. ' ')
  vim.wo[self.win].winbar = '%#NvimeSession#' .. left .. (self.status or 'nvime chat')
end

--- Reclaims a leftover buffer of the same name (the user wiped half a panel);
--- `nvim_buf_set_name` refuses a duplicate, which would brick every reopen.
local function drop_stale(name)
  local existing = vim.fn.bufnr('^' .. name .. '$')
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end
end

local function make_buffer(name, filetype)
  drop_stale(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  return buf
end

local function bind(buf, mode, lhs, fn, desc)
  vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
end

--- Prompt text, then clear it ready for the next message.
local function take_prompt(self)
  local lines = vim.api.nvim_buf_get_lines(self.prompt_buf, 0, -1, false)
  local text = vim.trim(table.concat(lines, '\n'))
  write_lines(self.prompt_buf, 0, -1, { '' })
  vim.bo[self.prompt_buf].modifiable = true
  return text
end

local function open_windows(self, opts)
  vim.cmd(opts.position == 'left' and 'topleft vsplit' or 'botright vsplit')
  self.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.win, self.buf)
  vim.api.nvim_win_set_width(self.win, opts.width)
  vim.wo[self.win].number = false
  vim.wo[self.win].relativenumber = false
  vim.wo[self.win].signcolumn = 'no'
  vim.wo[self.win].wrap = true
  vim.wo[self.win].linebreak = true

  vim.cmd('belowright split')
  self.prompt_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.prompt_win, self.prompt_buf)
  vim.api.nvim_win_set_height(self.prompt_win, opts.prompt_height)
  vim.wo[self.prompt_win].number = false
  vim.wo[self.prompt_win].relativenumber = false
  vim.wo[self.prompt_win].winbar = '%#NvimeDim#prompt · <CR> send (i_<C-s>) · <C-r> sessions · <C-c> stop'
end

local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Rebuilds the layout when the user closed one split with `:q`. Both windows
--- are redrawn together so the two halves cannot end up in unrelated places.
--- nvim refuses to close a tab's last window, so a lone survivor can still be
--- open after this loop; `stale` tracks it so it can be closed once
--- `open_windows` has given the tab a sibling, instead of being left behind
--- showing the same buffer a second time.
local function ensure_windows(self, opts)
  if win_valid(self.win) and win_valid(self.prompt_win) then
    return
  end
  local stale = nil
  for _, win in ipairs({ self.prompt_win, self.win }) do
    if win_valid(win) and not pcall(vim.api.nvim_win_close, win, true) then
      stale = win
    end
  end
  self.win, self.prompt_win = nil, nil
  open_windows(self, opts)
  if win_valid(stale) then
    pcall(vim.api.nvim_win_close, stale, true)
  end
end

--- Opens the panel (or focuses it when already open).
--- @param opts table width, prompt_height, position, on_submit, on_cancel, on_history, on_close
function M.open(opts)
  assert(type(opts) == 'table', 'panel.open needs an options table')
  assert(type(opts.on_submit) == 'function', 'panel.open needs an on_submit callback')
  if M.is_open() then
    ensure_windows(panel, opts)
    set_winbar(panel)
    vim.api.nvim_set_current_win(panel.prompt_win)
    return panel
  end

  local self = {
    buf = make_buffer('nvime://chat', 'markdown'),
    prompt_buf = make_buffer('nvime://prompt', 'markdown'),
    status = nil,
    written = false,
    spinner = nil,
    spinner_frame = 1,
    stream = nil,
    on_close = opts.on_close,
  }
  vim.bo[self.buf].modifiable = false
  open_windows(self, opts)

  local function submit()
    local text = take_prompt(self)
    if text ~= '' then
      opts.on_submit(text)
    end
  end
  -- <CR> sends from normal mode only; in insert it still inserts a newline, so
  -- a multi-line prompt stays possible. <C-s> is the insert-mode send.
  bind(self.prompt_buf, 'n', '<CR>', submit, 'nvime: send the prompt')
  bind(self.prompt_buf, 'i', '<C-s>', submit, 'nvime: send the prompt')
  for _, buf in ipairs({ self.buf, self.prompt_buf }) do
    bind(buf, 'n', '<C-r>', opts.on_history, 'nvime: pick a session')
    bind(buf, 'n', '<C-c>', opts.on_cancel, 'nvime: stop the running turn')
  end
  bind(self.buf, 'n', 'q', M.close, 'nvime: close the chat panel')

  panel = self
  set_winbar(self)
  vim.api.nvim_set_current_win(self.prompt_win)
  return self
end

--- True while the panel's buffers live. Windows may be missing — `M.open`
--- redraws them — but a half-wiped panel is dead and must be rebuilt.
function M.is_open()
  return panel ~= nil and vim.api.nvim_buf_is_valid(panel.buf) and vim.api.nvim_buf_is_valid(panel.prompt_buf)
end

function M.close()
  if panel == nil then
    return
  end
  -- The owner may still have a turn running; tell it before the surface goes.
  if panel.on_close ~= nil then
    panel.on_close()
  end
  M.stop_activity()
  for _, win in ipairs({ panel.prompt_win, panel.win }) do
    if win ~= nil and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ panel.prompt_buf, panel.buf }) do
    if vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  panel = nil
end

--- @param text string
--- @param hl string|nil highlight group for the whole line
function M.append(text, hl)
  if not M.is_open() then
    return
  end
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local spans = hl == nil and {} or { { 0, #line, hl } }
    commit(panel, line, { spans = spans })
  end
  follow(panel)
end

function M.blank()
  M.append('', nil)
end

--- @return table markdown render context: carried fence state + open fence rows
local function new_ctx()
  return { md = markdown.new_state(), fence = nil }
end

local function close_fence(self, ctx)
  local fence = ctx.fence
  if fence == nil then
    return
  end
  highlight_fence(self.buf, fence.rows, fence.lines, fence.lang)
  ctx.fence = nil
end

--- Commits one finished markdown line into the scrollback.
local function commit_md(self, ctx, text)
  local info = markdown.scan(text, ctx.md)
  local row = commit(self, text, info)
  if info.kind == 'fence_open' then
    ctx.fence = { lang = info.lang, lines = {}, rows = {} }
  elseif info.kind == 'code' and ctx.fence ~= nil then
    table.insert(ctx.fence.lines, text)
    table.insert(ctx.fence.rows, row)
  elseif info.kind == 'fence_close' then
    close_fence(self, ctx)
  end
end

--- Renders a complete markdown message (a resumed turn, or a one-shot reply).
function M.append_markdown(text)
  if not M.is_open() then
    return
  end
  local ctx = new_ctx()
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    commit_md(panel, ctx, line)
  end
  close_fence(panel, ctx)
  follow(panel)
end

--- Opens a streaming assistant message. Deltas append to it until `finish_stream`.
function M.begin_stream()
  if not M.is_open() then
    return
  end
  M.append('claude', 'NvimeAgent')
  panel.stream = { pending = '', ctx = new_ctx(), tail_row = nil, swallow_newline = false }
end

--- Rewrites the volatile tail line; completed lines above it are never touched.
local function draw_tail(self, text)
  local row = self.stream.tail_row
  if row == nil then
    row = append_row(self, text)
    self.stream.tail_row = row
  else
    write_lines(self.buf, row, row + 1, { text })
  end
  vim.api.nvim_buf_clear_namespace(self.buf, NS, row, row + 1)
  -- The tail is not final, so classify it against a copy of the fence state.
  local probe = vim.deepcopy(self.stream.ctx.md)
  apply_spans(self.buf, row, markdown.scan(text, probe).spans)
end

--- @param text string one streamed delta, which may span line boundaries
function M.push_delta(text)
  if not M.is_open() or panel.stream == nil then
    return
  end
  local self = panel
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
    if self.stream.tail_row ~= nil then
      -- The tail line is now final: rewrite it in place and commit it.
      write_lines(self.buf, self.stream.tail_row, self.stream.tail_row + 1, {})
      self.stream.tail_row = nil
    end
    commit_md(self, self.stream.ctx, line)
    newline = self.stream.pending:find('\n', 1, true)
  end
  if self.stream.pending ~= '' then
    draw_tail(self, self.stream.pending)
  end
  follow(self)
end

--- Flushes any partial line and closes the streaming message.
function M.finish_stream()
  if not M.is_open() or panel.stream == nil then
    return
  end
  local self = panel
  if self.stream.tail_row ~= nil then
    write_lines(self.buf, self.stream.tail_row, self.stream.tail_row + 1, {})
    self.stream.tail_row = nil
  end
  if self.stream.pending ~= '' then
    commit_md(self, self.stream.ctx, self.stream.pending)
  end
  close_fence(self, self.stream.ctx)
  self.stream = nil
  M.blank()
end

--- Inserts a line into a message that is still streaming (a tool one-liner).
--- The partial tail is committed first so ordering stays truthful.
function M.interject(text, hl)
  if not M.is_open() then
    return
  end
  local stream = panel.stream
  if stream ~= nil then
    if stream.tail_row ~= nil then
      write_lines(panel.buf, stream.tail_row, stream.tail_row + 1, {})
      stream.tail_row = nil
    end
    if stream.pending ~= '' then
      commit_md(panel, stream.ctx, stream.pending)
      stream.pending = ''
      stream.swallow_newline = true
    end
  end
  M.append(text, hl)
end

function M.status(text)
  if not M.is_open() then
    return
  end
  panel.status = text
  set_winbar(panel)
end

function M.start_activity()
  if not M.is_open() or panel.spinner ~= nil then
    return
  end
  local self = panel
  self.spinner = vim.uv.new_timer()
  self.spinner:start(0, SPINNER_MS, function()
    vim.schedule(function()
      if panel ~= self or self.spinner == nil then
        return
      end
      self.spinner_frame = self.spinner_frame % #SPINNER + 1
      set_winbar(self)
    end)
  end)
end

function M.stop_activity()
  if panel == nil or panel.spinner == nil then
    return
  end
  panel.spinner:stop()
  panel.spinner:close()
  panel.spinner = nil
  set_winbar(panel)
end

--- Test and health hook: the live panel handle, or nil.
function M.current()
  return panel
end

M.NS = NS

return M
