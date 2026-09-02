--- A y/n float for an action the reader cannot take back.
---
--- Deliberately not `vim.fn.confirm`: that blocks the editor and cannot be
--- driven by a test. It binds exactly `keymaps.CONFIRM`, which the registry
--- lists, so the leaf-only check cannot go blind to a live mapping.
local keymaps = require('nvime.keymaps')
local text = require('nvime.text')
local modes = require('nvime.modes')

local M = {}

local NS = vim.api.nvim_create_namespace('nvime.confirm')
local WIDTH = 64
local GROUP = vim.api.nvim_create_augroup('nvime.confirm', { clear = true })

--- The question on screen, or nil: { win, buf, on_answer }. One at a time — a
--- second float over an unanswered question would hide the decision it is
--- stacked on — so this latch has to clear on EVERY way the float can die, not
--- only on its own keys.
local active = nil

--- Answers the question once and takes the float down. `active` is cleared
--- first, so the window close below re-entering through the watcher below
--- finds nothing to answer twice.
--- @param yes boolean
local function settle(yes)
  local entry = active
  if entry == nil then
    return
  end
  active = nil
  vim.api.nvim_clear_autocmds({ group = GROUP })
  if vim.api.nvim_win_is_valid(entry.win) then
    pcall(vim.api.nvim_win_close, entry.win, true)
  end
  if vim.api.nvim_buf_is_valid(entry.buf) then
    pcall(vim.api.nvim_buf_delete, entry.buf, { force = true })
  end
  entry.on_answer(yes)
end

--- Closing the question is a no: `:q`, `<C-w>o`, a `:tabclose` of the tab it
--- opened over, or the review taking its own tab down.
--- @param win integer the float's window
--- @param buf integer the float's buffer
local function watch(win, buf)
  vim.api.nvim_create_autocmd('WinClosed', {
    group = GROUP,
    pattern = tostring(win),
    desc = 'nvime: a question closed unanswered is a no',
    callback = function()
      settle(false)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = GROUP,
    buffer = buf,
    desc = 'nvime: a question wiped unanswered is a no',
    callback = function()
      settle(false)
    end,
  })
end

--- Dismisses an unanswered question as a no. For when the decision it asks
--- about has been taken by another route and the float would otherwise sit
--- there ready to take it a second time.
function M.dismiss()
  settle(false)
end

--- The float's lines, and the marks that colour the two keys.
--- @param question string
--- @param width integer columns available inside the border
--- @return string[] lines
--- @return table[] marks each { row = 0-based, col, end_col, hl }
function M.render(question, width)
  assert(type(question) == 'string' and question ~= '', 'confirm.render needs a question')
  assert(type(width) == 'number' and width > 2, 'confirm.render needs a width')
  local lines = {}
  for _, line in ipairs(text.wrap(question, width - 2)) do
    lines[#lines + 1] = ' ' .. line
  end
  lines[#lines + 1] = ''
  local keys_row = #lines
  lines[#lines + 1] = ' y  yes      n  no'
  local marks = {}
  for _, key in ipairs({ 'y', 'n' }) do
    local col = lines[keys_row + 1]:find('%f[%a]' .. key .. '%f[%A]')
    if col ~= nil then
      marks[#marks + 1] = { row = keys_row, col = col - 1, end_col = col, hl = 'NvimeKey' }
    end
  end
  return lines, marks
end

--- Asks `question`. `on_answer(true)` runs only on an explicit yes; every
--- other way the question goes away — `n`, `<Esc>`, or the float being closed,
--- wiped or dismissed — answers false. It runs exactly once, or never, when a
--- float is already up and this ask is refused rather than stacked on it.
--- @param question string
--- @param on_answer fun(yes: boolean)
--- @return boolean whether the float was opened
function M.ask(question, on_answer)
  assert(type(question) == 'string' and question ~= '', 'confirm.ask needs a question')
  assert(type(on_answer) == 'function', 'confirm.ask needs an answer callback')
  if active ~= nil and not vim.api.nvim_win_is_valid(active.win) then
    -- Belt and braces: a teardown that suppressed the watcher below must not
    -- leave a dead question latched over every later one.
    settle(false)
  end
  if active ~= nil then
    vim.notify('nvime: answer the question already on screen first', vim.log.levels.WARN)
    return false
  end
  local width = math.min(WIDTH, math.max(vim.o.columns - 4, 20))
  local lines, marks = M.render(question, width)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, NS, mark.row, mark.col, {
      end_col = mark.end_col,
      hl_group = mark.hl,
      strict = false,
    })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  local height = #lines
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = math.max(math.min(height, vim.o.lines - 2), 1),
    row = math.max(math.floor((vim.o.lines - height) / 2), 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = 'rounded',
    title = ' nvime · are you sure? ',
    title_pos = 'center',
  })
  active = { win = win, buf = buf, on_answer = on_answer }
  watch(win, buf)
  modes.normal()
  for _, key in ipairs(keymaps.CONFIRM) do
    vim.keymap.set('n', key.lhs, function()
      settle(key.allow)
    end, { buffer = buf, nowait = true, silent = true, desc = key.desc })
  end
  return true
end

--- Test hook: the float on screen, or nil.
function M.current()
  return active
end

return M
