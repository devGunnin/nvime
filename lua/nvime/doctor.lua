--- `:Nvime doctor` — the "why doesn't it work" front door: the same checks
--- `:checkhealth nvime` runs (`diagnostics.lua`), rendered as one glanceable
--- pass/warn/fail list with the fix named right under each failure, instead
--- of the generic health buffer.
local diagnostics = require('nvime.diagnostics')
local icons = require('nvime.icons')
local text = require('nvime.text')
local modes = require('nvime.modes')

local M = {}

local WIDTH = 92
local NS = vim.api.nvim_create_namespace('nvime.doctor')

--- The gutter every message and every fix line is indented past.
local GUTTER = '    '

local LEVEL_HL = { ok = 'NvimeOk', warn = 'NvimeWarn', error = 'NvimeError', info = 'NvimeDim' }

local view = { win = nil, buf = nil }

--- One entry: its symbol and message, with the fix on the lines under it.
--- Long messages wrap under the gutter rather than running past the border.
--- @param entry table { level, message, advice }
--- @param width integer|nil columns available inside the border
--- @return string[] lines
--- @return string highlight group for the symbol
function M.render_entry(entry, width)
  assert(type(entry) == 'table', 'doctor.render_entry needs an entry')
  local body = math.max((width or WIDTH) - #GUTTER - 2, 20)
  local symbol = icons.level(entry.level)
  local wrapped = text.wrap(text.tilde(entry.message or ''), body)
  local lines = { string.format(' %s  %s', symbol, wrapped[1] or '') }
  for index = 2, #wrapped do
    lines[#lines + 1] = GUTTER .. wrapped[index]
  end
  if entry.advice ~= nil and entry.advice ~= '' then
    for index, line in ipairs(text.wrap(text.tilde(entry.advice), body - 5)) do
      lines[#lines + 1] = GUTTER .. (index == 1 and 'fix: ' or '     ') .. line
    end
  end
  return lines, LEVEL_HL[entry.level] or 'NvimeDim'
end

--- @param entries table[]
--- @param level string
--- @return integer
local function count(entries, level)
  local n = 0
  for _, entry in ipairs(entries) do
    if entry.level == level then
      n = n + 1
    end
  end
  return n
end

--- @param entries table[]
--- @return string summary
--- @return string highlight group
local function summarise(entries)
  local failing, warning = count(entries, 'error'), count(entries, 'warn')
  if failing > 0 then
    return string.format(' %d failing, %d warning — fix the failures above first', failing, warning), 'NvimeError'
  end
  if warning > 0 then
    return string.format(' all clear except %d warning', warning), 'NvimeWarn'
  end
  return ' all clear', 'NvimeOk'
end

--- The whole page. Pure, so the layout is testable without a window.
--- @param entries table[]
--- @param width integer|nil
--- @return string[] lines
--- @return table[] marks each { row = 0-based, col, end_col, hl }
function M.render(entries, width)
  assert(type(entries) == 'table', 'doctor.render needs a list of diagnostic entries')
  -- A blank line at each end, so the list breathes inside its border.
  local lines, marks = { '' }, {}
  for _, entry in ipairs(entries) do
    local rendered, hl = M.render_entry(entry, width)
    marks[#marks + 1] = { row = #lines, col = 1, end_col = 1 + #icons.level(entry.level), hl = hl }
    for index, line in ipairs(rendered) do
      lines[#lines + 1] = line
      if index > 1 then
        marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #line, hl = 'NvimeDim' }
      end
    end
  end
  local summary, summary_hl = summarise(entries)
  lines[#lines + 1] = ''
  lines[#lines + 1] = summary
  -- end_col is the line's own byte length: a whole-line mark never needs
  -- end_row, and nvim 0.11 errors on end_row given without an end_col.
  marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #summary, hl = summary_hl }
  lines[#lines + 1] = ''
  return lines, marks
end

local function close()
  if view.win ~= nil and vim.api.nvim_win_is_valid(view.win) then
    pcall(vim.api.nvim_win_close, view.win, true)
  end
  if view.buf ~= nil and vim.api.nvim_buf_is_valid(view.buf) then
    pcall(vim.api.nvim_buf_delete, view.buf, { force = true })
  end
  view.win, view.buf = nil, nil
end

--- Runs every check and shows the result in a float. Synchronous, like
--- `:checkhealth` — this is the user deliberately asking, never a background
--- or editing path.
function M.open()
  close()
  local width = math.min(WIDTH, math.max(vim.o.columns - 4, 20))
  local lines, marks = M.render(diagnostics.run(), width)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, mark in ipairs(marks) do
    -- Belt: a future render bug degrades to a short highlight here, never
    -- an open() error — clamp against the line actually written to the buffer.
    local line_bytes = #(lines[mark.row + 1] or '')
    local end_col = math.min(mark.end_col, line_bytes)
    vim.api.nvim_buf_set_extmark(buf, NS, mark.row, math.min(mark.col, end_col), {
      end_col = end_col,
      hl_group = mark.hl,
      strict = false,
    })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  local height = math.max(math.min(#lines, vim.o.lines - 4), 1)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2), 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = 'rounded',
    title = ' nvime doctor ',
    title_pos = 'center',
    footer = ' q close ',
    footer_pos = 'right',
  })
  -- Everything is pre-wrapped to the border, so display wrap is only a
  -- backstop; `linebreak` keeps that backstop off the middle of a word.
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  modes.normal()
  view.win, view.buf = win, buf
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, close, { buffer = buf, nowait = true, silent = true, desc = 'nvime: close' })
  end
end

function M.close()
  close()
end

--- Test hook: the float on screen, or nil.
function M.current()
  return view
end

return M
