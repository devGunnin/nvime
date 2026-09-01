--- `:Nvime doctor` — the "why doesn't it work" front door: the same checks
--- `:checkhealth nvime` runs (`diagnostics.lua`), rendered as one glanceable
--- pass/warn/fail list with the fix named right under each failure, instead
--- of the generic health buffer.
local diagnostics = require('nvime.diagnostics')

local M = {}

local WIDTH = 78

local SYMBOL = { ok = ' OK ', warn = 'WARN', error = 'FAIL', info = ' .. ' }

local view = { win = nil, buf = nil }

--- One entry, as its symbol and message, with the fix on the line under it
--- when there is one to show.
--- @param entry table { level, message, advice }
--- @return string[]
function M.render_entry(entry)
  assert(type(entry) == 'table', 'doctor.render_entry needs an entry')
  local lines = { string.format('%s  %s', SYMBOL[entry.level] or ' ?? ', entry.message) }
  if entry.advice ~= nil and entry.advice ~= '' then
    lines[#lines + 1] = '        fix: ' .. entry.advice
  end
  return lines
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

--- The whole page. Pure, so the layout is testable without a window.
--- @param entries table[]
--- @return string[]
function M.render(entries)
  assert(type(entries) == 'table', 'doctor.render needs a list of diagnostic entries')
  local lines = { ' nvime doctor', '' }
  for _, entry in ipairs(entries) do
    vim.list_extend(lines, M.render_entry(entry))
  end
  local failing = count(entries, 'error')
  local warning = count(entries, 'warn')
  lines[#lines + 1] = ''
  if failing > 0 then
    lines[#lines + 1] = string.format(' %d failing, %d warning — fix the failures above first', failing, warning)
  elseif warning > 0 then
    lines[#lines + 1] = string.format(' all clear except %d warning', warning)
  else
    lines[#lines + 1] = ' all clear'
  end
  return lines
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
  local lines = M.render(diagnostics.run())
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  local width = math.min(WIDTH, math.max(vim.o.columns - 4, 20))
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
  })
  vim.wo[win].wrap = true
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
