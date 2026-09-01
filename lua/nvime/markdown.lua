--- Streaming markdown classifier.
---
--- Pure: it takes one line plus the carry-over state and returns how that line
--- should be highlighted. The panel owns buffers and extmarks; keeping the
--- classification free of both is what makes it testable and what lets the
--- renderer redraw only the volatile tail line as deltas arrive.
local M = {}

--- Column pairs are 0-based and end-exclusive, matching the extmark API.
--- @class nvime.Span
--- @field [1] integer start column
--- @field [2] integer end column
--- @field [3] string highlight group

--- @class nvime.LineInfo
--- @field kind 'fence_open'|'fence_close'|'code'|'heading'|'text'
--- @field lang string|nil language of the fence this line opens
--- @field spans nvime.Span[]
--- @field line_hl string|nil group painted across the whole rendered line —
---   what gives a code block one continuous background rather than a ragged
---   one that stops at the last character of each line

function M.new_state()
  return { in_fence = false, fence_lang = nil }
end

local function is_boundary(char)
  return char == nil or char == '' or char:match('[%s%p]') ~= nil
end

local function overlaps(taken, first, last)
  for i = first, last do
    if taken[i] then
      return true
    end
  end
  return false
end

local function take(taken, first, last)
  for i = first, last do
    taken[i] = true
  end
end

--- Adds every non-overlapping match of `pattern` as a span of `hl`.
--- `boundary` requires the match to be delimited by whitespace or punctuation,
--- which is what keeps `snake_case_names` from rendering as italics.
local function scan_pairs(line, pattern, hl, taken, spans, boundary)
  local init = 1
  while init <= #line do
    local first, last = line:find(pattern, init)
    if first == nil then
      return
    end
    local ok = not overlaps(taken, first, last)
    if ok and boundary then
      ok = is_boundary(line:sub(first - 1, first - 1)) and is_boundary(line:sub(last + 1, last + 1))
    end
    if ok then
      take(taken, first, last)
      spans[#spans + 1] = { first - 1, last, hl }
    end
    init = last + 1
  end
end

--- Inline markdown spans, strongest marker first so `**x**` wins over `*x*`.
local function inline_spans(line)
  local spans, taken = {}, {}
  scan_pairs(line, '`[^`]+`', 'NvimeInlineCode', taken, spans, false)
  scan_pairs(line, '%*%*[^*]+%*%*', 'NvimeBold', taken, spans, false)
  scan_pairs(line, '__[^_]+__', 'NvimeBold', taken, spans, true)
  scan_pairs(line, '%*[^*]+%*', 'NvimeItalic', taken, spans, false)
  scan_pairs(line, '_[^_]+_', 'NvimeItalic', taken, spans, true)
  table.sort(spans, function(a, b)
    return a[1] < b[1]
  end)
  return spans
end

local function fence_marker(line)
  local indent, ticks, rest = line:match('^(%s*)(```+)(.*)$')
  if ticks == nil then
    indent, ticks, rest = line:match('^(%s*)(~~~+)(.*)$')
  end
  if ticks == nil then
    return nil
  end
  return { indent = indent, rest = vim.trim(rest) }
end

--- Classifies one line against the carried fence state.
--- @param line string
--- @param state table from `new_state`, mutated in place
--- @return nvime.LineInfo
function M.scan(line, state)
  assert(type(line) == 'string', 'markdown.scan needs a line string')
  assert(type(state) == 'table', 'markdown.scan needs a state table')
  local width = #line

  local fence = fence_marker(line)
  if fence ~= nil then
    if state.in_fence then
      state.in_fence = false
      state.fence_lang = nil
      return { kind = 'fence_close', lang = nil, spans = {}, line_hl = 'NvimeFence' }
    end
    state.in_fence = true
    state.fence_lang = fence.rest ~= '' and fence.rest:match('^(%S+)') or nil
    return { kind = 'fence_open', lang = state.fence_lang, spans = {}, line_hl = 'NvimeFence' }
  end

  if state.in_fence then
    -- No span: the line highlight carries the block's colour, and whatever the
    -- fence's own grammar paints on top of it keeps its foreground.
    return { kind = 'code', lang = state.fence_lang, spans = {}, line_hl = 'NvimeCode' }
  end

  local hashes = line:match('^(#+)%s')
  if hashes ~= nil and #hashes <= 6 then
    return {
      kind = 'heading',
      lang = nil,
      spans = { { 0, #hashes, 'NvimeDim' }, { #hashes, width, 'NvimeHeading' } },
    }
  end

  return { kind = 'text', lang = nil, spans = inline_spans(line) }
end

--- Convenience for tests and one-shot rendering of a finished message.
--- @param text string
--- @return nvime.LineInfo[]
function M.render(text)
  assert(type(text) == 'string', 'markdown.render needs a string')
  local state = M.new_state()
  local infos = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    infos[#infos + 1] = M.scan(line, state)
  end
  return infos
end

return M
