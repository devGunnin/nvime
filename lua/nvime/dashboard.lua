--- `:Nvime` with no argument: one float that answers "what is going on, and
--- what do I press".
---
--- It lists this project's big changes with where each one is and how much of
--- its review is left, and it opens them: `<CR>` on a change loads it into the
--- big panel. Everything else is one keystroke away from here, so the dashboard
--- is the front door rather than a printed help page.
---
--- The session list is asked for, not cached. A float that showed a stale
--- "2 open" would be worse than one that says it could not reach the sidecar.
local agent = require('nvime.agent')

local M = {}

local WIDTH = 78
local MAX_HEIGHT = 22

local view = {
  win = nil,
  buf = nil,
  --- Row (1-based) -> the session id on it, for `<CR>`.
  rows = {},
}

--- The entry points, in the order they are worth learning.
local ENTRIES = {
  { key = 'c', label = 'chat', summary = 'read-only conversation, with session resume' },
  { key = 'e', label = 'edit', summary = 'point-and-change, applied live in the buffer' },
  { key = 'b', label = 'big', summary = 'spec, sandboxed build, gated review, local merge' },
  { key = 'd', label = 'diff', summary = 'the changeset of the last edit run' },
}

--- One line per big change: where it is, and how much of its review is left.
--- @param session table a list summary from `big.list`
--- @return string
function M.session_line(session)
  assert(type(session) == 'table', 'dashboard.session_line needs a session')
  local counts = session.counts or {}
  local substantial = counts.substantial or 0
  local progress = ''
  if session.display == 'merged' then
    progress = 'landed'
  elseif session.difficulty == 'vibe' and (counts.total or 0) > 0 then
    -- Said outright: `0 open` on a session that runs no gate means nothing was
    -- defended, not that everything was.
    progress = string.format('%d thread(s), no gate', counts.total)
  elseif substantial > 0 then
    progress = string.format('%d/%d defended', counts.defended or 0, substantial)
  elseif (counts.total or 0) > 0 then
    progress = string.format('%d thread(s), nothing to defend', counts.total)
  end
  local where = session.display or 'drafting'
  if session.heldElsewhere then
    where = where .. '*'
  end
  return string.format('  %-11s %-24s %s', where, progress, session.title or '(untitled)')
end

--- The whole page. Pure, so the layout is testable without a window.
--- @param facts table sidecar (string), build (string), sessions (table[]), error (string|nil)
--- @return string[] lines
--- @return table rows row -> session id, for the rows that carry one
function M.render(facts)
  assert(type(facts) == 'table', 'dashboard.render needs a facts table')
  local lines = { 'nvime — no vibe coding in my editor', '' }
  for _, entry in ipairs(ENTRIES) do
    lines[#lines + 1] = string.format('  %s  %-6s %s', entry.key, entry.label, entry.summary)
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = '  sidecar  ' .. facts.sidecar
  lines[#lines + 1] = '  build    ' .. facts.build
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'big changes in this project'

  local rows = {}
  if facts.error ~= nil then
    lines[#lines + 1] = '  ! ' .. facts.error
  elseif #(facts.sessions or {}) == 0 then
    lines[#lines + 1] = '  none yet — press b and describe one'
  else
    for _, session in ipairs(facts.sessions) do
      lines[#lines + 1] = M.session_line(session)
      rows[#lines] = session.id
    end
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = '  <CR> open a change · q close · :checkhealth nvime'
  return lines, rows
end

local function close()
  local win, buf = view.win, view.buf
  view.win, view.buf, view.rows = nil, nil, {}
  if win ~= nil and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- `<CR>`: load the change under the cursor into the big panel.
local function open_under_cursor()
  if view.win == nil or not vim.api.nvim_win_is_valid(view.win) then
    return
  end
  local id = view.rows[vim.api.nvim_win_get_cursor(view.win)[1]]
  if id == nil then
    return
  end
  close()
  local big = require('nvime.big')
  big.open()
  big.select(id)
end

local function draw(lines, rows)
  if view.buf == nil or not vim.api.nvim_buf_is_valid(view.buf) then
    return
  end
  view.rows = rows
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  if view.win ~= nil and vim.api.nvim_win_is_valid(view.win) then
    vim.api.nvim_win_set_height(view.win, math.min(#lines, MAX_HEIGHT))
  end
end

--- Every keystroke the float binds. Each is a leaf, and `keymaps.all` lists
--- exactly this table so the prefix check cannot go blind to one.
M.KEYS = {
  { lhs = 'c', desc = 'nvime: open chat' },
  { lhs = 'e', desc = 'nvime: edit this file' },
  { lhs = 'b', desc = 'nvime: open a big change' },
  { lhs = 'd', desc = 'nvime: review the changeset' },
  { lhs = '<CR>', desc = 'nvime: open the change under the cursor' },
  { lhs = 'q', desc = 'nvime: close the dashboard' },
  { lhs = '<Esc>', desc = 'nvime: close the dashboard' },
}

local function jump(fn)
  return function()
    close()
    fn()
  end
end

local function bind(buf)
  local nvime = require('nvime')
  local actions = {
    c = jump(nvime.chat),
    e = jump(nvime.edit),
    b = jump(nvime.big),
    d = jump(nvime.changeset),
    ['<CR>'] = open_under_cursor,
    q = close,
    ['<Esc>'] = close,
  }
  for _, key in ipairs(M.KEYS) do
    vim.keymap.set('n', key.lhs, actions[key.lhs], { buffer = buf, nowait = true, silent = true, desc = key.desc })
  end
end

--- Opens the dashboard and fills in the session list when it arrives.
function M.open()
  close()
  local height = MAX_HEIGHT
  local width = math.min(WIDTH, math.max(vim.o.columns - 4, 30))
  view.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[view.buf].bufhidden = 'wipe'
  vim.bo[view.buf].filetype = 'nvimedashboard'
  view.win = vim.api.nvim_open_win(view.buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2), 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = 'rounded',
    title = ' nvime ',
    title_pos = 'center',
  })
  vim.wo[view.win].cursorline = true
  bind(view.buf)

  local facts = {
    sidecar = agent.is_running() and 'running' or 'starts on first use',
    build = vim.uv.fs_stat(agent.dist_path()) ~= nil and 'present' or ('missing — ' .. agent.build_hint()),
    sessions = {},
  }
  draw(M.render(facts))

  local root = require('nvime.context').project_root()
  agent.request('big.list', { root = root }, function(err, result)
    if err ~= nil then
      facts.error = err.message or 'could not reach the sidecar'
    else
      facts.sessions = (result or {}).sessions or {}
    end
    draw(M.render(facts))
  end)
end

--- Test hook: the float on screen.
function M.current()
  return view
end

M.dismiss = close

return M
