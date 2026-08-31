--- A small floating editor for one piece of free text — a review comment.
---
--- Deliberately not `vim.fn.input`: that blocks the editor and cannot be left
--- half-written. This is an ordinary modifiable buffer in a float, so the user
--- can edit, undo and abandon it like any other text.
local M = {}

local WIDTH = 72
local HEIGHT = 6

local active = nil

local function close()
  if active == nil then
    return
  end
  local win, buf = active.win, active.buf
  active = nil
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- Opens the float. `on_submit(text)` runs at most once, and never with empty
--- text — an accidental `<CR>` on a blank comment is a dismissal, not a send.
--- @param opts table title, hint, on_submit(text)
--- @return integer|nil window handle
function M.open(opts)
  assert(type(opts) == 'table', 'compose.open needs an options table')
  assert(type(opts.on_submit) == 'function', 'compose.open needs an on_submit callback')
  close()

  local width = math.min(WIDTH, math.max(vim.o.columns - 4, 20))
  local height = math.max(math.min(HEIGHT, vim.o.lines - 2), 1)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2), 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = 'rounded',
    title = opts.title or ' nvime ',
    title_pos = 'center',
  })
  vim.wo[win].wrap = true
  vim.wo[win].winbar = '%#NvimeDim#' .. (opts.hint or '<CR> send · <Esc> cancel')
  active = { win = win, buf = buf }

  local function submit()
    local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
    close()
    if text ~= '' then
      opts.on_submit(text)
    end
  end
  local function bind(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  bind('n', '<CR>', submit)
  bind('i', '<C-s>', submit)
  bind('n', 'q', close)
  bind('n', '<Esc>', close)
  vim.cmd('startinsert')
  return win
end

--- Test hook: the float on screen, or nil.
function M.current()
  return active
end

--- Closes whatever is open. Safe to call repeatedly.
M.dismiss = close

return M
