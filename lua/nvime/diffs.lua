--- Line diffs between two versions of a file, and the buffer edits that turn
--- one into the other. Pure: nothing here touches a buffer or the filesystem,
--- so every rule below is testable on strings alone.
local M = {}

--- `vim.diff` moved to `vim.text.diff` in 0.11; nvime supports 0.10 onwards.
local diff = (vim.text ~= nil and vim.text.diff) or vim.diff

--- Splits file text into buffer lines. `eol` records whether the text ended
--- with a newline, which `M.to_text` needs to rebuild the file byte for byte.
--- @param text string
--- @return string[] lines
--- @return boolean eol
function M.to_lines(text)
  assert(type(text) == 'string', 'diffs.to_lines needs text')
  local eol = text:sub(-1) == '\n'
  local lines = vim.split(text, '\n', { plain = true })
  -- A trailing newline yields a trailing empty element that is not a line.
  if eol then
    table.remove(lines)
  end
  return lines, eol
end

--- @param lines string[]
--- @param eol boolean whether the file ends with a newline
--- @return string
function M.to_text(lines, eol)
  assert(type(lines) == 'table', 'diffs.to_text needs lines')
  return table.concat(lines, '\n') .. (eol and '\n' or '')
end

--- Raw hunk indices, each `{ start_a, count_a, start_b, count_b }` with 1-based
--- line numbers. A zero count means an insertion or deletion, and its `start`
--- is then the line it follows — the convention `M.buffer_edit` decodes.
--- @param before string
--- @param after string
--- @return table[]
function M.hunks(before, after)
  assert(type(before) == 'string' and type(after) == 'string', 'diffs.hunks needs two texts')
  return diff(before, after, { result_type = 'indices' }) or {}
end

--- @param path string shown in the header
--- @param before string
--- @param after string
--- @return string a plain unified diff, header included
function M.unified(path, before, after)
  local body = diff(before, after, { result_type = 'unified', ctxlen = 3 }) or ''
  if body == '' then
    return string.format('--- a/%s\n+++ b/%s\n(no textual change)\n', path, path)
  end
  return string.format('--- a/%s\n+++ b/%s\n%s', path, path, body)
end

--- 1-based inclusive line span a hunk guards on the "b" side. A zero-count
--- hunk has no lines of its own, so it guards the line it is anchored to:
--- reverting an insertion point the user has since edited must refuse.
local function guarded_span(b_start, b_count)
  if b_count == 0 then
    return math.max(b_start, 1), math.max(b_start, 1)
  end
  return b_start, b_start + b_count - 1
end

--- The hunk a diff line belongs to, found by the "b" line the walk is at.
--- A `-` line sits between b-1 and b, so a pure deletion is matched one line
--- back from where the counter stands.
local function hunk_at(hunks, b_line, removed)
  for index, hunk in ipairs(hunks) do
    local first, last = guarded_span(hunk[3], hunk[4])
    if hunk[4] == 0 then
      if removed and b_line == first + 1 then
        return index
      end
    elseif b_line >= first and b_line <= last then
      return index
    end
  end
  return nil
end

--- For each line of a unified diff, the index into `hunks` it belongs to, or
--- nil for headers and context lines. Lets the unified view offer the same
--- per-hunk revert as the list view instead of advertising one it cannot do.
---
--- @param unified string as produced by `M.unified`
--- @param hunks table[] from `M.hunks` on the same two texts
--- @return (integer|nil)[] one entry per line of `unified`
function M.unified_rows(unified, hunks)
  assert(type(unified) == 'string' and type(hunks) == 'table', 'diffs.unified_rows needs a diff and hunks')
  local map = {}
  local b_line = nil
  for index, line in ipairs(vim.split(unified, '\n', { plain = true })) do
    local header = line:match('^@@ %-%d+,?%d* %+(%d+)')
    if header ~= nil then
      b_line = tonumber(header)
    elseif b_line == nil then
      map[index] = nil
    elseif line:sub(1, 1) == '+' then
      map[index] = hunk_at(hunks, b_line, false)
      b_line = b_line + 1
    elseif line:sub(1, 1) == '-' then
      map[index] = hunk_at(hunks, b_line, true)
    elseif line:sub(1, 1) == '\\' then
      -- `\ No newline at end of file` is a marker, not a line of either side;
      -- counting it desynced every b-side row after it.
      map[index] = nil
    elseif line ~= '' then
      b_line = b_line + 1
    end
  end
  return map
end

--- The buffer edit one hunk describes: replace rows `[first, last)` (0-based,
--- end-exclusive, the shape `nvim_buf_set_lines` takes) with `lines`.
--- @param hunk table one entry from `M.hunks`
--- @param after_lines string[] the "b" side, whole file
--- @return table { first, last, lines, kind }
function M.buffer_edit(hunk, after_lines)
  local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
  assert(type(start_a) == 'number' and type(count_b) == 'number', 'diffs.buffer_edit needs a hunk')
  -- A zero count anchors on the preceding line, so the insertion point is
  -- `start` itself once converted to a 0-based row.
  local first = count_a == 0 and start_a or (start_a - 1)
  local lines = {}
  for i = start_b, start_b + count_b - 1 do
    lines[#lines + 1] = after_lines[i]
  end
  local kind = 'change'
  if count_a == 0 then
    kind = 'add'
  elseif count_b == 0 then
    kind = 'delete'
  end
  return { first = first, last = first + count_a, lines = lines, kind = kind }
end

--- The mirror of `M.buffer_edit`: put the hunk's "a" lines back over the rows
--- its "b" side occupies. `offset` shifts the rows when the file has drifted
--- since (an earlier revert), and comes from `M.locate`.
--- @param hunk table
--- @param before_lines string[] the "a" side, whole file
--- @param offset integer lines to shift the target rows by
--- @return table { first, last, lines }
function M.reverse_edit(hunk, before_lines, offset)
  local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
  assert(type(start_b) == 'number' and type(count_a) == 'number', 'diffs.reverse_edit needs a hunk')
  local first = (count_b == 0 and start_b or (start_b - 1)) + (offset or 0)
  local lines = {}
  for i = start_a, start_a + count_a - 1 do
    lines[#lines + 1] = before_lines[i]
  end
  return { first = first, last = first + count_b, lines = lines }
end

--- Rows (0-based) a hunk leaves changed in the new buffer, for highlighting.
--- A pure deletion leaves no new line, so it marks the line it happened at.
--- @param hunk table
--- @param line_count integer lines in the buffer after the edit
--- @return integer[] rows
--- @return string kind
function M.changed_rows(hunk, line_count)
  local start_b, count_b = hunk[3], hunk[4]
  local kind = hunk[2] == 0 and 'add' or (count_b == 0 and 'delete' or 'change')
  local rows = {}
  if count_b == 0 then
    local row = math.min(math.max(start_b - 1, 0), math.max(line_count - 1, 0))
    return { row }, kind
  end
  for i = start_b, start_b + count_b - 1 do
    if i >= 1 and i <= line_count then
      rows[#rows + 1] = i - 1
    end
  end
  return rows, kind
end

--- Where a hunk of `after` still sits in `current`, as a line offset to add to
--- its "b" line numbers.
---
--- Returns nil when the user has since hand-edited those very lines: a revert
--- computed against drifted text would write something neither side asked for.
--- @param after string the content the agent produced
--- @param current string the file as it is now
--- @param b_start integer
--- @param b_count integer
--- @return integer|nil offset
--- @return string|nil reason when the hunk can no longer be located
function M.locate(after, current, b_start, b_count)
  if after == current then
    return 0, nil
  end
  local first, last = guarded_span(b_start, b_count)
  local offset = 0
  for _, drift in ipairs(M.hunks(after, current)) do
    local d_start, d_count = drift[1], drift[2]
    local d_first, d_last = guarded_span(d_start, d_count)
    if d_last >= first and d_first <= last then
      return nil, 'those lines have been edited since'
    end
    if d_last < first then
      offset = offset + drift[4] - d_count
    end
  end
  return offset, nil
end

return M
