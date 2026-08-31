--- The permission prompt for a tool nvime will not auto-allow: a small float
--- with `y`/`n`, never `vim.fn.confirm`. Nothing blocks — the editor stays
--- usable while the sidecar holds the tool call, and the answer travels back
--- through the same RPC as everything else.
---
--- Asks queue: one float at a time, in arrival order, so a run that trips two
--- rules does not stack windows on top of each other.
local M = {}

local WIDTH = 64

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

local function body(request)
  return {
    ' claude wants to:',
    '   ' .. (request.summary or request.tool or 'run a tool'),
    '',
    ' nvime will not allow that on its own:',
    '   ' .. (request.reason or 'outside the agreed scope'),
    '',
    ' y  allow once      n  deny',
  }
end

--- Opens the float for `ask` and wires `y`/`n`/`<Esc>` to `answer`.
local function show(ask, answer)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body(ask.request))
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  local height = vim.api.nvim_buf_line_count(buf)
  local width = math.min(WIDTH, math.max(vim.o.columns - 4, 20))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = math.max(math.min(height, vim.o.lines - 2), 1),
    row = math.max(math.floor((vim.o.lines - height) / 2), 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = 'rounded',
    title = ' nvime · approve? ',
    title_pos = 'center',
  })
  active = { win = win, buf = buf, request = ask.request, on_answer = ask.on_answer }

  local function map(lhs, allow)
    vim.keymap.set('n', lhs, function()
      answer(allow)
    end, { buffer = buf, nowait = true, silent = true, desc = 'nvime: answer the approval' })
  end
  map('y', true)
  map('Y', true)
  map('n', false)
  map('N', false)
  map('<Esc>', false)
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
