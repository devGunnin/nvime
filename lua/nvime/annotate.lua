--- Where one unified-diff hunk lands in the POST-change file, and what it
--- marks there.
---
--- Pure: nothing here touches a buffer, a window or the filesystem, so every
--- rule below is testable on strings. The review pane feeds the result to
--- extmarks, which is what lets the buffer keep the file's real bytes —
--- treesitter and the LSP see the file, not a rendering of it.
local M = {}

--- Bands, by what the change actually is. Reused from the live-edit tier so a
--- reviewer learns one diff colour, not two.
local ADD = 'NvimeEditAdd'
local CHANGE = 'NvimeEditChange'

--- What a removed line is prefixed with in the virtual line standing in for it.
M.REMOVED_PREFIX = '- '

local HEADER = '^@@ %-%d+,?%d* %+(%d+),?%d* @@'

--- The new-side start line of a hunk header (1-based), or nil when `header` is
--- not a hunk header at all.
--- @param header string
--- @return integer|nil
function M.new_start(header)
  if type(header) ~= 'string' then
    return nil
  end
  local start = header:match(HEADER)
  if start == nil then
    return nil
  end
  return tonumber(start)
end

--- The marks one hunk puts on the post-change file.
---
--- Removed lines have no row of their own — they are gone from the file — so
--- they attach to the row that took their place (the first line of the `+` run
--- that replaced them, or the context line that follows a pure deletion) and
--- render above it as virtual lines.
--- @param header string the `@@` line
--- @param body string[] the hunk body, each line keeping its ` `/`+`/`-` prefix
--- @return table|nil { row, bands = {{row, hl}}, removals = {{row, lines}} }, nil for a non-header
function M.hunk_marks(header, body)
  local start = M.new_start(header)
  if start == nil then
    return nil
  end
  assert(type(body) == 'table', 'annotate.hunk_marks needs a body list')
  local row = start - 1
  local bands, removals = {}, {}
  local first = nil
  --- Texts of the `-` run being read, nil outside one.
  local removed = nil
  --- The `+` run being read replaces a `-` run, so it is a change, not an add.
  local changing = false
  local function flush(at)
    if removed == nil then
      return
    end
    removals[#removals + 1] = { row = at, lines = removed }
    first = first or at
    removed = nil
  end
  for _, line in ipairs(body) do
    local kind = line:sub(1, 1)
    -- `\` is "\ No newline at end of file", which belongs to neither side's
    -- line count and so moves nothing.
    if kind == '-' then
      removed = removed or {}
      removed[#removed + 1] = line:sub(2)
      changing = false
    elseif kind == '+' then
      if removed ~= nil then
        flush(row)
        changing = true
      end
      bands[#bands + 1] = { row = row, hl = changing and CHANGE or ADD }
      first = first or row
      row = row + 1
    elseif kind ~= '\\' then
      flush(row)
      changing = false
      row = row + 1
    end
  end
  flush(row)
  return { row = first or (start - 1), bands = bands, removals = removals }
end

--- One rendered line as `virt_lines` chunks: each mark colours its own byte
--- span, everything between them reads in `fill`.
---
--- Marks may arrive unsorted and a mark without a `col` is a whole-line band,
--- which a virtual line cannot paint — it becomes the fill instead, which is
--- the closest a virt_line gets to a row background.
--- @param line string
--- @param marks table[]|nil each { col, end_col, hl }; no col means the fill
--- @param fill string|nil highlight for the uncovered spans
--- @return table[] chunks, each { text, hl }
function M.chunks(line, marks, fill)
  assert(type(line) == 'string', 'annotate.chunks needs a line')
  local spans = {}
  for _, mark in ipairs(marks or {}) do
    if mark.col == nil then
      fill = mark.hl or fill
    elseif mark.end_col ~= nil and mark.end_col > mark.col then
      spans[#spans + 1] = mark
    end
  end
  table.sort(spans, function(a, b)
    return a.col < b.col
  end)
  local chunks = {}
  local at = 0
  local function emit(text, hl)
    if text ~= '' then
      chunks[#chunks + 1] = { text, hl }
    end
  end
  for _, span in ipairs(spans) do
    -- Overlapping marks would otherwise emit the same bytes twice and shift
    -- the rest of the line right; the earlier mark wins its span.
    local from = math.max(span.col, at)
    local to = math.min(span.end_col, #line)
    if to > from then
      emit(line:sub(at + 1, from), fill)
      emit(line:sub(from + 1, to), span.hl)
      at = to
    end
  end
  emit(line:sub(at + 1), fill)
  return chunks
end

--- `lines` and their marks as one `virt_lines` block.
--- @param lines string[]
--- @param marks table[] each { row = 0-based into `lines`, col, end_col, hl }
--- @param fill string|nil highlight for spans no mark covers
--- @return table[] one chunk list per line
function M.virt_lines(lines, marks, fill)
  assert(type(lines) == 'table', 'annotate.virt_lines needs a line list')
  local by_row = {}
  for _, mark in ipairs(marks or {}) do
    by_row[mark.row] = by_row[mark.row] or {}
    table.insert(by_row[mark.row], mark)
  end
  local out = {}
  for index, line in ipairs(lines) do
    out[index] = M.chunks(line, by_row[index - 1], fill)
  end
  return out
end

return M
