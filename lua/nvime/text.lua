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

--- `text` broken to `width` cells, its own newlines kept.
---
--- Breaks at spaces where it can; a single token wider than the line is broken
--- by characters rather than allowed to overflow. Nothing is ever dropped
--- except the space a line was broken at.
--- @param text string
--- @param width integer
--- @return string[]
function M.wrap(text, width)
  assert(type(text) == 'string', 'wrap needs text')
  assert(type(width) == 'number' and width > 0, 'wrap needs a positive width')
  local out = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
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
      while width_of(current) > width do
        out[#out + 1] = vim.fn.strcharpart(current, 0, width)
        current = vim.fn.strcharpart(current, width)
      end
    end
    out[#out + 1] = current
  end
  return out
end

--- `text` broken to `width` cells with every byte preserved, spaces included.
--- Used where the exact payload is the point (a command awaiting approval),
--- and a word wrap's dropped break-space would be a lie about what runs.
--- @param text string
--- @param width integer
--- @return string[]
function M.wrap_exact(text, width)
  assert(type(text) == 'string', 'wrap_exact needs text')
  assert(type(width) == 'number' and width > 0, 'wrap_exact needs a positive width')
  local out = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    local total = vim.fn.strchars(line)
    if total == 0 then
      out[#out + 1] = ''
    end
    local at = 0
    while at < total do
      out[#out + 1] = vim.fn.strcharpart(line, at, width)
      at = at + width
    end
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
