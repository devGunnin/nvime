--- A choice the agent offered, rendered inline in the conversation.
---
--- When the agent's question is a pick between discrete alternatives it sends
--- an options block alongside its prose. This module validates that block (it
--- arrives from a subprocess, so nothing here trusts its shape), lays it out as
--- a numbered list in the transcript, and binds the digits that answer it.
---
--- It is not a modal: the list is scrollback like everything else, the keys are
--- buffer-local to the panel it was written into, and they are released the
--- moment the reader answers. Free text is always still an answer — the reader
--- types it in the prompt as usual, and the block detaches itself.
local icons = require('nvime.icons')

local M = {}

--- Anchors a block's top row against edits elsewhere in the scrollback (a
--- stream's tail line clearing above it, say), the same way `apply.lua`
--- anchors the saved cursor and topline across a live-applied hunk.
local NS = vim.api.nvim_create_namespace('nvime.options')

--- Past this a list stops being something you can read at a glance. A block
--- offering more is refused outright rather than trimmed: the prose question it
--- came with is shown in full either way, and a silently shortened list would
--- hide alternatives the reader was told about.
M.MAX_OPTIONS = 12

--- Options past this cannot have a single-keypress binding. They are still
--- numbered, and still answerable by typing the number into the prompt.
M.DIGIT_KEYS = 9

local function trimmed(value)
  return type(value) == 'string' and vim.trim(value) or ''
end

--- @param raw any an option entry as it arrived
--- @return table|nil { label = string, detail = string|nil }
local function parse_option(raw)
  local source = type(raw) == 'string' and { label = raw } or raw
  if type(source) ~= 'table' then
    return nil
  end
  local label = trimmed(source.label)
  if label == '' then
    return nil
  end
  local detail = trimmed(source.detail)
  return { label = label, detail = detail ~= '' and detail or nil }
end

--- Validates a block decoded from the sidecar. Never throws and never returns
--- a half-built block: an unusable payload is simply not a choice, and the
--- caller falls back to the prose question it came with.
--- @param raw any
--- @return table|nil { prompt, options, multi }
function M.parse(raw)
  if type(raw) ~= 'table' or type(raw.options) ~= 'table' then
    return nil
  end
  local options = {}
  for _, entry in ipairs(raw.options) do
    local option = parse_option(entry)
    if option == nil then
      return nil
    end
    options[#options + 1] = option
  end
  -- One option is not a choice; it is a statement the reader cannot disagree
  -- with, and offering it as a pick would read worse than the prose.
  if #options < 2 or #options > M.MAX_OPTIONS then
    return nil
  end
  local prompt = trimmed(raw.prompt)
  return {
    prompt = prompt ~= '' and prompt or nil,
    options = options,
    multi = raw.multi == true,
  }
end

--- The keys line under the list, in the words of what is actually bound.
--- @param block table a parsed block
--- @return string
function M.hint(block)
  local reachable = math.min(#block.options, M.DIGIT_KEYS)
  local keys = '1-' .. reachable
  local parts = { block.multi and (keys .. ' toggles') or (keys .. ' picks') }
  if #block.options > reachable then
    parts[#parts + 1] = 'type a number for the rest'
  end
  if block.multi then
    parts[#parts + 1] = '<CR> sends'
  end
  -- Honest about the one thing that is easy to miss: these keys answer only
  -- from the block's own rows, and ]o is how a scrolled-away reader gets back.
  parts[#parts + 1] = ']o returns here'
  -- Always offered: a list of alternatives never stops the reader saying
  -- something the agent did not think of.
  parts[#parts + 1] = 'o for something else'
  return table.concat(parts, ' · ')
end

--- The block as scrollback lines plus the spans that colour them.
--- Pure: no buffer, no window, so a spec reads the layout straight out.
--- @param block table a parsed block
--- @param chosen table<integer, boolean>|nil which options are currently picked
--- @return string[], table[] lines, then marks of { row = 1-based, col, end_col, hl }
function M.lines(block, chosen)
  assert(type(block) == 'table' and type(block.options) == 'table', 'options.lines needs a parsed block')
  chosen = chosen or {}
  local tick = icons.get().ok
  local lines, marks = {}, {}
  local function add(text, col, end_col, hl)
    lines[#lines + 1] = text
    marks[#marks + 1] = { row = #lines, col = col, end_col = end_col or #text, hl = hl }
  end

  if block.prompt ~= nil then
    add('  ' .. block.prompt, 0, nil, 'NvimeBody')
  end
  local GAP = '  '
  -- Padded to the widest index in the block, so 10-12 line up under 1-9
  -- rather than pushing their row one cell to the right of everyone else's.
  local width = #tostring(#block.options)
  for index, option in ipairs(block.options) do
    -- The box is two display cells whether or not it holds a tick, so the
    -- labels line up either way. Widths in cells, extmark columns in bytes:
    -- the tick is multi-byte and would otherwise throw one of the two off.
    local number = string.format('  %' .. width .. 'd', index)
    local box = block.multi and (' ' .. (chosen[index] and tick or ' ')) or ''
    local key = number .. box
    local text = key .. GAP .. option.label
    add(text, 0, #key, chosen[index] and 'NvimeSelected' or 'NvimeOptionKey')
    marks[#marks + 1] = { row = #lines, col = #key, end_col = #text, hl = 'NvimeBody' }
    if option.detail ~= nil then
      local indent = string.rep(' ', #number + (block.multi and 2 or 0) + #GAP)
      add(indent .. option.detail, 0, nil, 'NvimeDim')
    end
  end
  add('  ' .. M.hint(block), 0, nil, 'NvimeDim')
  return lines, marks
end

--- The reply a selection sends, as the reader's own words would have read.
--- @param block table a parsed block
--- @param picked integer[] 1-based indices, in the order they were offered
--- @return string
function M.reply(block, picked)
  assert(#picked > 0, 'options.reply needs at least one pick')
  local parts = {}
  for _, index in ipairs(picked) do
    local option = block.options[index]
    assert(option ~= nil, 'options.reply was handed an index the block does not hold')
    parts[#parts + 1] = string.format('%d: %s', index, option.label)
  end
  return table.concat(parts, ', ')
end

--- How a chosen reply reads back in the transcript, as the reader's own turn.
--- @param reply string
--- @return string
function M.echo(reply)
  return icons.get().arrow .. ' ' .. reply
end

--- Reads a typed prompt as a pick, when it is one. A bare number in range (or
--- several, for a multi block) is the option they meant; anything else is their
--- own words and is sent as written.
--- @param block table a parsed block
--- @param text string what they typed
--- @return string|nil the reply to send, or nil when this is not a pick
function M.pick_from_text(block, text)
  assert(type(block) == 'table', 'options.pick_from_text needs a parsed block')
  assert(type(text) == 'string', 'options.pick_from_text needs the typed text')
  local indices, seen = {}, {}
  for word in vim.trim(text):gmatch('[^%s,]+') do
    -- Digits only: `tonumber` alone also takes `0x2`, `2.0`, `1e0` — none of
    -- which is what a reader typing a plain pick looks like.
    local index = word:match('^%d+$') and tonumber(word) or nil
    if index == nil or block.options[index] == nil or seen[index] then
      return nil
    end
    seen[index] = true
    indices[#indices + 1] = index
  end
  if #indices == 0 or (#indices > 1 and not block.multi) then
    return nil
  end
  table.sort(indices)
  return M.reply(block, indices)
end

local function unbind(handle)
  for _, lhs in ipairs(handle.bound) do
    pcall(vim.keymap.del, 'n', lhs, { buffer = handle.buf })
  end
  handle.bound = {}
end

local function bind(handle, lhs, fn, desc)
  vim.keymap.set('n', lhs, fn, { buffer = handle.buf, nowait = true, silent = true, desc = desc })
  handle.bound[#handle.bound + 1] = lhs
end

--- The block's current top row, tracked through any scrollback edits above
--- it since it was written — a plain integer would go stale the moment a
--- stream elsewhere clears or commits a tail line and shifts every row below.
--- @param handle table an attached handle whose block has been rendered
--- @return integer 0-based row
local function current_row(handle)
  local pos = vim.api.nvim_buf_get_extmark_by_id(handle.buf, NS, handle.mark_id, {})
  assert(#pos > 0, 'options: the block anchor was deleted from under a live handle')
  return pos[1]
end

--- Whether the cursor sits somewhere inside the block's own rows. A digit
--- means "pick" only there; everywhere else in the scrollback it is a plain
--- count prefixing a motion, exactly as it is anywhere else in normal mode.
--- @param handle table an attached handle
--- @return boolean
local function cursor_in_block(handle)
  if handle.mark_id == nil then
    -- Not written yet (a stream still owns the tail row): nothing to be on.
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local top = current_row(handle)
  return row >= top and row < top + handle.height
end

--- The picks currently toggled on, in the order the agent offered them.
local function picked(handle)
  local out = {}
  for index = 1, #handle.block.options do
    if handle.chosen[index] then
      out[#out + 1] = index
    end
  end
  return out
end

--- Redraws the list where it already sits, so a toggle does not append a
--- second copy of the block below the first. A toggle can only fire once the
--- block is on screen, but a later turn may have opened a new stream by
--- then — `rewrite` refuses to run while one is open, so this degrades to a
--- no-op redraw (the toggle itself already recorded) rather than raising out
--- of a keypress handler.
local function redraw(handle)
  if handle.spent or handle.surface:is_streaming() then
    return
  end
  local row = current_row(handle)
  local lines, marks = M.lines(handle.block, handle.chosen)
  handle.surface:rewrite(row, lines, marks)
  -- `rewrite` replaces the range in place, so the block's row does not
  -- actually move — but a same-range `nvim_buf_set_lines` drags a right-
  -- gravity mark to the END of the replacement, which is exactly what left
  -- gravity would then get wrong for a later edit ABOVE the block. Pinning
  -- the mark back to the row just written sidesteps relying on either.
  vim.api.nvim_buf_set_extmark(handle.buf, NS, row, 0, { id = handle.mark_id, right_gravity = true })
end

local function toggle(handle, index)
  if handle.chosen[index] then
    handle.chosen[index] = nil
  else
    handle.chosen[index] = true
  end
  redraw(handle)
end

--- Feeds `lhs` back with `v:count` prepended, so a mapping that declines the
--- key (cursor off the block) hands Vim back exactly what was typed — not
--- just this key with any count already consumed by it dropped.
--- @param lhs string
local function fall_through(lhs)
  local count = vim.v.count
  -- 'n' skips this mapping so the fed key is not re-mapped into it; 'i'
  -- queues ahead of the rest of e.g. `3j`, not after it.
  vim.api.nvim_feedkeys((count > 0 and tostring(count) or '') .. lhs, 'ni', false)
end

--- Binds the digit/<CR>/o keys that answer `handle`'s block, once it is
--- actually on screen — split out of `attach` because it is the one piece
--- deferred behind a live stream.
--- @param handle table the handle `attach` built, with `row`/`height` set
--- @param block table the parsed block
--- @param answer fun(indices: integer[])
--- @param on_other fun()|nil
local function bind_keys(handle, block, answer, on_other)
  -- A digit picks only over the block's own rows; elsewhere it falls
  -- through so Vim's own count-then-motion handling takes it from there.
  for index = 1, math.min(#block.options, M.DIGIT_KEYS) do
    local lhs = tostring(index)
    bind(handle, lhs, function()
      if handle.spent or not cursor_in_block(handle) then
        fall_through(lhs)
        return
      end
      if block.multi then
        toggle(handle, index)
      else
        answer({ index })
      end
    end, 'nvime: choose option ' .. index)
  end
  if block.multi then
    bind(handle, '<CR>', function()
      if handle.spent or not cursor_in_block(handle) then
        -- Off the block, <CR> is the ordinary next-line motion — it must
        -- not go silently dead for the life of the offer.
        fall_through('\r')
        return
      end
      answer(picked(handle))
    end, 'nvime: send the chosen options')
  end
  if on_other ~= nil then
    bind(handle, 'o', function()
      if handle.spent then
        return
      end
      if not cursor_in_block(handle) then
        fall_through('o')
        return
      end
      handle.detach()
      on_other()
    end, 'nvime: answer in your own words instead')
  end
end

--- Writes `block` into `surface` and binds the keys that answer it.
---
--- `on_answer(reply)` is called at most once, with the text to send as the
--- reader's own reply; the handle is spent by then and its keys are gone.
--- `on_other()` is called instead when the reader wants to say something else,
--- and the handle is spent then too.
--- @param surface table a live panel handle (not the closed-panel stand-in)
--- @param block table a parsed block
--- @param on_answer fun(reply: string)
--- @param on_other fun()|nil
--- @return table the handle: `detach()` gives the keys back without answering
function M.attach(surface, block, on_answer, on_other)
  assert(type(surface) == 'table' and type(surface.buf) == 'number', 'options.attach needs a live panel')
  assert(type(block) == 'table' and #block.options >= 2, 'options.attach needs a block with choices')
  assert(type(on_answer) == 'function', 'options.attach needs an answer callback')

  local handle = {
    surface = surface,
    buf = surface.buf,
    block = block,
    chosen = {},
    bound = {},
    spent = false,
    row = nil,
    mark_id = nil,
    height = 0,
  }

  function handle.detach()
    if handle.spent then
      return
    end
    handle.spent = true
    unbind(handle)
    if handle.mark_id ~= nil then
      pcall(vim.api.nvim_buf_del_extmark, handle.buf, NS, handle.mark_id)
    end
  end

  --- Moves the cursor onto the block's own rows from wherever it is —
  --- including the prompt buffer. The one way back to a block a reader
  --- scrolled away from, or whose row a mapped digit cannot reach.
  --- @return boolean whether a live block was actually there to jump to
  function handle.jump()
    if handle.spent or handle.mark_id == nil then
      return false
    end
    local win = vim.fn.bufwinid(handle.buf)
    if win == -1 then
      return false
    end
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { current_row(handle) + 1, 0 })
    return true
  end

  local function answer(indices)
    if handle.spent or #indices == 0 then
      return
    end
    handle.detach()
    on_answer(M.reply(block, indices))
  end

  -- Never write into the scrollback while a stream owns its tail row —
  -- `append_marked` asserts this, same as `replace`/`rewrite` — so a caller
  -- that offers again before the stream it is already showing has closed
  -- waits for it, rather than racing the tail or raising out of a request
  -- callback.
  surface:after_stream(function()
    if handle.spent then
      return
    end
    local lines, marks = M.lines(block, handle.chosen)
    handle.row = surface:append_marked(lines, marks)
    -- Right gravity (the default): an edit landing exactly at the block's
    -- row — a later stream's line arriving above it — must push the anchor
    -- down with it, not leave it pointing at the new line instead.
    handle.mark_id = vim.api.nvim_buf_set_extmark(handle.buf, NS, handle.row, 0, {})
    -- +1: covers the blank spacer `blank()` writes below the block, where a
    -- pinned scrollback's cursor lands the instant the block renders.
    handle.height = #lines + 1
    surface:blank()
    bind_keys(handle, block, answer, on_other)
  end)

  return handle
end

return M
