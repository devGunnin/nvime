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

local M = {}

local NS = vim.api.nvim_create_namespace('nvime.panel')
local SPINNER = { '·', '‥', '…', '‥' }
local SPINNER_MS = 140

local Panel = {}
Panel.__index = Panel

--- Live panels by name. A closed panel is removed, never left as a husk.
local panels = {}

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

local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

--- Follows the tail unless the reader has scrolled up to look at something.
local function follow(self)
  if not win_valid(self.win) then
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
  if not win_valid(self.win) then
    return
  end
  local left = self.spinner == nil and '' or (SPINNER[self.spinner_frame] .. ' ')
  -- Escaped: a winbar evaluates `%{expr}` as vimscript every redraw, and the
  -- status text carries a session title the user typed or pasted.
  local text = tostring(self.status_text or self.title):gsub('%%', '%%%%')
  vim.wo[self.win].winbar = '%#NvimeSession#' .. left .. text
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

local function tune_window(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
end

local function open_windows(self)
  vim.cmd(self.position == 'left' and 'topleft vsplit' or 'botright vsplit')
  self.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.win, self.buf)
  vim.api.nvim_win_set_width(self.win, self.width)
  tune_window(self.win)

  if self.prompt_buf == nil then
    return
  end
  vim.cmd('belowright split')
  self.prompt_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(self.prompt_win, self.prompt_buf)
  vim.api.nvim_win_set_height(self.prompt_win, self.prompt_height)
  tune_window(self.prompt_win)
  vim.wo[self.prompt_win].winbar = '%#NvimeDim#' .. self.prompt_hint
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
  for _, win in ipairs({ self.prompt_win, self.win }) do
    if win_valid(win) and not pcall(vim.api.nvim_win_close, win, true) then
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
    buf = make_buffer('nvime://' .. opts.name, opts.filetype or 'markdown'),
    prompt_buf = nil,
    status_text = nil,
    written = false,
    spinner = nil,
    spinner_frame = 1,
    stream = nil,
    on_close = opts.on_close,
  }, Panel)
  if wants_prompt then
    self.prompt_buf = make_buffer('nvime://' .. opts.name .. '-prompt', 'markdown')
    -- `@file`/`@dir` completion, scoped to the root THIS panel captured — never
    -- re-derived from the prompt buffer's own (fake) path.
    if type(opts.root) == 'string' then
      vim.b[self.prompt_buf].nvime_root = opts.root
      vim.bo[self.prompt_buf].completefunc = "v:lua.require('nvime.completion').completefunc"
      vim.bo[self.prompt_buf].omnifunc = "v:lua.require('nvime.completion').completefunc"
      completion.refresh(opts.root)
    end
  end
  vim.bo[self.buf].modifiable = false
  open_windows(self)

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
      bind(buf, key.mode, key.lhs, key.fn, key.desc)
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

function Panel:focus()
  local win = win_valid(self.prompt_win) and self.prompt_win or self.win
  if win_valid(win) then
    vim.api.nvim_set_current_win(win)
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
  for _, win in ipairs({ self.prompt_win, self.win }) do
    if win_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  for _, buf in ipairs({ self.prompt_buf, self.buf }) do
    if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
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
function Panel:replace(lines)
  assert(self.stream == nil, 'panel:replace cannot run while a stream is open')
  vim.api.nvim_buf_clear_namespace(self.buf, NS, 0, -1)
  write_lines(self.buf, 0, -1, #lines == 0 and { '' } or lines)
  self.written = #lines > 0
end

--- @param row integer 0-based scrollback row
--- @param hl string highlight group applied to the whole row
function Panel:highlight_row(row, hl)
  apply_spans(self.buf, row, { { 0, #(vim.api.nvim_buf_get_lines(self.buf, row, row + 1, false)[1] or ''), hl } })
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
function Panel:append_markdown(text)
  local ctx = new_ctx()
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    commit_md(self, ctx, line)
  end
  close_fence(self, ctx)
  follow(self)
end

--- Opens a streaming assistant message. Deltas append to it until `finish_stream`.
--- @param speaker string|nil header line; nil for a stream with no header
function Panel:begin_stream(speaker)
  if speaker ~= nil then
    self:append(speaker, 'NvimeAgent')
  end
  self.stream = { pending = '', ctx = new_ctx(), tail_row = nil, swallow_newline = false }
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
  close_fence(self, self.stream.ctx)
  self.stream = nil
  self:blank()
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

function Panel:status(text)
  self.status_text = text
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
      self.spinner_frame = self.spinner_frame % #SPINNER + 1
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
