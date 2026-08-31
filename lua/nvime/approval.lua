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

local M = {}

local WIDTH = 72

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

--- `text` broken into rendered lines of at most `width` characters, its own
--- newlines kept. Character-based, so a multi-byte payload is never cut in
--- half; nothing is ever elided.
--- @return string[]
local function wrapped(text, width)
  local out = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local total = vim.fn.strchars(line)
    if total == 0 then
      out[#out + 1] = ''
    end
    local at = 0
    while at < total do
      out[#out + 1] = vim.fn.strcharpart(line, at, width)
      at = at + width
    end
  end
  return out
end

--- The float's contents.
---
--- The decision and its keys sit at the top, where they stay visible however
--- long the payload below them is; the payload itself follows in full.
--- @param request table approvalId, tool, summary, reason, detail
--- @param width integer columns available inside the border
--- @return string[] lines
--- @return integer|nil warn 1-based row of the truncation banner, if any
function M.render(request, width)
  assert(type(request) == 'table', 'approval.render needs a request')
  local lines = {
    ' claude wants to:',
    INDENT .. (request.summary or request.tool or 'run a tool'),
    '',
    ' nvime will not allow that on its own:',
    INDENT .. (request.reason or 'outside the agreed scope'),
    '',
    ' y  allow once      n  deny',
  }
  local detail = request.detail
  if type(detail) ~= 'table' or type(detail.text) ~= 'string' or detail.text == '' then
    return lines, nil
  end
  local body = wrapped(detail.text, math.max(width - #INDENT, 8))
  lines[#lines + 1] = string.format(
    ' the exact %s — %d line%s, %d byte%s:',
    detail.kind or 'value',
    #body,
    #body == 1 and '' or 's',
    detail.bytes or #detail.text,
    (detail.bytes or #detail.text) == 1 and '' or 's'
  )
  local warn = nil
  if detail.truncated then
    lines[#lines + 1] =
      string.format(' !! TRUNCATED — nvime can only show you %d of %d bytes', #detail.text, detail.bytes)
    warn = #lines
  end
  for _, line in ipairs(body) do
    lines[#lines + 1] = INDENT .. line
  end
  return lines, warn
end

--- Opens the float for `ask` and wires the approval keys to `answer`.
local function show(ask, answer)
  local width = math.min(WIDTH, math.max(vim.o.columns - 4, 20))
  local lines, warn = M.render(ask.request, width)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  if warn ~= nil then
    vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace('nvime.approval'), warn - 1, 0, {
      line_hl_group = 'NvimeError',
    })
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

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
  vim.wo[win].wrap = true
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
