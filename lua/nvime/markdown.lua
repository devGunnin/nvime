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
--- @field kind 'fence_open'|'fence_close'|'code'|'heading'|'text'|'rule'
--- @field lang string|nil language of the fence this line opens
--- @field spans nvime.Span[]
--- @field conceal nvime.Span[]|nil column pairs rendered as nothing — the
---   markup's own delimiters, so `**x**` reads as `x` without the buffer
---   losing the text a reader might yank
--- @field body_hl string|nil the line's own foreground, applied as a span the
---   inline spans above override — what pins prose to one explicit colour
---   instead of leaving it to whatever happens to paint Normal
--- @field line_hl string|nil a GROUND painted across the whole rendered line,
---   window width included: what gives a code block one continuous background
---   rather than a ragged one stopping at its last character. It sits over any
---   span's foreground, so it is only ever used where there are no spans

--- The language tag a model uses to offer the reader a choice. The panel
--- swallows the block rather than showing its JSON; the sidecar parses it.
M.OPTIONS_LANG = 'nvime-options'

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

--- One inline marker: the pattern that matches marker + content + marker, the
--- group the whole run is painted in, how many bytes each delimiter is, and
--- whether the run must be delimited by whitespace or punctuation (which is
--- what keeps `snake_case_names` from rendering as italics).
local MARKERS = {
  { pattern = '`[^`]+`', hl = 'NvimeInlineCode', marker = 1, boundary = false },
  { pattern = '~~[^~]+~~', hl = 'NvimeDim', marker = 2, boundary = false },
  { pattern = '%*%*[^*]+%*%*', hl = 'NvimeBold', marker = 2, boundary = false },
  { pattern = '__[^_]+__', hl = 'NvimeBold', marker = 2, boundary = true },
  { pattern = '%*[^*]+%*', hl = 'NvimeItalic', marker = 1, boundary = false },
  { pattern = '_[^_]+_', hl = 'NvimeItalic', marker = 1, boundary = true },
}

--- Adds every non-overlapping match of `rule.pattern` as a span, plus the two
--- column pairs covering its delimiters so the panel can render them as
--- nothing.
local function scan_marker(line, rule, taken, spans, conceal)
  local init = 1
  while init <= #line do
    local first, last = line:find(rule.pattern, init)
    if first == nil then
      return
    end
    local ok = not overlaps(taken, first, last)
    if ok and rule.boundary then
      ok = is_boundary(line:sub(first - 1, first - 1)) and is_boundary(line:sub(last + 1, last + 1))
    end
    if ok then
      take(taken, first, last)
      spans[#spans + 1] = { first - 1, last, rule.hl }
      conceal[#conceal + 1] = { first - 1, first - 1 + rule.marker }
      conceal[#conceal + 1] = { last - rule.marker, last }
    end
    init = last + 1
  end
end

--- Inline markdown spans, strongest marker first so `**x**` wins over `*x*`.
--- @return nvime.Span[], nvime.Span[] spans, then the delimiters to conceal
local function inline_spans(line)
  local spans, conceal, taken = {}, {}, {}
  for _, rule in ipairs(MARKERS) do
    scan_marker(line, rule, taken, spans, conceal)
  end
  local by_start = function(a, b)
    return a[1] < b[1]
  end
  table.sort(spans, by_start)
  table.sort(conceal, by_start)
  return spans, conceal
end

--- A CommonMark thematic break: three or more of `-`, `*` or `_`, alone on the
--- line but for spaces. Checked only outside a fence, where it is code.
local function is_thematic_break(line)
  local body = line:match('^%s*(.-)%s*$'):gsub(' ', '')
  if #body < 3 then
    return false
  end
  local first = body:sub(1, 1)
  if first ~= '-' and first ~= '*' and first ~= '_' then
    return false
  end
  return body == string.rep(first, #body)
end

local function fence_marker(line)
  local indent, ticks, rest = line:match('^(%s*)(```+)(.*)$')
  if ticks == nil then
    indent, ticks, rest = line:match('^(%s*)(~~~+)(.*)$')
  end
  if ticks == nil then
    return nil
  end
  return { marker = { #indent, #indent + #ticks }, rest = vim.trim(rest) }
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
    -- The ticks themselves are concealed: the block's own ground already says
    -- where it starts and ends, and the language tag is the only part worth
    -- reading. The line stays, so the block keeps its top and bottom edge.
    local conceal = { fence.marker }
    if state.in_fence then
      state.in_fence = false
      state.fence_lang = nil
      return { kind = 'fence_close', lang = nil, spans = {}, conceal = conceal, line_hl = 'NvimeFence' }
    end
    state.in_fence = true
    state.fence_lang = fence.rest ~= '' and fence.rest:match('^(%S+)') or nil
    return {
      kind = 'fence_open',
      lang = state.fence_lang,
      spans = {},
      conceal = conceal,
      line_hl = 'NvimeFence',
    }
  end

  -- A ground, not a span: it has to reach the window edge so a block reads as
  -- one continuous surface rather than a stripe ending at each line's text.
  if state.in_fence then
    return { kind = 'code', lang = state.fence_lang, spans = {}, line_hl = 'NvimeCode' }
  end

  -- Classified, not rendered: a break is a gap in the conversation, and how
  -- wide a gap looks is the panel's call, not the classifier's.
  if is_thematic_break(line) then
    return { kind = 'rule', lang = nil, spans = {}, body_hl = 'NvimeDim' }
  end

  local hashes = line:match('^(#+)%s')
  if hashes ~= nil and #hashes <= 6 then
    return {
      kind = 'heading',
      lang = nil,
      spans = { { 0, #hashes, 'NvimeDim' }, { #hashes, width, 'NvimeHeading' } },
      conceal = { { 0, #hashes + 1 } },
      body_hl = 'NvimeBody',
    }
  end

  local spans, conceal = inline_spans(line)
  return { kind = 'text', lang = nil, spans = spans, conceal = conceal, body_hl = 'NvimeBody' }
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
