--- A small floating list. Deliberately not `vim.fn.inputlist`/`confirm`: nvime
--- never opens a modal prompt, so every choice is a float with keybinds that
--- the user can dismiss without answering.
local M = {}

local MAX_HEIGHT = 12

local function close(win, buf)
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- @param items table[] each with `label` (string) and `value` (any)
--- @param opts table title, on_choice(value)
function M.open(items, opts)
  assert(type(items) == 'table', 'picker.open needs an items list')
  assert(type(opts.on_choice) == 'function', 'picker.open needs an on_choice callback')
  if #items == 0 then
    vim.notify('nvime: no sessions yet for this project', vim.log.levels.INFO)
    return nil
  end

  local labels = vim.tbl_map(function(item)
    return item.label
  end, items)
  local width = 0
  for _, label in ipairs(labels) do
    width = math.max(width, vim.fn.strdisplaywidth(label))
  end
  width = math.min(math.max(width + 2, 30), math.floor(vim.o.columns * 0.8))
  local height = math.min(#items, MAX_HEIGHT)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, labels)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = opts.title or 'nvime',
    title_pos = 'center',
  })
  vim.wo[win].cursorline = true

  local function dismiss()
    close(win, buf)
  end
  local function choose()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local item = items[row]
    dismiss()
    if item ~= nil then
      opts.on_choice(item.value)
    end
  end

  local map = function(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map('<CR>', choose)
  map('q', dismiss)
  map('<Esc>', dismiss)
  return win
end

return M
