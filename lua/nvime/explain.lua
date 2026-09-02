--- The post-clear `e`: a small float with the agent's plain-language
--- explanation of one thread's hunks. Read-only, and only ever asked for once
--- the sidecar will actually answer — see `threads.lua`'s `e` key, which
--- mirrors the server-side gate so the float is never opened on a refusal.
local modes = require('nvime.modes')

local M = {}

local WIDTH = 76

local active = nil

local function close()
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

--- `text` wrapped to `width` columns, its own newlines kept. Character-based,
--- so a multi-byte explanation is never cut in half.
--- @param text string
--- @param width integer columns available inside the border
--- @return string[]
function M.render(text, width)
  assert(type(text) == 'string', 'explain.render needs text')
  assert(type(width) == 'number' and width > 0, 'explain.render needs a positive width')
  local lines = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local total = vim.fn.strchars(line)
    if total == 0 then
      lines[#lines + 1] = ''
    end
    local at = 0
    while at < total do
      lines[#lines + 1] = vim.fn.strcharpart(line, at, width)
      at = at + width
    end
  end
  if #lines == 0 then
    lines[1] = ''
  end
  return lines
end

local function open_float(title, lines)
  close()
  local width = math.min(WIDTH, math.max(vim.o.columns - 4, 20))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'markdown'
  local height = math.max(math.min(#lines, vim.o.lines - 4), 1)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2), 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = 'rounded',
    title = ' explain · ' .. title .. ' ',
    title_pos = 'center',
  })
  vim.wo[win].wrap = true
  active = { win = win, buf = buf }
  modes.normal()
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, close, { buffer = buf, nowait = true, silent = true, desc = 'nvime: close' })
  end
end

--- Opens the float with a placeholder while the agent turn runs.
--- @param title string the thread's title
function M.pending(title)
  assert(type(title) == 'string', 'explain.pending needs a title')
  open_float(title, { ' asking claude to explain this…' })
end

--- Fills the float with the explanation (or a failure message), replacing
--- whatever was there — the placeholder, or an earlier thread's answer.
--- @param title string
--- @param text string
function M.show(title, text)
  assert(type(title) == 'string', 'explain.show needs a title')
  assert(type(text) == 'string', 'explain.show needs text')
  local width = math.max(math.min(WIDTH, math.max(vim.o.columns - 4, 20)) - 2, 8)
  open_float(title, M.render(text, width))
end

--- Test hook: the float on screen, or nil.
function M.current()
  return active
end

function M.close()
  close()
end

return M
