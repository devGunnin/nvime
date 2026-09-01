--- Small text shaping helpers the floating surfaces share.
---
--- All of them count DISPLAY CELLS, not bytes: a title with a box-drawing
--- glyph or a CJK path must not overflow the border it was measured against.
local M = {}

--- @param text string
--- @return integer display cells
local function width_of(text)
  return vim.fn.strdisplaywidth(text)
end

--- `text` at most `width` cells, with a trailing ellipsis when it was cut.
--- @param text string
--- @param width integer
--- @return string
function M.ellipsise(text, width)
  assert(type(text) == 'string', 'ellipsise needs text')
  assert(type(width) == 'number' and width > 0, 'ellipsise needs a positive width')
  if width_of(text) <= width then
    return text
  end
  -- The ellipsis is itself East Asian Ambiguous, so it can cost two cells:
  -- budget for its measured width rather than for one.
  local mark = '…'
  local budget = width - width_of(mark)
  if budget < 1 then
    mark = ''
    budget = width
  end
  -- Cut by characters, not bytes, and re-measure: one character can be two cells.
  local out = ''
  for index = 0, vim.fn.strchars(text) - 1 do
    local candidate = out .. vim.fn.strcharpart(text, index, 1)
    if width_of(candidate) > budget then
      break
    end
    out = candidate
  end
  return out .. mark
end

--- Yields `line` one UTF-8 character at a time by walking byte offsets.
---
--- `vim.fn.strcharpart(text, index, 1)` rescans from byte 0 on every call, so
--- calling it once per character turns an O(n) walk into O(n²) — measured at
--- 8138ms for a 64KiB payload (see the perf test below). Reading the lead
--- byte's high bits gives the sequence length without any such rescan, so
--- this walks the string once, in byte order.
--- @param text string
--- @return fun(): string|nil
local function utf8_chars(text)
  local len = #text
  local pos = 1
  return function()
    if pos > len then
      return nil
    end
    local byte = text:byte(pos)
    local size = 1
    if byte >= 0xF0 then
      size = 4
    elseif byte >= 0xE0 then
      size = 3
    elseif byte >= 0xC0 then
      size = 2
    end
    -- Never read past the end, even on truncated or malformed UTF-8.
    size = math.min(size, len - pos + 1)
    local ch = text:sub(pos, pos + size - 1)
    pos = pos + size
    return ch
  end
end

--- `line` with every tab expanded to spaces at an 8-column stop, so a chunk
--- budgeted in display cells never has one character silently cost up to 8.
--- Tab stops reset at each newline, so this only makes sense per line — the
--- callers below always pass one.
--- @param line string a single line, no embedded newline
--- @return string
local function expand_tabs(line)
  if not line:find('\t', 1, true) then
    return line
  end
  local TABSTOP = 8
  local out, col = {}, 0
  for ch in utf8_chars(line) do
    if ch == '\t' then
      local spaces = TABSTOP - (col % TABSTOP)
      out[#out + 1] = string.rep(' ', spaces)
      col = col + spaces
    else
      out[#out + 1] = ch
      col = col + width_of(ch)
    end
  end
  return table.concat(out)
end

--- `text` cut into pieces that each measure at most `width` display cells.
---
--- Built by accumulating characters and re-measuring the whole candidate
--- string, never by summing per-character widths: display width is not
--- additive across a concatenation (combining marks, wide-char boundaries),
--- so only the accumulated string's own measurement can be trusted. The
--- first character of a chunk is always kept even if it alone exceeds
--- `width` (a CJK character in a 1-cell budget), so every chunk makes
--- progress and the loop always terminates.
--- @param text string
--- @param width integer
--- @return string[]
local function cell_chunks(text, width)
  if text == '' then
    return { '' }
  end
  local out = {}
  local chunk = nil
  for ch in utf8_chars(text) do
    if chunk == nil then
      chunk = ch
    else
      local candidate = chunk .. ch
      if width_of(candidate) > width then
        out[#out + 1] = chunk
        chunk = ch
      else
        chunk = candidate
      end
    end
  end
  out[#out + 1] = chunk
  return out
end

--- `text` broken to `width` cells, its own newlines kept.
---
--- Breaks at spaces where it can; a single token wider than the line is broken
--- by display cells rather than allowed to overflow. Nothing is ever dropped
--- except the space a line was broken at.
--- @param text string
--- @param width integer
--- @return string[]
function M.wrap(text, width)
  assert(type(text) == 'string', 'wrap needs text')
  assert(type(width) == 'number' and width > 0, 'wrap needs a positive width')
  local out = {}
  for _, raw_line in ipairs(vim.split(text, '\n', { plain = true })) do
    local line = expand_tabs(raw_line)
    local current = ''
    for word in line:gmatch('%S+') do
      if current == '' then
        current = word
      elseif width_of(current .. ' ' .. word) <= width then
        current = current .. ' ' .. word
      else
        out[#out + 1] = current
        current = word
      end
      if width_of(current) > width then
        local chunks = cell_chunks(current, width)
        for i = 1, #chunks - 1 do
          out[#out + 1] = chunks[i]
        end
        current = chunks[#chunks]
      end
    end
    out[#out + 1] = current
  end
  return out
end

--- `text` broken to `width` cells with every character preserved. Used where
--- the exact payload is the point (a command awaiting approval), and a word
--- wrap's dropped break-space would be a lie about what runs. A tab is still
--- expanded to spaces — the alternative is trusting whichever buffer's
--- `tabstop` happens to be active when this runs, which the caller does not
--- control.
--- @param text string
--- @param width integer
--- @return string[]
function M.wrap_exact(text, width)
  assert(type(text) == 'string', 'wrap_exact needs text')
  assert(type(width) == 'number' and width > 0, 'wrap_exact needs a positive width')
  local out = {}
  for _, raw_line in ipairs(vim.split(text, '\n', { plain = true })) do
    vim.list_extend(out, cell_chunks(expand_tabs(raw_line), width))
  end
  return out
end

--- `text` with every mention of the user's home directory written as `~`.
--- Applied to whole messages, not just paths — a diagnostic reads
--- "sidecar built: ~/…", never a 60-character absolute path.
--- @param text string
--- @return string
function M.tilde(text)
  assert(type(text) == 'string', 'tilde needs text')
  local home = vim.uv.os_homedir()
  if home == nil or home == '' then
    return text
  end
  return (text:gsub(vim.pesc(home), '~'))
end

return M
