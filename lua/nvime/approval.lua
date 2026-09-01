--- The permission prompt for a tool nvime will not auto-allow: a small float
--- with `y`/`n`, never `vim.fn.confirm`. Nothing blocks — the editor stays
--- usable while the sidecar holds the tool call, and the answer travels back
--- through the same RPC as everything else.
---
--- Asks queue: one float at a time, in arrival order, so a run that trips two
--- rules does not stack windows on top of each other.
---
--- The float shows the payload — the whole command, the whole path — verbatim,
--- wrapped over as many lines as it takes and scrolled if it does not fit. The
--- panel's one-line summary is clipped, and nobody can consent to a command
--- they were shown three quarters of.
local keymaps = require('nvime.keymaps')
local text = require('nvime.text')

local M = {}

local WIDTH = 88
local NS = vim.api.nvim_create_namespace('nvime.approval')

--- Room for the two-space indent the payload is rendered with.
local INDENT = '  '

local queue = {}
local active = nil

local function close_window()
  if active == nil then
    return
  end
  local win, buf = active.win, active.buf
  active = nil
  if win ~= nil and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- The float's page under construction: its lines, the marks that colour them,
--- and the rows to paint as alerts.
---
--- Every append wraps to the border, which is what lets the finished line
--- count be the float's height on screen. Without that a two-line summary
--- silently pushes the payload — the thing being consented to — off the bottom
--- of a float sized for one.
local Sheet = {}
Sheet.__index = Sheet

--- @param width integer columns available inside the border
--- @return table
local function sheet(width)
  return setmetatable({
    lines = {},
    marks = {},
    alerts = {},
    width = width,
    -- One column of slack past the indent: a line that ends exactly on the
    -- border can measure as needing a second row, and the float then opens
    -- with an empty band under its content.
    body_width = math.max(width - #INDENT - 1, 8),
  }, Sheet)
end

--- One label, wrapped and kept a column in. `text.wrap` collapses runs of
--- whitespace, so that column is re-applied rather than passed through it.
--- @return integer the 0-based row it started on
function Sheet:label(caption, hl)
  local wrapped = text.wrap(caption:gsub('^ ', ''), self.width - 2)
  for _, line in ipairs(wrapped) do
    self.lines[#self.lines + 1] = ' ' .. line
  end
  local row = #self.lines - #wrapped
  self.marks[#self.marks + 1] = { row = row, col = 0, end_col = 1 + #wrapped[1], hl = hl or 'NvimeLabel' }
  return row
end

--- A label the reader must not miss, and the row it will be painted on.
function Sheet:alert(caption)
  self.alerts[#self.alerts + 1] = self:label(caption, 'NvimeError') + 1
end

--- A label, its prose wrapped under it, then a blank line.
function Sheet:section(caption, body)
  self:label(caption)
  for _, line in ipairs(text.wrap(body, self.body_width)) do
    self.lines[#self.lines + 1] = INDENT .. line
  end
  self.lines[#self.lines + 1] = ''
end

--- Indented lines, verbatim. `band` gives them a whole-line highlight so they
--- read as one block to the border rather than as a ragged column.
function Sheet:indented(body, band)
  local first = #self.lines
  for _, line in ipairs(body) do
    self.lines[#self.lines + 1] = INDENT .. line
  end
  if band == nil then
    return
  end
  for row = first, #self.lines - 1 do
    self.marks[#self.marks + 1] = { row = row, hl = band }
  end
end

--- The block the user is actually consenting to: what it is, how much of it
--- there is, and every byte of it.
---
--- Wrapped by CHARACTERS, not words: a word wrap drops the space it broke at,
--- and a command is not something to show approximately.
--- @param page table
--- @param detail table kind, text, bytes, truncated
--- @param shown string the payload as far as the sidecar could send it
local function append_payload(page, detail, shown)
  local body = text.wrap_exact(shown, page.body_width)
  page:label(
    string.format(
      ' the exact %s — %d line%s, %d byte%s:',
      detail.kind or 'value',
      #body,
      #body == 1 and '' or 's',
      detail.bytes or #shown,
      (detail.bytes or #shown) == 1 and '' or 's'
    )
  )
  if detail.truncated then
    page:alert(string.format(' !! TRUNCATED — nvime can only show you %d of %d bytes', #shown, detail.bytes))
  end
  page:indented(body, 'NvimeCode')
end

--- The y/n decision row. Wrapped like everything else `render` builds, rather
--- than appended as a raw literal — a raw line is what let this row need a
--- second screen row on a narrow float while `#lines` still counted it as
--- one, hiding the payload below it with no visual cue anything was cut.
--- @param page table
local function append_keys(page)
  local first = #page.lines
  for _, line in ipairs(text.wrap('y allow once n deny', page.width - 2)) do
    page.lines[#page.lines + 1] = ' ' .. line
  end
  -- `text.wrap` collapses whitespace runs to one space, so the keys are
  -- found by a whole-word match rather than by a fixed column: either key
  -- can land as the last word on its wrapped line, with nothing after it.
  for row = first, #page.lines - 1 do
    local line = page.lines[row + 1]
    for _, key in ipairs({ 'y', 'n' }) do
      local col = line:find('%f[%a]' .. key .. '%f[%A]')
      if col ~= nil then
        page.marks[#page.marks + 1] = { row = row, col = col - 1, end_col = col, hl = 'NvimeKey' }
      end
    end
  end
end

--- The float's contents.
---
--- The decision and its keys sit at the top, where they stay visible however
--- long the payload below them is; the payload itself follows in full.
--- @param request table approvalId, tool, summary, reason, detail, path
--- @param width integer columns available inside the border
--- @return string[] lines
--- @return integer[] alerts 1-based rows to paint as errors
--- @return table[] marks each { row = 0-based, col, end_col, hl }
function M.render(request, width)
  assert(type(request) == 'table', 'approval.render needs a request')
  assert(type(width) == 'number' and width > 0, 'approval.render needs a positive width')
  local page = sheet(width)
  page:section(' claude wants to:', request.summary or request.tool or 'run a tool')
  page:section(' nvime will not allow that on its own:', request.reason or 'outside the agreed scope')

  local detail = request.detail
  local shown = type(detail) == 'table' and type(detail.text) == 'string' and detail.text or nil

  -- The sidecar already resolved where the write really lands. Without this
  -- the user authorizes a path they would have to walk a symlink to decode.
  if type(request.path) == 'string' and request.path ~= '' and request.path ~= shown then
    page:alert(' !! it really lands on:')
    page:indented(text.wrap_exact(request.path, page.body_width))
    page.lines[#page.lines + 1] = ''
  end

  append_keys(page)

  if shown ~= nil and shown ~= '' then
    append_payload(page, detail, shown)
  end
  return page.lines, page.alerts, page.marks
end

--- Opens the float for `ask` and wires the approval keys to `answer`.
local function show(ask, answer)
  local width = math.min(WIDTH, math.max(vim.o.columns - 4, 20))
  local lines, alerts, marks = M.render(ask.request, width)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, NS, mark.row, mark.col or 0, {
      end_col = mark.col ~= nil and mark.end_col or nil,
      hl_group = mark.col ~= nil and mark.hl or nil,
      line_hl_group = mark.col == nil and mark.hl or nil,
      strict = false,
    })
  end
  for _, row in ipairs(alerts) do
    vim.api.nvim_buf_set_extmark(buf, NS, row - 1, 0, { line_hl_group = 'NvimeError' })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  -- One row per line: every line `render` builds — including the y/n row
  -- now — is wrapped to the border on the way in, so the buffer's height is
  -- the height on screen.
  local height = #lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    -- Clamped, never the content: a payload taller than the screen scrolls.
    height = math.max(math.min(height, vim.o.lines - 2), 1),
    row = math.max(math.floor((vim.o.lines - height) / 2), 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = 'rounded',
    title = ' nvime · approve? ',
    title_pos = 'center',
  })
  -- Everything is pre-wrapped to the border, so these two are only a backstop
  -- — and `linebreak` keeps that backstop off the middle of a word.
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  active = { win = win, buf = buf, request = ask.request, on_answer = ask.on_answer }

  for _, key in ipairs(keymaps.APPROVAL) do
    vim.keymap.set('n', key.lhs, function()
      answer(key.allow)
    end, { buffer = buf, nowait = true, silent = true, desc = key.desc })
  end
end

local function pump()
  if active ~= nil or #queue == 0 then
    return
  end
  local ask = table.remove(queue, 1)
  show(ask, function(allow)
    close_window()
    ask.on_answer(allow)
    pump()
  end)
end

--- Queues an approval. `on_answer(allow)` runs exactly once — from the user's
--- key, from `M.dismiss_all`, or never if `M.settle` withdrew the ask because
--- the sidecar had already stopped waiting for it.
--- @param request table approvalId, tool, summary, reason
--- @param on_answer fun(allow: boolean)
function M.ask(request, on_answer)
  assert(type(request) == 'table' and type(request.approvalId) == 'string', 'approval.ask needs a request')
  assert(type(on_answer) == 'function', 'approval.ask needs an answer callback')
  queue[#queue + 1] = { request = request, on_answer = on_answer }
  pump()
end

--- Withdraws an ask the sidecar already settled (a timeout, a cancelled run).
--- The float goes away without pretending the user answered.
--- @param approval_id string
--- @return boolean whether anything was withdrawn
function M.settle(approval_id)
  assert(type(approval_id) == 'string', 'approval.settle needs an id')
  if active ~= nil and active.request.approvalId == approval_id then
    close_window()
    pump()
    return true
  end
  for i, ask in ipairs(queue) do
    if ask.request.approvalId == approval_id then
      table.remove(queue, i)
      return true
    end
  end
  return false
end

--- Denies everything outstanding — the panel closed, or the run ended.
function M.dismiss_all()
  local waiting = queue
  queue = {}
  -- Not `cond and x or nil`: in Lua that always yields the fallback.
  local on_screen = nil
  if active ~= nil then
    on_screen = active.on_answer
  end
  close_window()
  if on_screen ~= nil then
    on_screen(false)
  end
  for _, ask in ipairs(waiting) do
    ask.on_answer(false)
  end
end

--- Test hook: the ask on screen, or nil.
function M.current()
  return active
end

--- Test hook: how many asks are waiting behind the one on screen.
function M.queued()
  return #queue
end

return M
