--- The review threads of a big change: the thread list on the left, the hunks
--- of the selected thread on the right, in their own tabpage.
---
--- Trivia is auto-resolved but never hidden — it sits in the list with an
--- `auto` chip and `X` re-opens it, so the reader always knows everything that
--- changed. The comprehension gate that clears a substantial thread is P4;
--- `a` says so rather than pretending to grade.
local agent = require('nvime.agent')

local M = {}

local NS = vim.api.nvim_create_namespace('nvime.threads')
local TREE_WIDTH = 40

--- The chip a thread carries, its highlight, and what the reader does about it.
local CHIPS = {
  defend = { text = 'DEFEND', hl = 'NvimeThreadDefend' },
  clear = { text = '  ok  ', hl = 'NvimeThreadClear' },
  auto = { text = ' auto ', hl = 'NvimeThreadAuto' },
  reopened = { text = ' OPEN ', hl = 'NvimeThreadOpen' },
}

local view = {
  root = nil,
  session = nil,
  on_update = nil,
  --- The captured diff, split once; hunks are sliced out of it by offset.
  diff_lines = {},
  --- Hunk id -> { file, offset, lineCount, note }.
  hunks = {},
  selected = 1,
  tab = nil,
  tree_win = nil,
  tree_buf = nil,
  pane_win = nil,
  pane_buf = nil,
}

--- @param block table
--- @return table the chip for this block's state
function M.chip(block)
  if block.substantial then
    return block.state == 'open' and CHIPS.defend or CHIPS.clear
  end
  return block.state == 'open' and CHIPS.reopened or CHIPS.auto
end

--- The thread list as it is drawn.
--- @param blocks table[]
--- @return string[] lines
--- @return table[] highlights, each { row = 0-based, hl = group }
function M.tree_lines(blocks)
  assert(type(blocks) == 'table', 'threads.tree_lines needs a block list')
  local lines, highlights = {}, {}
  for index, block in ipairs(blocks) do
    local chip = M.chip(block)
    local files = #(block.files or {})
    local suffix = files > 1 and string.format(' (%d files)', files) or ''
    lines[#lines + 1] = string.format('%s %s%s', chip.text, block.title, suffix)
    highlights[#highlights + 1] = { row = index - 1, hl = chip.hl }
  end
  if #lines == 0 then
    lines[1] = 'nothing changed in this build.'
  end
  return lines, highlights
end

--- The hunks of one thread, sliced out of the captured diff.
--- @param block table
--- @return string[]
function M.pane_lines(block)
  if block == nil then
    return { 'no thread selected.' }
  end
  local lines = { block.title, '' }
  if block.rationale ~= nil and block.rationale ~= '' then
    lines = { block.title, '# ' .. block.rationale, '' }
  end
  local shown_file = nil
  for _, id in ipairs(block.hunkIds or {}) do
    local hunk = view.hunks[id]
    if hunk == nil then
      lines[#lines + 1] = '(hunk ' .. id .. ' is not in the captured diff)'
    else
      if hunk.file ~= shown_file then
        shown_file = hunk.file
        lines[#lines + 1] = '--- ' .. hunk.file
      end
      if hunk.note ~= nil then
        lines[#lines + 1] = hunk.note
      else
        for at = hunk.offset + 1, hunk.offset + hunk.lineCount do
          lines[#lines + 1] = view.diff_lines[at] or ''
        end
      end
      lines[#lines + 1] = ''
    end
  end
  return lines
end

local function blocks()
  return (view.session or {}).blocks or {}
end

local function current_block()
  return blocks()[view.selected]
end

local function win_valid(win)
  return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function write(buf, lines)
  if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function status()
  if not win_valid(view.tree_win) then
    return
  end
  local counts = (view.session or {}).counts or { open = 0, total = 0 }
  local title = (view.session or {}).title or 'big change'
  vim.wo[view.tree_win].winbar = string.format('%%#NvimeSession#%s · %d of %d open', title, counts.open, counts.total)
  if win_valid(view.pane_win) then
    vim.wo[view.pane_win].winbar = '%#NvimeDim#a answer · r request changes · X re-open · ]t/[t · M merge'
  end
end

local function draw_pane()
  write(view.pane_buf, M.pane_lines(current_block()))
  if win_valid(view.pane_win) then
    pcall(vim.api.nvim_win_set_cursor, view.pane_win, { 1, 0 })
  end
end

local function draw_tree()
  local lines, highlights = M.tree_lines(blocks())
  write(view.tree_buf, lines)
  if view.tree_buf == nil or not vim.api.nvim_buf_is_valid(view.tree_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(view.tree_buf, NS, 0, -1)
  for _, span in ipairs(highlights) do
    vim.api.nvim_buf_set_extmark(view.tree_buf, NS, span.row, 0, {
      end_col = 6,
      hl_group = span.hl,
      strict = false,
    })
  end
end

--- Redraws both panes and the status. Selection is clamped, never dangling.
local function draw()
  view.selected = math.max(1, math.min(view.selected, math.max(#blocks(), 1)))
  draw_tree()
  draw_pane()
  status()
end

--- Follows the cursor in the tree: the pane always shows the thread under it.
local function on_cursor()
  if not win_valid(view.tree_win) or #blocks() == 0 then
    return
  end
  local row = vim.api.nvim_win_get_cursor(view.tree_win)[1]
  if row == view.selected then
    return
  end
  view.selected = row
  draw_pane()
end

--- @param delta integer threads to move by
local function jump(delta)
  local total = #blocks()
  if total == 0 or not win_valid(view.tree_win) then
    return
  end
  local target = math.max(1, math.min(view.selected + delta, total))
  vim.api.nvim_set_current_win(view.tree_win)
  vim.api.nvim_win_set_cursor(view.tree_win, { target, 0 })
  view.selected = target
  draw_pane()
end

--- Adopts a session view the sidecar returned, keeping the reader's place.
--- @param session table
local function adopt(session)
  view.session = session
  if view.on_update ~= nil then
    view.on_update(session)
  end
  draw()
end

local function notify(message, level)
  vim.notify('nvime: ' .. message, level or vim.log.levels.INFO)
end

--- `X`: re-open an auto-resolved thread, or clear it again.
local function toggle()
  local block = current_block()
  if block == nil then
    return
  end
  if block.substantial then
    notify('a substantial thread is cleared by the review gate, not by hand', vim.log.levels.WARN)
    return
  end
  agent.request('big.toggle', {
    root = view.root,
    sessionId = view.session.id,
    blockId = block.id,
    resolved = block.state == 'open',
  }, function(err, result)
    if err ~= nil then
      notify(err.message or 'could not change that thread', vim.log.levels.WARN)
      return
    end
    adopt(result.session)
  end)
end

--- `r`: send this thread's comment back to the build agent and re-triage.
local function request_changes()
  local block = current_block()
  if block == nil then
    return
  end
  require('nvime.compose').open({
    title = ' request changes · ' .. block.title .. ' ',
    hint = '<CR> send (i_<C-s>) · <Esc> cancel',
    on_submit = function(comment)
      notify('revising the worktree — this runs for as long as the change takes')
      agent.request('big.revise', {
        root = view.root,
        sessionId = view.session.id,
        blockId = block.id,
        comment = comment,
      }, function(err, result)
        if err ~= nil then
          notify(err.message or 'the revision failed', vim.log.levels.ERROR)
          return
        end
        M.reload(result.session)
      end)
    end,
  })
end

--- `<CR>`: open the worktree's copy of this thread's first file.
local function open_file()
  local block = current_block()
  local worktree = (view.session or {}).worktree
  if block == nil or worktree == nil then
    return
  end
  local file = (block.files or {})[1]
  if file == nil then
    return
  end
  local path = worktree.path .. '/' .. file
  if vim.fn.filereadable(path) == 0 then
    notify(file .. ' is not in the worktree (it was deleted, or renamed away)', vim.log.levels.WARN)
    return
  end
  vim.cmd('tabedit ' .. vim.fn.fnameescape(path))
end

function M.close()
  local tab = view.tab
  view.tab, view.tree_win, view.pane_win = nil, nil, nil
  -- nvim refuses to close the last tabpage; the buffers below still go, so the
  -- review does not linger as a husk in a session that had only this tab.
  if tab ~= nil and vim.api.nvim_tabpage_is_valid(tab) and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.api.nvim_set_current_tabpage, tab)
    pcall(vim.cmd, 'tabclose')
  end
  for _, buf in ipairs({ view.tree_buf, view.pane_buf }) do
    if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  view.tree_buf, view.pane_buf = nil, nil
end

local KEYS = {
  {
    lhs = ']t',
    fn = function()
      jump(1)
    end,
    desc = 'nvime: next thread',
  },
  {
    lhs = '[t',
    fn = function()
      jump(-1)
    end,
    desc = 'nvime: previous thread',
  },
  { lhs = 'X', fn = toggle, desc = 'nvime: re-open or clear a trivial thread' },
  { lhs = 'r', fn = request_changes, desc = 'nvime: request changes' },
  { lhs = '<CR>', fn = open_file, desc = 'nvime: open this file in the worktree' },
  {
    lhs = 'a',
    fn = function()
      notify('the review gate lands in the next release')
    end,
    desc = 'nvime: answer this thread',
  },
  {
    lhs = 'M',
    fn = function()
      notify('merge is not armed until the review gate ships')
    end,
    desc = 'nvime: merge',
  },
  {
    lhs = 'q',
    fn = function()
      M.close()
    end,
    desc = 'nvime: close the review',
  },
}

local function make_buffer(name, filetype)
  local existing = vim.fn.bufnr('^' .. name .. '$')
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) then
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = filetype
  vim.bo[buf].modifiable = false
  for _, key in ipairs(KEYS) do
    vim.keymap.set('n', key.lhs, key.fn, { buffer = buf, nowait = true, silent = true, desc = key.desc })
  end
  return buf
end

local function build_tab()
  vim.cmd('tabnew')
  view.tab = vim.api.nvim_get_current_tabpage()
  view.tree_buf = make_buffer('nvime://threads', 'nvimethreads')
  view.pane_buf = make_buffer('nvime://threads-diff', 'diff')

  view.tree_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(view.tree_win, view.tree_buf)
  vim.cmd('botright vsplit')
  view.pane_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(view.pane_win, view.pane_buf)
  vim.api.nvim_win_set_width(view.tree_win, TREE_WIDTH)
  for _, win in ipairs({ view.tree_win, view.pane_win }) do
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
  end
  vim.wo[view.tree_win].cursorline = true

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = vim.api.nvim_create_augroup('NvimeThreads', { clear = true }),
    buffer = view.tree_buf,
    desc = 'nvime: show the thread under the cursor',
    callback = on_cursor,
  })
  vim.api.nvim_set_current_win(view.tree_win)
end

--- Re-reads the captured diff for `session` and redraws.
--- @param session table a SessionView
function M.reload(session)
  assert(type(session) == 'table', 'threads.reload needs a session')
  view.session = session
  if view.on_update ~= nil then
    view.on_update(session)
  end
  agent.request('big.diff', { root = view.root, sessionId = session.id }, function(err, result)
    -- Shape-checked, not assumed: a sidecar built from another revision answers
    -- with something else, and that has to read as a named failure rather than
    -- a type error thrown out of a scheduled callback.
    local diff = type(result) == 'table' and result.diff or nil
    if err ~= nil or type(diff) ~= 'table' or type(diff.text) ~= 'string' then
      view.diff_lines, view.hunks = {}, {}
      draw()
      local reason = err ~= nil and (err.message or 'the sidecar refused')
        or 'the sidecar answered big.diff with an unexpected shape — rebuild it'
      notify('could not load the captured diff: ' .. reason, vim.log.levels.WARN)
      return
    end
    view.diff_lines = vim.split(diff.text, '\n', { plain = true })
    view.hunks = {}
    for _, hunk in ipairs(diff.hunks or {}) do
      view.hunks[hunk.id] = hunk
    end
    draw()
  end)
end

--- Opens the review threads for `session` in their own tabpage.
--- @param root string the project root
--- @param session table a SessionView
--- @param on_update fun(session: table)|nil told whenever the session changes
function M.open(root, session, on_update)
  assert(type(root) == 'string', 'threads.open needs a project root')
  assert(type(session) == 'table', 'threads.open needs a session')
  if not session.hasDiff then
    notify('this big change has no captured diff yet', vim.log.levels.WARN)
    return
  end
  M.close()
  view.root = root
  view.on_update = on_update
  view.selected = 1
  build_tab()
  M.reload(session)
end

--- Test hook: the rendered model.
function M.view()
  return view
end

return M
