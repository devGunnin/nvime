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
local text = require('nvime.text')

local M = {}

local WIDTH = 96
local MAX_HEIGHT = 24
local NS = vim.api.nvim_create_namespace('nvime.dashboard')

--- Columns the session table is laid out on, so the title's room is known.
local WHERE_WIDTH, PROGRESS_WIDTH = 11, 24
local TITLE_COL = 2 + WHERE_WIDTH + 1 + PROGRESS_WIDTH + 1

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

--- The colour a change's state is drawn in, so the list scans by shape.
local STATE_HL = {
  merged = 'NvimeOk',
  reviewing = 'NvimeWarn',
  mergeable = 'NvimeOk',
  building = 'NvimeActivity',
  triaging = 'NvimeActivity',
  drafting = 'NvimeDim',
}

--- The states of the preflight facts that are actually good news. Anything
--- else is neutral or a failure, and neither is painted as "all set".
local READY = { running = true, present = true }

--- @param value string the fact as it is written on the page
--- @return string highlight group
function M.fact_hl(value)
  assert(type(value) == 'string', 'dashboard.fact_hl needs a fact')
  if READY[value] then
    return 'NvimeOk'
  end
  return value:find('missing') ~= nil and 'NvimeError' or 'NvimeDim'
end

--- One line per big change: where it is, and how much of its review is left.
--- @param session table a list summary from `big.list`
--- @param title_width integer|nil cells the title may occupy before it is cut
--- @return string
function M.session_line(session, title_width)
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
  local title = session.title or '(untitled)'
  if title_width ~= nil then
    -- Cut, never wrapped: a wrapped title shifts every row below it out of
    -- step with the session it opens.
    title = text.ellipsise(title, math.max(title_width, 8))
  end
  return string.format('  %-' .. WHERE_WIDTH .. 's %-' .. PROGRESS_WIDTH .. 's %s', where, progress, title)
end

--- The whole page. Pure, so the layout is testable without a window.
--- @param facts table sidecar (string), build (string), sessions (table[]), error (string|nil)
--- @param width integer|nil columns available inside the border
--- @return string[] lines
--- @return table rows row -> session id, for the rows that carry one
--- @return table[] marks each { row = 0-based, col, end_col, hl }
function M.render(facts, width)
  assert(type(facts) == 'table', 'dashboard.render needs a facts table')
  local title_width = math.max((width or WIDTH) - TITLE_COL, 12)
  -- A blank line at each end, so the page breathes inside its border.
  local lines, marks = { '', ' nvime — no vibe coding in my editor', '' }, {}
  -- end_col < 0 means "to the end of this row's own line": resolved here to
  -- the line's real byte length. nvim 0.11 errors on end_row given without an
  -- end_col, even with strict=false — 0.12 silently tolerates it.
  local function mark(row, col, end_col, hl)
    if end_col < 0 then
      end_col = #(lines[row + 1] or '')
    end
    marks[#marks + 1] = { row = row, col = col, end_col = end_col, hl = hl }
  end
  mark(1, 0, -1, 'NvimeHeading')

  for _, entry in ipairs(ENTRIES) do
    lines[#lines + 1] = string.format('  %s  %-6s %s', entry.key, entry.label, entry.summary)
    mark(#lines - 1, 2, 3, 'NvimeKey')
    mark(#lines - 1, 5, 11, 'NvimeFile')
    mark(#lines - 1, 12, -1, 'NvimeDim')
  end
  lines[#lines + 1] = ''
  for _, row in ipairs({ { 'sidecar  ', facts.sidecar }, { 'build    ', facts.build } }) do
    lines[#lines + 1] = '  ' .. row[1] .. row[2]
    mark(#lines - 1, 0, 2 + #row[1], 'NvimeLabel')
    mark(#lines - 1, 2 + #row[1], -1, M.fact_hl(row[2]))
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = ' big changes in this project'
  mark(#lines - 1, 0, -1, 'NvimeHeading')

  local rows = {}
  if facts.error ~= nil then
    lines[#lines + 1] = '  ! ' .. facts.error
    mark(#lines - 1, 0, -1, 'NvimeError')
  elseif #(facts.sessions or {}) == 0 then
    lines[#lines + 1] = '  none yet — press b and describe one'
    mark(#lines - 1, 0, -1, 'NvimeDim')
  else
    for _, session in ipairs(facts.sessions) do
      lines[#lines + 1] = M.session_line(session, title_width)
      rows[#lines] = session.id
      mark(#lines - 1, 2, 2 + WHERE_WIDTH, STATE_HL[session.display] or 'NvimeDim')
      mark(#lines - 1, 2 + WHERE_WIDTH, TITLE_COL, 'NvimeDim')
    end
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = '  <CR> open a change · q close · :checkhealth nvime'
  mark(#lines - 1, 0, -1, 'NvimeDim')
  lines[#lines + 1] = ''
  return lines, rows, marks
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

local function draw(lines, rows, marks)
  if view.buf == nil or not vim.api.nvim_buf_is_valid(view.buf) then
    return
  end
  view.rows = rows
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(view.buf, NS, 0, -1)
  for _, mark in ipairs(marks or {}) do
    -- Belt: a future render bug degrades to a short highlight here, never
    -- a draw() error — clamp against the line actually written to the buffer.
    local line_bytes = #(lines[mark.row + 1] or '')
    local end_col = math.min(mark.end_col, line_bytes)
    vim.api.nvim_buf_set_extmark(view.buf, NS, mark.row, math.min(mark.col, end_col), {
      end_col = end_col,
      hl_group = mark.hl,
      strict = false,
    })
  end
  if view.win ~= nil and vim.api.nvim_win_is_valid(view.win) then
    vim.api.nvim_win_set_height(view.win, math.max(math.min(#lines, MAX_HEIGHT), 1))
    -- On the first change, not on the banner: the cursorline then reads as a
    -- selection rather than as a stripe across the title.
    local first = nil
    for row in pairs(rows) do
      first = first == nil and row or math.min(first, row)
    end
    pcall(vim.api.nvim_win_set_cursor, view.win, { first or 1, 0 })
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
  vim.wo[view.win].winhighlight = 'CursorLine:NvimeCursorLine'
  bind(view.buf)

  local facts = {
    sidecar = agent.is_running() and 'running' or 'starts on first use',
    build = vim.uv.fs_stat(agent.dist_path()) ~= nil and 'present' or ('missing — ' .. agent.build_hint()),
    sessions = {},
  }
  draw(M.render(facts, width))

  local root = require('nvime.context').project_root()
  agent.request('big.list', { root = root }, function(err, result)
    if err ~= nil then
      facts.error = err.message or 'could not reach the sidecar'
    else
      facts.sessions = (result or {}).sessions or {}
    end
    draw(M.render(facts, width))
  end)
end

--- Test hook: the float on screen.
function M.current()
  return view
end

M.dismiss = close

return M
