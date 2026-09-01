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
  for index, option in ipairs(block.options) do
    -- The box is two display cells whether or not it holds a tick, so the
    -- labels line up either way. Widths in cells, extmark columns in bytes:
    -- the tick is multi-byte and would otherwise throw one of the two off.
    local number = string.format('  %d', index)
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
    local index = tonumber(word)
    if index == nil or index % 1 ~= 0 or block.options[index] == nil or seen[index] then
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
--- second copy of the block below the first.
local function redraw(handle)
  local lines, marks = M.lines(handle.block, handle.chosen)
  handle.surface:rewrite(handle.row, lines, marks)
end

local function toggle(handle, index)
  if handle.chosen[index] then
    handle.chosen[index] = nil
  else
    handle.chosen[index] = true
  end
  redraw(handle)
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
  }

  function handle.detach()
    if handle.spent then
      return
    end
    handle.spent = true
    unbind(handle)
  end

  local function answer(indices)
    if handle.spent or #indices == 0 then
      return
    end
    handle.detach()
    on_answer(M.reply(block, indices))
  end

  local lines, marks = M.lines(block, handle.chosen)
  handle.row = surface:append_marked(lines, marks)
  surface:blank()

  for index = 1, math.min(#block.options, M.DIGIT_KEYS) do
    bind(handle, tostring(index), function()
      if handle.spent then
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
      answer(picked(handle))
    end, 'nvime: send the chosen options')
  end
  if on_other ~= nil then
    bind(handle, 'o', function()
      if handle.spent then
        return
      end
      handle.detach()
      on_other()
    end, 'nvime: answer in your own words instead')
  end
  return handle
end

return M
