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
local models = require('nvime.models')
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

--- A review-tab request short enough that an indicator would only flash is
--- never shown one; anything past this is visible until it settles.
local ACTIVITY_DELAY_MS = 300

--- The spinner's own cadence, matching the panel's.
local ACTIVITY_TICK_MS = 90

--- The pane's title always keeps at least this many cells, whatever the
--- streamed detail beside it wants — the floor `status()` cuts the detail to.
local PANE_TITLE_ROOM = 12

--- The one review-tab request in flight, or nil. A rebase or a grading round
--- is a full agent turn — minutes — and a tab that says nothing while one runs
--- is indistinguishable from a wedged one (issue #10).
---
--- Survives `M.close`: the sidecar keeps running a build turn after the tab
--- closes, so the one-at-a-time latch must too — only the timer, which would
--- otherwise tick against dead windows, is paused. `generation` is what keeps
--- a stale callback from touching a LATER request's record: `run_op` captures
--- it when the request goes out, and only clears the indicator, stops the
--- timer, or frees the latch when both that generation AND `session_id` are
--- still current — a reopen onto a DIFFERENT change must not inherit this
--- record just because nothing has replaced it yet (see `current_activity`).
--- @type table|nil { label, detail, request_id, frame, shown, timer, generation, session_id }
local activity = nil

--- Bumped once per request; `activity.generation` pins a callback to the
--- record it started with, so nothing has to compare table identity.
local next_generation = 0

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
--- One rule per line: the LABEL carries the colour, the content is always body.
--- That is the whole separation — grey means "this names something", never
--- "this is more text" — and it is why a verdict no longer reads as an aside
--- while the answer it judges reads as the loudest thing on the pane.
function M.gate_lines(block)
  local rounds = (block or {}).rounds or {}
  if #rounds == 0 then
    return {}, {}
  end
  local cleared = (block or {}).state ~= 'open'
  local lines, marks = { '', 'the gate' }, {}
  local function mark(col, end_col, hl)
    marks[#marks + 1] = { row = #lines - 1, col = col, end_col = end_col, hl = hl }
  end
  --- Tints the whole row's background, under whatever foreground `labelled`
  --- or `mark` paints on top — the same per-speaker surface the conversation
  --- panel uses, extended into the gate.
  local function band(hl)
    marks[#marks + 1] = { row = #lines - 1, hl = hl }
  end
  --- A labelled line: the label in `hl`, everything after it in body.
  local function labelled(indent, label, body, hl)
    lines[#lines + 1] = indent .. label .. body
    mark(0, #indent + #label, hl)
    mark(#indent + #label, #lines[#lines], 'NvimeBody')
  end
  mark(0, #lines[2], 'NvimeDim')

  for index, round in ipairs(rounds) do
    for at, line in ipairs(vim.split(round.answer or '', '\n', { plain = true })) do
      if at == 1 then
        labelled('', SPEAKER, line, 'NvimeUser')
      else
        lines[#lines + 1] = CONTINUE .. line
        mark(0, #lines[#lines], 'NvimeBody')
      end
      band('NvimeUserBody')
    end
    if round.result == nil then
      lines[#lines + 1] = '  ! ' .. (round.ungraded or 'this answer was not graded')
      mark(0, #lines[#lines], 'NvimeError')
      band('NvimeAgentBody')
      lines[#lines + 1] = '  the thread stays open — answer again'
      mark(0, #lines[#lines], 'NvimeDim')
      band('NvimeAgentBody')
    else
      -- Green only for the round that actually cleared the thread; every
      -- other score is a score that was not enough.
      local grade = string.format('%d · ', round.result.grade or 0)
      labelled('  ', grade, round.result.verdict or '', (cleared and index == #rounds) and 'NvimeOk' or 'NvimeWarn')
      band('NvimeAgentBody')
      for _, entry in ipairs({ { 'hint: ', round.result.hint }, { 'next: ', round.result.followup } }) do
        if entry[2] ~= nil and entry[2] ~= '' then
          labelled('  ', entry[1], entry[2], 'NvimeDim')
          band('NvimeAgentBody')
        end
      end
    end
    lines[#lines + 1] = ''
  end
  return lines, marks
end

--- The tinted band one raw diff line earns, or nil for context.
---
--- No header check: `pane_lines` slices `view.diff_lines[offset+1 ..
--- offset+lineCount]` against `readHunk`'s own counters
--- (`agent/src/unidiff.ts`), which never include the `+++`/`---` file
--- header lines — so this can never be handed one. It used to guess at the
--- header shape anyway, which only produced false negatives: a removed Lua
--- comment (`-- foo`) becomes the diff line `--- foo`, the header shape
--- exactly, and lost its tint.
--- @param line string
--- @return string|nil highlight group
function M.hunk_band(line)
  local head = line:sub(1, 1)
  if head == '+' then
    return 'NvimeEditAdd'
  end
  if head == '-' then
    return 'NvimeEditDelete'
  end
  return nil
end

--- The foreground one raw diff line reads in. Without it a context line and an
--- added line are the same white, and the reader has only a faint band to tell
--- what the change actually is; context recedes so the change stands out.
--- @param line string
--- @return string highlight group
function M.hunk_fg(line)
  local head = line:sub(1, 1)
  if head == '+' then
    return 'NvimeAdded'
  end
  if head == '-' then
    return 'NvimeRemoved'
  end
  return 'NvimeDim'
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
    -- `why · ` rather than the old `# `: a hash right above a diff reads as
    -- part of it, and the label says whose note this is.
    local label = 'why · '
    lines = { block.title, label .. block.rationale, '' }
    marks[#marks + 1] = { row = 1, col = 0, end_col = #label, hl = 'NvimeDim' }
    marks[#marks + 1] = { row = 1, col = #label, end_col = #lines[2], hl = 'NvimeBody' }
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
        marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #hunk.note, hl = 'NvimeDim' }
      else
        for at = hunk.offset + 1, hunk.offset + hunk.lineCount do
          local line = view.diff_lines[at] or ''
          lines[#lines + 1] = line
          marks[#marks + 1] = { row = #lines - 1, col = 0, end_col = #line, hl = M.hunk_fg(line) }
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
  return 'a answer · e explain · r changes · X re-open · ]t/[t · M merge · <C-c> give up on a wedged request'
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

--- `activity`, but only when it belongs to the change the tab is showing
--- right now. A record left over from a change the reader has since moved
--- away from (a reopen onto a different session, `<C-r>` then `<C-t>`) is
--- still running on the sidecar, but it must read as idle here: it is not
--- this change's latch, and not this change's spinner.
--- @return table|nil
local function current_activity()
  if activity == nil or activity.session_id ~= (view.session or {}).id then
    return nil
  end
  return activity
end

--- The spinner and label for the request in flight, or nil when the tab is
--- idle (or the request has not yet outlived `ACTIVITY_DELAY_MS`).
--- @return string|nil
function M.activity_line()
  local current = current_activity()
  if current == nil or not current.shown then
    return nil
  end
  local frames = require('nvime.icons').get().spinner
  return frames[(current.frame - 1) % #frames + 1] .. ' ' .. current.label
end

--- The two bars. The gate's count goes on the narrow tree, where it always
--- fits; the change's own name goes on the wide pane, where it does.
---
--- While a request is in flight both bars switch to it: the tree says what is
--- running and the pane carries the last thing the sidecar reported doing,
--- since none of the keys the hint names will do anything until it settles.
local function status()
  if not win_valid(view.tree_win) then
    return
  end
  -- Well inside the border: a bar that exactly fills its window makes nvim
  -- scroll it and show a `<` instead.
  local left = M.activity_line() or M.gate_status(view.session)
  local gate = shape.ellipsise(left, math.max(vim.api.nvim_win_get_width(view.tree_win) - 4, 8))
  vim.wo[view.tree_win].winbar = '%#NvimeBar# ' .. M.escape_winbar(gate) .. ' %=%#NvimeBar# '
  if not win_valid(view.pane_win) then
    return
  end
  local pane_width = vim.api.nvim_win_get_width(view.pane_win)
  local current = current_activity()
  local keys
  if current ~= nil then
    -- The streamed detail is whatever the sidecar sent — unbounded, and often
    -- multi-line (runner stderr, a git error). Collapsed to one line and cut
    -- to fit before it ever reaches the winbar, the same as the left bar
    -- already was; the static keys hint below is short enough it never needed this.
    keys = shape.ellipsise(((current.detail or ''):gsub('%s+', ' ')), math.max(pane_width - PANE_TITLE_ROOM - 4, 8))
  else
    keys = M.keys_hint(view.session)
  end
  local room = pane_width - vim.fn.strdisplaywidth(keys) - 4
  local title = shape.ellipsise((view.session or {}).title or 'big change', math.max(room, PANE_TITLE_ROOM))
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

--- Renders a sidecar refusal as its message, then its detail line if any — the
--- reason a rejected model name (or any other refusal) is legible rather than
--- just "the run failed". Mirrors `big.lua`'s `show_error` for the streamed panel.
--- @param err table
--- @param fallback string shown when the sidecar sent no message at all
local function notify_error(err, fallback)
  notify(err.message or fallback, vim.log.levels.ERROR)
  if err.detail ~= nil and err.detail ~= '' then
    notify(err.detail, vim.log.levels.ERROR)
  end
end

--- Arms `record`'s timer, showing the spinner immediately when `immediate` is
--- true (resuming a request that was already shown before the tab closed) or
--- after `ACTIVITY_DELAY_MS` otherwise.
--- @param record table the activity record the timer belongs to
--- @param immediate boolean
local function arm_timer(record, immediate)
  local timer = vim.uv.new_timer()
  record.timer = timer
  timer:start(immediate and 0 or ACTIVITY_DELAY_MS, ACTIVITY_TICK_MS, function()
    vim.schedule(function()
      -- The record is the authority, not the closure: a request that settled,
      -- or a record whose timer was re-armed, between the tick and this
      -- callback has already moved on from `timer`.
      if activity ~= record or record.timer ~= timer then
        return
      end
      record.shown = true
      record.frame = record.frame + 1
      status()
    end)
  end)
end

--- Starts the indicator for one request. Nothing is drawn for the first
--- `ACTIVITY_DELAY_MS`, so a round trip the reader would not have noticed
--- anyway never flashes a spinner at them.
---
--- Callers only reach this once `refuse_if_busy` (session-scoped, see
--- `current_activity`) has said the tab is free, so a leftover `activity` here
--- can only be a foreign change's record — still running on the sidecar, but
--- not this change's latch to hold. Its timer is paused rather than touched
--- any other way: the record itself is left alone so its own generation check
--- in `run_op` quarantines its eventual answer once nothing points at it.
--- @param label string what is running, in the reader's words
local function begin_activity(label)
  assert(type(label) == 'string' and label ~= '', 'threads.begin_activity needs a label')
  local session_id = (view.session or {}).id
  assert(activity == nil or activity.session_id ~= session_id, 'the review tab runs one request at a time per change')
  if activity ~= nil and activity.timer ~= nil then
    activity.timer:stop()
    activity.timer:close()
  end
  next_generation = next_generation + 1
  activity = {
    label = label,
    detail = nil,
    request_id = nil,
    frame = 0,
    shown = false,
    timer = nil,
    generation = next_generation,
    session_id = session_id,
  }
  arm_timer(activity, false)
end

--- Stops the ticking timer without releasing the latch — a tab close must not
--- drop the record of a request that keeps running on the sidecar. Safe to
--- call when nothing is in flight, or when the timer is already paused.
local function pause_activity()
  if activity == nil or activity.timer == nil then
    return
  end
  activity.timer:stop()
  activity.timer:close()
  activity.timer = nil
end

--- Re-arms a paused activity's timer once the tab (and its windows) come
--- back — showing it immediately when it was already shown before the pause,
--- rather than making the reader wait out the delay a second time.
local function resume_activity()
  if activity == nil or activity.timer ~= nil then
    return
  end
  arm_timer(activity, activity.shown)
end

--- Clears the indicator and stops its timer, unconditionally — whatever is
--- currently live, not necessarily the request that is settling (see
--- `run_op`, which only calls this when the settling request is still the
--- current generation). Safe to call when nothing is in flight.
local function end_activity()
  local live = activity
  activity = nil
  if live == nil then
    return
  end
  if live.timer ~= nil then
    live.timer:stop()
    live.timer:close()
  end
  status()
end

--- Says what is already running, so a second keystroke reads as "not yet"
--- rather than firing a request the sidecar will only refuse as busy. Scoped
--- to the change on screen: a request still running for a change the reader
--- has since left is not this change's latch (see `current_activity`).
--- @return boolean true when the caller must not proceed
local function refuse_if_busy()
  local current = current_activity()
  if current == nil then
    return false
  end
  notify(current.label .. ' — wait for that to finish', vim.log.levels.WARN)
  return true
end

--- `<C-c>`: give up waiting on a wedged request. Nothing tells the sidecar —
--- there is no cancel channel every op can reach (see `answer()`) — so this
--- only frees the local latch. The abandoned request keeps a generation that
--- is no longer current, so if it does answer later it renders its outcome
--- but can never re-arm the latch or touch whatever runs next. Scoped to the
--- change on screen: it must not reach into a foreign change's latch.
local function give_up()
  if current_activity() == nil then
    return
  end
  end_activity()
  notify('gave up waiting — the request may still land', vim.log.levels.WARN)
end

--- Every request the review tab makes, with the indicator around it.
---
--- One at a time per change: the sidecar claims the session for the duration
--- of a turn and would refuse a second one, so the guard belongs here where
--- it can say what is running instead of relaying a `busy`.
---
--- `spec.always_deliver` opts a call site out of quarantine — only safe for a
--- callback that touches nothing but its own float (`explain`, which never
--- reads or writes `view.session`). Every other call site is left quarantined
--- by default: `on_result`/`on_failure` are skipped entirely once the answer
--- is no longer current, so it can never mutate `view.session`, fire
--- `on_update`, or issue another request against a change the reader has left
--- — only its outcome line is rendered.
--- @param spec table label, method, params, and optional no_deadline/on_error/on_failure/always_deliver
--- @param on_result fun(result: table) called only when the request succeeded
local function run_op(spec, on_result)
  assert(type(spec.label) == 'string' and spec.label ~= '', 'threads.run_op needs a label')
  assert(type(spec.method) == 'string' and spec.method ~= '', 'threads.run_op needs a method')
  assert(type(on_result) == 'function', 'threads.run_op needs a result handler')
  if refuse_if_busy() then
    return
  end
  begin_activity(spec.label)
  local generation = activity.generation
  local session_id = activity.session_id
  agent.request(spec.method, spec.params, function(err, result)
    -- Two different questions. `is_same_record`: has nothing later replaced
    -- this record (generation)? If so the request genuinely just finished,
    -- and the latch must be freed regardless of what the tab shows now — an
    -- answered request left un-cleared would read as busy forever the next
    -- time the reader comes back to this same change. `is_current` narrows
    -- that to "and the tab still shows the change this was for": only then
    -- may `on_result`/`on_failure` run, since only then are `view.session`,
    -- `on_update`, and another `big.diff` safe to touch.
    local is_same_record = activity ~= nil and activity.generation == generation
    local is_current = is_same_record and (view.session or {}).id == session_id
    if is_same_record then
      end_activity()
    end
    if not (is_current or spec.always_deliver) then
      local outcome = err ~= nil and (err.message or spec.on_error or 'that request failed')
        or (spec.label .. ' finished')
      notify(
        outcome .. ' — for a change you have since left',
        err ~= nil and vim.log.levels.WARN or vim.log.levels.INFO
      )
      return
    end
    if err ~= nil then
      if spec.on_failure ~= nil then
        spec.on_failure(err)
      else
        notify_error(err, spec.on_error or 'that request failed')
      end
      return
    end
    on_result(result or {})
  end, {
    no_deadline = spec.no_deadline,
    on_sent = function(id)
      -- Nil when the request already settled (a synchronous refusal); the
      -- events it would have matched are gone with it. Guarded by generation
      -- too, though `on_sent` fires synchronously so this is only ever the
      -- record `begin_activity` just created.
      if activity ~= nil and activity.generation == generation then
        activity.request_id = id
      end
    end,
  })
end

--- The sidecar streams a run's progress addressed to the request that started
--- it. Showing the latest line is what makes a multi-minute rebase read as
--- work rather than as a hang.
--- @param name string
--- @param params table
function M.on_agent_event(name, params)
  if activity == nil or params.id == nil or params.id ~= activity.request_id then
    return
  end
  local detail = nil
  if name == 'big.state' then
    detail = params.note or params.state
  elseif name == 'big.tool' then
    detail = params.summary or params.tool
  elseif name == 'big.notice' then
    detail = params.text
  end
  if type(detail) ~= 'string' or detail == '' then
    return
  end
  activity.detail = detail
  status()
end

local subscribed = false

local function subscribe_once()
  if subscribed then
    return
  end
  agent.on_event(M.on_agent_event)
  subscribed = true
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
  run_op({
    label = 'updating the thread',
    method = 'big.toggle',
    on_error = 'could not change that thread',
    params = {
      root = view.root,
      sessionId = view.session.id,
      blockId = block.id,
      resolved = block.state == 'open',
    },
  }, function(result)
    adopt(result.session)
  end)
end

--- `r`: send this thread's comment back to the build agent and re-triage.
local function request_changes()
  local block = current_block()
  if block == nil or refuse_if_busy() then
    return
  end
  require('nvime.compose').open({
    title = ' request changes · ' .. block.title .. ' ',
    hint = 'what should change, and why?',
    on_submit = function(comment)
      notify('revising the change — this runs for as long as it takes')
      local dial = models.dial('big_build')
      local triage_dial = models.dial('big_triage')
      run_op({
        label = 'revising the change',
        method = 'big.revise',
        on_error = 'the revision failed',
        -- A revision re-runs the build agent; it is bounded by <C-c> and by
        -- the sidecar, never by the editor's control deadline.
        no_deadline = true,
        params = {
          root = view.root,
          sessionId = view.session.id,
          blockId = block.id,
          comment = comment,
          model = dial.model,
          effort = dial.effort,
          triageModel = triage_dial.model,
          triageEffort = triage_dial.effort,
        },
      }, function(result)
        M.reload(result.session)
      end)
    end,
  })
end

--- `a`: defend this thread. The box takes typed text only — the whole feature
--- is that you had to think it through, and pasting the diff back is not that.
local function answer()
  local block = current_block()
  if block == nil or refuse_if_busy() then
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
      local dial = models.dial('big_grade')
      run_op({
        label = 'grading your answer',
        method = 'big.answer',
        on_error = 'the grading turn failed',
        -- A grading round is an agent turn with no bound at all, and closing
        -- the answer box only destroys the window — the turn keeps running
        -- and still holds the session lock. `<C-c>` gives up locally (see
        -- `give_up`), but reaches no cancel channel on the sidecar for this.
        no_deadline = true,
        params = {
          root = view.root,
          sessionId = view.session.id,
          answers = { { blockId = block.id, text = text } },
          model = dial.model,
          effort = dial.effort,
        },
      }, function(result)
        adopt(result.session)
        M.report_grade(result.session, block.id)
      end)
    end,
  })
end

--- `e`: post-clear explain. Only when the sidecar will actually answer it — a
--- substantial thread whose defense is still open is refused server-side too,
--- but checked here first so the float is never opened on a refusal.
local function explain()
  local block = current_block()
  if block == nil or refuse_if_busy() then
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
  local dial = models.dial('explain')
  run_op({
    label = 'explaining this thread',
    method = 'big.explain',
    -- Closing the float only destroys the window, not the request — the turn
    -- runs to completion regardless (or until `<C-c>` gives up on it locally),
    -- and other actions refuse with "wait for that to finish" until it does.
    no_deadline = true,
    -- Safe to always deliver: neither branch below touches `view.session`,
    -- so a reader who switched changes while this ran still gets their
    -- answer rather than a generic "finished elsewhere" notice.
    always_deliver = true,
    params = {
      root = view.root,
      sessionId = view.session.id,
      blockId = block.id,
      model = dial.model,
      effort = dial.effort,
    },
    -- The float is already open on this thread, so the refusal belongs in it
    -- rather than in a toast the reader has to look away for.
    on_failure = function(err)
      local text = '! ' .. (err.message or 'could not explain this thread')
      if err.detail ~= nil and err.detail ~= '' then
        text = text .. '\n' .. err.detail
      end
      explain_ui.show(title, text)
    end,
  }, function(result)
    explain_ui.show(title, result.text or '')
  end)
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
  run_op({
    label = 'checking the merge preconditions',
    method = 'big.merge',
    no_deadline = true,
    params = {
      root = view.root,
      sessionId = view.session.id,
      cleanup = config.get().big.cleanup_on_merge,
    },
    on_failure = function(err)
      notify_error(err, 'the merge failed')
      M.reload_current()
    end,
  }, function(result)
    adopt(result.session)
    if not result.merged then
      M.report_refusals(result.refusals or {})
      return
    end
    refresh_after_merge(result.session)
    require('nvime.organization').attest(view.root, result.session.id)
  end)
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
  local dial = models.dial('big_build')
  local triage_dial = models.dial('big_triage')
  run_op({
    label = 'rebasing the build onto the updated base',
    method = 'big.rebase',
    on_error = 'the rebase failed',
    no_deadline = true,
    params = {
      root = view.root,
      sessionId = view.session.id,
      model = dial.model,
      effort = dial.effort,
      triageModel = triage_dial.model,
      triageEffort = triage_dial.effort,
    },
  }, function(result)
    notify('rebased onto the updated base — review what changed, then M merges')
    M.reload(result.session)
  end)
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
  -- The request itself keeps going — a build turn is meant to outlive the
  -- surface watching it — and so does the one-at-a-time latch it holds: only
  -- the timer is paused, so it stops ticking against dead windows without
  -- dropping the record. `M.open` re-adopts it if the tab comes back before
  -- it settles (issue-#10 regression: a reopen used to drop the latch, so a
  -- second request would go out while the sidecar still held the first).
  pause_activity()
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
  { lhs = '<C-c>', fn = give_up, desc = 'nvime: give up waiting on a wedged request' },
  {
    lhs = 'q',
    fn = function()
      M.close()
    end,
    desc = 'nvime: close the review',
  },
}

--- Reclaims a leftover buffer of the same name. The name has no `scheme://`,
--- so it resolves as a real relative path — `buftype == 'nofile'` is what
--- tells nvime's own scratch buffer apart from a real file a user happens to
--- have open under the same name.
local function drop_stale(name)
  local existing = vim.fn.bufnr('^' .. name .. '$')
  if existing ~= -1 and vim.api.nvim_buf_is_valid(existing) and vim.bo[existing].buftype == 'nofile' then
    pcall(vim.api.nvim_buf_delete, existing, { force = true })
  end
end

local function make_buffer(name, filetype)
  drop_stale(name)
  local buf = vim.api.nvim_create_buf(false, true)
  -- The reclaim above now leaves a real file's buffer alone, so the plain
  -- name can still be taken — nvim then refuses the duplicate (E95). Falling
  -- back to the `nvime://` scheme, which can never collide with a real path,
  -- keeps the review opening instead of raising mid-open — but a leftover
  -- fallback buffer from an earlier collision needs the same reclaim, and
  -- the fallback set itself needs the same pcall guard, or a second
  -- collision raises unguarded.
  if not pcall(vim.api.nvim_buf_set_name, buf, name) then
    local fallback = 'nvime://' .. name
    drop_stale(fallback)
    pcall(vim.api.nvim_buf_set_name, buf, fallback)
  end
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
      -- Only the bars are cut to the window width; a full `draw()` would
      -- also re-cut the pane and reset its cursor to the top, throwing the
      -- reader back to line 1 of a hunk they had scrolled into.
      if win_valid(view.tree_win) then
        status()
      end
    end,
  })
  -- `:tabclose` or `:q` on the raw window (bypassing the `q` mapping's own
  -- `M.close`) still hides this buffer, and `bufhidden = 'wipe'` wipes it —
  -- the one signal every teardown path shares. Without this the indicator's
  -- timer keeps ticking a `status()` against dead windows for the rest of
  -- the run; harmless (guarded by `win_valid`) but wasteful.
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = view.tree_buf,
    desc = 'nvime: stop the indicator timer when the review tab is torn down',
    callback = pause_activity,
  })
  vim.api.nvim_set_current_win(view.tree_win)
  -- Every key here is a normal-mode-only mapping (`KEYS`), but the caller can
  -- land here mid-insert — the big panel's prompt is routinely left in insert
  -- after sending, and `tabnew`ing away from it carries that mode along
  -- verbatim. Left alone, a raw `a`/`M` types into the (briefly writable, see
  -- `write`) buffer instead of firing `answer`/`merge` — the exact `aMDEFEND`
  -- corruption a QA pass caught, with no error since nvim considers this a
  -- perfectly normal insert.
  if vim.fn.mode():match('^i') then
    vim.cmd('stopinsert')
  end
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
  subscribe_once()
  view.root = root
  view.on_update = on_update
  view.selected = 1
  build_tab()
  -- Re-adopts a request that was already in flight when the tab last closed
  -- (a plain reopen, or `<C-t>` from the big panel) rather than orphaning it:
  -- the latch survived `M.close`, only its timer was paused. Only for THIS
  -- change, though — reopening onto a DIFFERENT change must not inherit a
  -- leftover latch that belongs to the one the reader left (issue-#10
  -- regression N1): that record is left alone, quarantined by `run_op`'s own
  -- generation/session check once it eventually settles.
  if activity ~= nil and activity.session_id == session.id then
    resume_activity()
  end
  status()
  M.reload(session)
end

--- Test hook: the rendered model.
function M.view()
  return view
end

--- Test hook: the request in flight for the change on screen, or nil — what
--- the reader would actually see, not a leftover record for a change they
--- have since left (see `current_activity`).
function M.activity()
  return current_activity()
end

return M
