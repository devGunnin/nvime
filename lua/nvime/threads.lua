--- The review threads of a big change: the thread list on the left, the hunks
--- of the selected thread on the right, in their own tabpage.
---
--- Trivia is auto-resolved but never hidden — it sits in the list with an
--- `auto` chip and `X` re-opens it, so the reader always knows everything that
--- changed. A substantial thread is cleared only by the comprehension gate:
--- `a` opens a typed, paste-blocked answer box, the sidecar grades it, and a
--- grade under the session's threshold comes back as a hint and a follow-up
--- the next answer has to address. There is no override, and `M` will not
--- merge while anything is open.
local agent = require('nvime.agent')
local shape = require('nvime.text')

local M = {}

local NS = vim.api.nvim_create_namespace('nvime.threads')
local TREE_WIDTH = 40

--- Chip width, so the badge highlight and the title column agree.
local CHIP_WIDTH = 6

--- The one-column left gutter both review windows are drawn with.
local GUTTER = 1

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

--- The thread list as it is drawn. Titles are cut, never wrapped: a wrapped
--- title would put the row a keystroke acts on out of step with the cursor.
--- @param blocks table[]
--- @param width integer|nil columns the list is drawn in
--- @return string[] lines
--- @return table[] highlights, each { row = 0-based, col, end_col, hl }
function M.tree_lines(blocks, width)
  assert(type(blocks) == 'table', 'threads.tree_lines needs a block list')
  local lines, highlights = {}, {}
  for index, block in ipairs(blocks) do
    local chip = M.chip(block)
    local files = #(block.files or {})
    local suffix = files > 1 and string.format(' (%d files)', files) or ''
    local room = (width or TREE_WIDTH) - CHIP_WIDTH - 1 - #suffix
    local title = width == nil and block.title or shape.ellipsise(block.title, math.max(room, 8))
    lines[#lines + 1] = string.format('%s %s%s', chip.text, title, suffix)
    highlights[#highlights + 1] = { row = index - 1, col = 0, end_col = CHIP_WIDTH, hl = chip.hl }
    if suffix ~= '' then
      local at = #lines[#lines] - #suffix
      highlights[#highlights + 1] = { row = index - 1, col = at, end_col = at + #suffix, hl = 'NvimeDim' }
    end
  end
  if #lines == 0 then
    lines[1] = 'nothing changed in this build.'
    highlights[1] = { row = 0, col = 0, end_col = #lines[1], hl = 'NvimeDim' }
  end
  return lines, highlights
end

--- The question this thread's next answer has to address, or nil.
--- @param block table
--- @return string|nil
function M.followup(block)
  local rounds = (block or {}).rounds or {}
  local last = rounds[#rounds]
  if last == nil or last.result == nil then
    return nil
  end
  local question = last.result.followup
  if question == nil or question == '' then
    return nil
  end
  return question
end

--- The `you · ` prefix, and the indent its continuation lines align under.
--- Cells, not bytes: the separator is multi-byte and a byte-count indent puts
--- the continuation a column off from the text it belongs to.
local SPEAKER = 'you · '
local CONTINUE = string.rep(' ', vim.fn.strdisplaywidth(SPEAKER))

--- The gate's record for one thread: every answer and what came back.
---
--- The speaker is named once per answer, not once per line — a six-line
--- defense used to arrive as six `you ·` labels stacked down the margin.
--- @param block table
--- @return string[] lines
--- @return table[] marks each { row = 0-based within these lines, col, end_col, hl }
function M.gate_lines(block)
  local rounds = (block or {}).rounds or {}
  if #rounds == 0 then
    return {}, {}
  end
  local cleared = (block or {}).state ~= 'open'
  local lines, marks = { '', '── the gate ──' }, {}
  local function mark(col, end_col, hl)
    marks[#marks + 1] = { row = #lines - 1, col = col, end_col = end_col, hl = hl }
  end
  mark(0, #lines[2], 'NvimeDim')

  for index, round in ipairs(rounds) do
    for at, line in ipairs(vim.split(round.answer or '', '\n', { plain = true })) do
      lines[#lines + 1] = (at == 1 and SPEAKER or CONTINUE) .. line
      if at == 1 then
        mark(0, #SPEAKER, 'NvimeUser')
      end
    end
    if round.result == nil then
      lines[#lines + 1] = '  ! ' .. (round.ungraded or 'this answer was not graded')
      mark(0, #lines[#lines], 'NvimeError')
      lines[#lines + 1] = '  the thread stays open — answer again'
      mark(0, #lines[#lines], 'NvimeDim')
    else
      local grade = string.format('  %d', round.result.grade or 0)
      lines[#lines + 1] = string.format('%s · %s', grade, round.result.verdict or '')
      -- Green only for the round that actually cleared the thread; every
      -- other score is a score that was not enough.
      mark(0, #grade, (cleared and index == #rounds) and 'NvimeOk' or 'NvimeWarn')
      mark(#grade, #lines[#lines], 'NvimeDim')
      for _, entry in ipairs({ { 'hint: ', round.result.hint }, { 'next: ', round.result.followup } }) do
        if entry[2] ~= nil and entry[2] ~= '' then
          lines[#lines + 1] = '  ' .. entry[1] .. entry[2]
          mark(0, 2 + #entry[1], 'NvimeDim')
        end
      end
    end
    lines[#lines + 1] = ''
  end
  return lines, marks
end

--- The tinted band one raw diff line earns, or nil for context and headers.
--- A `+++`/`---` header is not a changed line, and colouring it as one is how
--- a diff view ends up with a red banner over every file it shows.
--- @param line string
--- @return string|nil highlight group
function M.hunk_band(line)
  local head, next_char = line:sub(1, 1), line:sub(2, 2)
  if next_char == head then
    return nil
  end
  if head == '+' then
    return 'NvimeEditAdd'
  end
  if head == '-' then
    return 'NvimeEditDelete'
  end
  return nil
end

--- The hunks of one thread, sliced out of the captured diff, then its gate.
--- @param block table
--- @return string[] lines
--- @return table[] marks each { row = 0-based, col, end_col, hl }
function M.pane_lines(block)
  if block == nil then
    return { 'no thread selected.' }, { { row = 0, col = 0, end_col = 19, hl = 'NvimeDim' } }
  end
  local lines = { block.title, '' }
  local marks = { { row = 0, col = 0, end_col = #block.title, hl = 'NvimeHeading' } }
  if block.rationale ~= nil and block.rationale ~= '' then
    lines = { block.title, '# ' .. block.rationale, '' }
    marks[#marks + 1] = { row = 1, col = 0, end_col = #lines[2], hl = 'NvimeDim' }
  end
  local shown_file = nil
  for _, id in ipairs(block.hunkIds or {}) do
    local hunk = view.hunks[id]
    if hunk == nil then
      lines[#lines + 1] = '(hunk ' .. id .. ' is not in the captured diff)'
      marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #lines[#lines], hl = 'NvimeError' }
    else
      if hunk.file ~= shown_file then
        shown_file = hunk.file
        lines[#lines + 1] = '--- ' .. hunk.file
        marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #lines[#lines], hl = 'NvimeFile' }
      end
      if hunk.note ~= nil then
        lines[#lines + 1] = hunk.note
      else
        for at = hunk.offset + 1, hunk.offset + hunk.lineCount do
          local line = view.diff_lines[at] or ''
          lines[#lines + 1] = line
          local band = M.hunk_band(line)
          if band ~= nil then
            marks[#marks + 1] = { row = #lines - 1, hl = band }
          end
        end
      end
      lines[#lines + 1] = ''
    end
  end
  local gate, gate_marks = M.gate_lines(block)
  local offset = #lines
  vim.list_extend(lines, gate)
  for _, mark in ipairs(gate_marks) do
    marks[#marks + 1] = { row = mark.row + offset, col = mark.col, end_col = mark.end_col, hl = mark.hl }
  end
  return lines, marks
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

--- A winbar evaluates `%{expr}` as vimscript on every redraw, and a session
--- title is the user's own prompt text — often pasted from an issue.
--- @param text string
--- @return string
function M.escape_winbar(text)
  return (tostring(text):gsub('%%', '%%%%'))
end

--- The gate line: what is left before `M` will do anything.
--- @param session table
--- @return string
function M.gate_status(session)
  local counts = (session or {}).counts or { open = 0, total = 0, substantial = 0, defended = 0 }
  if (session or {}).display == 'merged' then
    local merge = (session or {}).merge or {}
    return string.format('merged into %s as %s', merge.baseBranch or '?', (merge.commit or '?'):sub(1, 8))
  end
  local defended = string.format('%d/%d defended', counts.defended or 0, counts.substantial or 0)
  if (counts.open or 0) > 0 then
    return string.format('%s · %d open · merge locked', defended, counts.open)
  end
  return string.format('%s · M merges into your branch', defended)
end

--- What the reader can press, given where the review is. A landed change
--- offers none of the review keys — they would all refuse.
--- @param session table|nil
--- @return string
function M.keys_hint(session)
  if (session or {}).display == 'merged' then
    return '<CR> open a file · q close'
  end
  -- `R rebase` is deliberately absent: it only applies once the base has
  -- moved, and the merge refusal names it at exactly that moment.
  return 'a answer · e explain · r changes · X re-open · ]t/[t · M merge'
end

local function paint(buf, marks)
  if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for _, mark in ipairs(marks or {}) do
    -- No column pair means the whole rendered line, window width included —
    -- what makes a diff band a band rather than a ragged stripe.
    vim.api.nvim_buf_set_extmark(buf, NS, mark.row, mark.col or 0, {
      end_col = mark.col ~= nil and mark.end_col or nil,
      hl_group = mark.col ~= nil and mark.hl or nil,
      line_hl_group = mark.col == nil and mark.hl or nil,
      priority = mark.col == nil and 90 or nil,
      strict = false,
    })
  end
end

--- The two bars. The gate's count goes on the narrow tree, where it always
--- fits; the change's own name goes on the wide pane, where it does.
local function status()
  if not win_valid(view.tree_win) then
    return
  end
  -- Less the bar's own leading and trailing space, and one more: a bar that
  -- exactly fills its window makes nvim scroll it and show a `<` instead.
  local gate = shape.ellipsise(M.gate_status(view.session), vim.api.nvim_win_get_width(view.tree_win) - 3)
  vim.wo[view.tree_win].winbar = '%#NvimeBar# ' .. M.escape_winbar(gate) .. ' %=%#NvimeBar# '
  if not win_valid(view.pane_win) then
    return
  end
  local keys = M.keys_hint(view.session)
  local room = vim.api.nvim_win_get_width(view.pane_win) - vim.fn.strdisplaywidth(keys) - 3
  local title = shape.ellipsise((view.session or {}).title or 'big change', math.max(room, 12))
  vim.wo[view.pane_win].winbar = '%#NvimeBar# '
    .. M.escape_winbar(title)
    .. ' %=%#NvimeBarDim#'
    .. M.escape_winbar(keys)
    .. ' '
end

local function draw_pane()
  local lines, marks = M.pane_lines(current_block())
  write(view.pane_buf, lines)
  paint(view.pane_buf, marks)
  if win_valid(view.pane_win) then
    pcall(vim.api.nvim_win_set_cursor, view.pane_win, { 1, 0 })
  end
end

local function draw_tree()
  -- Less the one-column gutter: a row that fills the window exactly still
  -- wraps, and a wrapped row puts the cursor out of step with its thread.
  local width = win_valid(view.tree_win) and vim.api.nvim_win_get_width(view.tree_win) or TREE_WIDTH
  local lines, highlights = M.tree_lines(blocks(), width - GUTTER)
  write(view.tree_buf, lines)
  paint(view.tree_buf, highlights)
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
    hint = 'what should change, and why?',
    on_submit = function(comment)
      notify('revising the change — this runs for as long as it takes')
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
      end, {
        -- A revision re-runs the build agent; it is bounded by <C-c> and by
        -- the sidecar, never by the editor's control deadline.
        no_deadline = true,
      })
    end,
  })
end

--- `a`: defend this thread. The box takes typed text only — the whole feature
--- is that you had to think it through, and pasting the diff back is not that.
local function answer()
  local block = current_block()
  if block == nil then
    return
  end
  if not block.substantial then
    notify('trivia needs no defense — X re-opens it if you disagree with the triage')
    return
  end
  if block.state ~= 'open' then
    notify('this thread is already cleared')
    return
  end
  local followup = M.followup(block)
  require('nvime.compose').open({
    title = ' defend · ' .. block.title .. ' ',
    hint = followup ~= nil and ('follow-up: ' .. followup) or 'what does this change do, and why?',
    no_paste = true,
    height = 10,
    on_submit = function(text)
      notify('grading your answer')
      agent.request('big.answer', {
        root = view.root,
        sessionId = view.session.id,
        answers = { { blockId = block.id, text = text } },
      }, function(err, result)
        if err ~= nil then
          notify(err.message or 'the grading turn failed', vim.log.levels.ERROR)
          return
        end
        adopt(result.session)
        M.report_grade(result.session, block.id)
      end, {
        -- A grading round is an agent turn with no bound at all: its request
        -- id is never stored where `big.cancel` can see it, and closing the
        -- answer box only destroys the window — the turn keeps running and
        -- still holds the session lock. There is no <C-c> for this one.
        no_deadline = true,
      })
    end,
  })
end

--- `e`: post-clear explain. Only when the sidecar will actually answer it — a
--- substantial thread whose defense is still open is refused server-side too,
--- but checked here first so the float is never opened on a refusal.
local function explain()
  local block = current_block()
  if block == nil then
    return
  end
  if block.substantial and block.state == 'open' then
    notify(
      'this thread is still open — clear it first; explaining now would hand over the answer',
      vim.log.levels.WARN
    )
    return
  end
  local title = block.title
  local explain_ui = require('nvime.explain')
  explain_ui.pending(title)
  agent.request('big.explain', {
    root = view.root,
    sessionId = view.session.id,
    blockId = block.id,
  }, function(err, result)
    if err ~= nil then
      explain_ui.show(title, '! ' .. (err.message or 'could not explain this thread'))
      return
    end
    explain_ui.show(title, (result or {}).text or '')
  end, {
    -- An agent turn with no cancel: closing the float only destroys the
    -- window, not the request — the turn runs to completion regardless, and
    -- other actions refuse with "already running" until it does.
    no_deadline = true,
  })
end

--- Says what the newest round on `block_id` earned. Read off the session the
--- sidecar returned, never off what this side hoped would happen.
--- @param session table
--- @param block_id string
function M.report_grade(session, block_id)
  local block = nil
  for _, candidate in ipairs((session or {}).blocks or {}) do
    if candidate.id == block_id then
      block = candidate
    end
  end
  if block == nil then
    return
  end
  local rounds = block.rounds or {}
  local last = rounds[#rounds]
  if last == nil then
    notify('nothing came back for that thread — it stays open', vim.log.levels.WARN)
    return
  end
  if last.result == nil then
    notify(last.ungraded or 'that answer was not graded — the thread stays open', vim.log.levels.WARN)
    return
  end
  -- Clipped to one line: a grader's verdict runs to several sentences, and a
  -- multi-line `vim.notify` stops the editor on a hit-enter prompt. The whole
  -- text is in the thread's gate record either way.
  local room = math.max(vim.o.columns - 24, 24)
  if block.state == 'resolved' then
    notify(
      string.format('cleared (%d) — %s', last.result.grade or 0, shape.ellipsise(last.result.verdict or '', room))
    )
    return
  end
  notify(
    string.format('%d, not enough — %s', last.result.grade or 0, shape.ellipsise(last.result.hint or '', room)),
    vim.log.levels.WARN
  )
end

--- Brings buffers under the project root up to date with what just landed.
--- Uses P2's conflict-aware path: a buffer with unsaved edits is named, never
--- overwritten.
local function refresh_after_merge(session)
  local ok, apply = pcall(require, 'nvime.apply')
  if not ok then
    return
  end
  local reloaded, left = apply.recheck(view.root, { run_id = 'big-merge-' .. session.id })
  if #left == 0 then
    notify(string.format('merged · %d buffer(s) refreshed', #reloaded))
    return
  end
  notify(
    string.format('merged · %d buffer(s) refreshed, %d left alone: %s', #reloaded, #left, left[1].reason),
    vim.log.levels.WARN
  )
end

--- `M`: land the reviewed change on the branch it was built from.
---
--- The sidecar decides. This side never predicts the answer — it asks, and
--- renders whatever comes back, refusals included.
local function merge()
  if view.session == nil then
    return
  end
  local config = require('nvime.config')
  notify('checking the merge preconditions')
  agent.request('big.merge', {
    root = view.root,
    sessionId = view.session.id,
    cleanup = config.get().big.cleanup_on_merge,
  }, function(err, result)
    if err ~= nil then
      notify(err.message or 'the merge failed', vim.log.levels.ERROR)
      if err.detail ~= nil and err.detail ~= '' then
        notify(err.detail, vim.log.levels.ERROR)
      end
      M.reload_current()
      return
    end
    adopt(result.session)
    if not result.merged then
      M.report_refusals(result.refusals or {})
      return
    end
    refresh_after_merge(result.session)
  end, { no_deadline = true })
end

--- Renders why the merge would not run, and what to do about it.
--- @param refusals table[] each { code, message }
function M.report_refusals(refusals)
  if #refusals == 0 then
    notify('the merge was refused without a reason — this is a bug', vim.log.levels.ERROR)
    return
  end
  local moved = false
  local parts = {}
  for _, refusal in ipairs(refusals) do
    parts[#parts + 1] = refusal.message
    if refusal.code == 'base-moved' then
      moved = true
    end
  end
  if moved then
    parts[#parts + 1] = 'press R to rebase the build onto it and review what changed'
  end
  notify('not merging — ' .. table.concat(parts, '; '), vim.log.levels.WARN)
end

--- `R`: move the build onto a base branch that has advanced, then re-review.
local function rebase()
  if view.session == nil then
    return
  end
  notify('rebasing the build onto the updated base — this runs for as long as it takes')
  agent.request('big.rebase', { root = view.root, sessionId = view.session.id }, function(err, result)
    if err ~= nil then
      notify(err.message or 'the rebase failed', vim.log.levels.ERROR)
      return
    end
    M.reload(result.session)
  end, { no_deadline = true })
end

--- Re-reads the session the sidecar holds, without assuming what changed.
function M.reload_current()
  if view.session == nil then
    return
  end
  agent.request('big.open', { root = view.root, sessionId = view.session.id }, function(err, result)
    if err == nil then
      adopt(result.session)
    end
  end)
end

--- `<CR>`: open the build clone's copy of this thread's first file.
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
    notify(file .. ' is not in the build clone (it was deleted, or renamed away)', vim.log.levels.WARN)
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
  { lhs = '<CR>', fn = open_file, desc = 'nvime: open this file in the build clone' },
  { lhs = 'a', fn = answer, desc = 'nvime: answer this thread' },
  { lhs = 'e', fn = explain, desc = 'nvime: explain this thread' },
  { lhs = 'R', fn = rebase, desc = 'nvime: rebase onto the moved base' },
  { lhs = 'M', fn = merge, desc = 'nvime: merge' },
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
  -- Plain names, no `scheme://`: this pair is the whole tabpage, and the
  -- default tabline renders their name as the tab's label.
  view.tree_buf = make_buffer('nvime-review', 'nvimethreads')
  view.pane_buf = make_buffer('nvime-review-diff', 'diff')

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
    vim.wo[win].statuscolumn = string.rep(' ', GUTTER)
    vim.wo[win].fillchars = 'eob: '
    vim.wo[win].winhighlight = 'CursorLine:NvimeCursorLine'
  end
  -- The list is one row per thread, cut to fit; the pane is prose and diff.
  vim.wo[view.tree_win].wrap = false
  vim.wo[view.pane_win].wrap = true
  vim.wo[view.pane_win].linebreak = true
  vim.wo[view.pane_win].breakindent = true
  vim.wo[view.pane_win].breakindentopt = 'shift:2'
  vim.wo[view.tree_win].cursorline = true

  local group = vim.api.nvim_create_augroup('NvimeThreads', { clear = true })
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = view.tree_buf,
    desc = 'nvime: show the thread under the cursor',
    callback = on_cursor,
  })
  -- Both bars are cut to the window they sit in, so a resize has to re-cut
  -- them; otherwise a widened pane keeps an ellipsis it no longer needs.
  vim.api.nvim_create_autocmd('WinResized', {
    group = group,
    desc = 'nvime: refit the review bars to the new widths',
    callback = function()
      if win_valid(view.tree_win) then
        draw()
      end
    end,
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
