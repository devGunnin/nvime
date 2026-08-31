--- A small floating editor for one piece of free text — a review comment, or
--- the answer that defends a review thread.
---
--- Deliberately not `vim.fn.input`: that blocks the editor and cannot be left
--- half-written. This is an ordinary modifiable buffer in a float, so the user
--- can edit, undo and abandon it like any other text.
local M = {}

local WIDTH = 72
local HEIGHT = 6

--- A single change that adds more than this many characters is a paste, not
--- typing. Chosen well above any one keystroke and well below a sentence.
local PASTE_BURST = 24

local PASTE_REFUSAL = "type it — that's the point"

local active = nil

local function close()
  if active == nil then
    return
  end
  local win, buf, detach = active.win, active.buf, active.detach
  active = nil
  if detach ~= nil then
    detach()
  end
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- @param before string[]
--- @param after string[]
--- @return integer characters `after` has that `before` did not
local function added_chars(before, after)
  local function size(lines)
    local total = 0
    for _, line in ipairs(lines) do
      total = total + #line
    end
    return total
  end
  return size(after) - size(before)
end

--- Whether one change looks like a paste rather than a keystroke.
---
--- Mechanism-independent on purpose: bracketed paste, `<C-r>`, `:put`, and any
--- future route all land here as one change that grew the buffer by more than a
--- person can type at once. A blocklist of paste KEYS would only cover the
--- routes it happened to name.
--- @param before string[]
--- @param after string[]
--- @return boolean
function M.is_paste(before, after)
  assert(type(before) == 'table' and type(after) == 'table', 'compose.is_paste needs two line lists')
  if #after > #before + 1 then
    return true
  end
  return added_chars(before, after) > PASTE_BURST
end

--- How many earlier states are remembered, so undo/redo is not read as a paste.
local SEEN_LIMIT = 64

--- Watches `buf` and undoes any change that arrives faster than typing.
---
--- `nvim_buf_attach` sees every change whatever made it, which is the point:
--- bracketed paste, `<C-r>`, `:put` and anything else all arrive here. A
--- blocklist of paste KEYS would only cover the routes it happened to name.
---
--- Content this buffer has already held is always allowed back — that is what
--- redo restores, and text the user typed once is text they typed.
---
--- The revert is scheduled because a buffer may not be written from inside the
--- callback, so pasted text is on screen for one tick. The refusal says so
--- rather than pretending nothing happened.
--- @param buf integer
--- @param win integer the float, so the cursor lands back in it
--- @return fun() detach
local function block_paste(buf, win)
  local accepted = lines_of(buf)
  local seen = { [table.concat(accepted, '\n')] = true }
  local order = {}
  local detached = false
  local reverting = false

  local function remember(current)
    accepted = current
    local key = table.concat(current, '\n')
    if seen[key] then
      return
    end
    seen[key] = true
    order[#order + 1] = key
    if #order > SEEN_LIMIT then
      seen[table.remove(order, 1)] = nil
    end
  end

  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if detached then
        return true
      end
      if reverting then
        return
      end
      vim.schedule(function()
        if detached or not vim.api.nvim_buf_is_valid(buf) then
          return
        end
        local current = lines_of(buf)
        if seen[table.concat(current, '\n')] or not M.is_paste(accepted, current) then
          remember(current)
          return
        end
        reverting = true
        pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, accepted)
        reverting = false
        if vim.api.nvim_win_is_valid(win) then
          pcall(vim.api.nvim_win_set_cursor, win, { #accepted, #(accepted[#accepted] or '') })
        end
        vim.notify('nvime: ' .. PASTE_REFUSAL, vim.log.levels.WARN)
      end)
    end,
  })
  return function()
    detached = true
  end
end

--- Opens the float. `on_submit(text)` runs at most once, and never with empty
--- text — an accidental `<CR>` on a blank comment is a dismissal, not a send.
---
--- With `no_paste`, the buffer takes typed text only: the put mappings refuse
--- outright and anything that gets past them is undone. There is no escape
--- hatch and none is planned — a defense you pasted is not a defense.
--- @param opts table title, hint, on_submit(text), no_paste (boolean), text (string[])
--- @return integer|nil window handle
function M.open(opts)
  assert(type(opts) == 'table', 'compose.open needs an options table')
  assert(type(opts.on_submit) == 'function', 'compose.open needs an on_submit callback')
  close()

  local width = math.min(WIDTH, math.max(vim.o.columns - 4, 20))
  local height = math.max(math.min(opts.height or HEIGHT, vim.o.lines - 2), 1)
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
    local text = vim.trim(table.concat(lines_of(buf), '\n'))
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

  if opts.no_paste then
    local function refuse()
      vim.notify('nvime: ' .. PASTE_REFUSAL, vim.log.levels.WARN)
    end
    for _, lhs in ipairs(require('nvime.keymaps').COMPOSE_PUT) do
      bind('n', lhs, refuse)
    end
    -- `<C-r>` in insert mode is a register put; it is the one paste route that
    -- is a single keystroke, so it gets its own refusal rather than a revert.
    bind('i', '<C-r>', refuse)
    active.detach = block_paste(buf, win)
  end

  vim.cmd('startinsert')
  return win
end

--- Test hook: the float on screen, or nil.
function M.current()
  return active
end

--- Closes whatever is open. Safe to call repeatedly.
M.dismiss = close

M.PASTE_REFUSAL = PASTE_REFUSAL

return M
