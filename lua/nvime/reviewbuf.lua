--- The review pane's real-file buffers.
---
--- The pane shows the build clone's own copy of a changed file as a NORMAL
--- file buffer: a real path, so the filetype, treesitter and the reader's own
--- LSP attach exactly as they would for a file they opened themselves. The
--- diff is extmarks laid over it — bands on the changed rows, virtual lines
--- where something was removed — never text, so the buffer's bytes stay the
--- file's and nothing downstream is reading a rendering.
---
--- Buffers are read-only: the clone is a sandbox the reviewer reads, and a
--- stray keystroke must not edit it.
local annotate = require('nvime.annotate')

local M = {}

M.NS = vim.api.nvim_create_namespace('nvime.reviewfile')

--- Whole-line bands sit under any foreground the colorscheme paints.
local BAND_PRIORITY = 90

--- What this review opened, by path: { buf, adopted }. `adopted` means the
--- reader already had that file open, so the buffer is theirs — it is neither
--- locked nor wiped, only lent the review's marks and keys for the duration.
local opened = {}

--- The clone's copy of `path`, loaded and keyed for the review.
--- @param path string absolute, inside the build clone
--- @param keys table[] the review's buffer-local keys, each { lhs, fn, desc }
--- @return integer|nil buffer
--- @return string|nil why it could not be opened
function M.open(path, keys)
  assert(type(path) == 'string' and path ~= '', 'reviewbuf.open needs a path')
  assert(type(keys) == 'table', 'reviewbuf.open needs the review key table')
  local known = opened[path]
  if known ~= nil and vim.api.nvim_buf_is_valid(known.buf) then
    return known.buf
  end
  local buf = vim.fn.bufadd(path)
  if buf == 0 then
    return nil, 'neovim would not open ' .. path
  end
  local adopted = vim.api.nvim_buf_is_loaded(buf)
  -- Reading a file runs the reader's own autocmds; one that raises must
  -- degrade the pane with a reason, not throw out of a redraw.
  local ok, err = pcall(vim.fn.bufload, buf)
  if not ok then
    return nil, tostring(err)
  end
  if not vim.api.nvim_buf_is_loaded(buf) then
    return nil, 'could not read ' .. path
  end
  if not adopted then
    vim.bo[buf].buflisted = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
  end
  for _, key in ipairs(keys) do
    vim.keymap.set('n', key.lhs, key.fn, { buffer = buf, nowait = true, silent = true, desc = key.desc })
  end
  opened[path] = { buf = buf, adopted = adopted }
  return buf
end

--- One removed line per virtual line: the marker carries the diff colour, the
--- text itself stays dim — it is not in the file any more.
--- @param lines string[]
--- @return table[] one chunk list per line
local function removed_chunks(lines)
  local out = {}
  for index, text in ipairs(lines) do
    local chunks = { { annotate.REMOVED_PREFIX, 'NvimeRemoved' } }
    if text ~= '' then
      chunks[#chunks + 1] = { text, 'NvimeDim' }
    end
    out[index] = chunks
  end
  return out
end

--- Hangs `virt` off `row`, above it when there is such a row — a deletion past
--- the last line has nothing to sit above, so it goes below the last one.
local function set_virt(buf, row, virt, count)
  local above = row < count
  vim.api.nvim_buf_set_extmark(buf, M.NS, above and row or count - 1, 0, {
    virt_lines = virt,
    virt_lines_above = above,
    strict = false,
  })
end

--- Lays one thread's annotations over `buf`, replacing whatever was there.
--- @param buf integer
--- @param spec table { bands = {{row, hl}}, removals = {{row, lines}}, overlay = { row, lines, marks }|nil }
function M.paint(buf, spec)
  assert(type(spec) == 'table', 'reviewbuf.paint needs an annotation spec')
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
  local count = vim.api.nvim_buf_line_count(buf)
  if count == 0 then
    return
  end
  for _, band in ipairs(spec.bands or {}) do
    if band.row < count then
      vim.api.nvim_buf_set_extmark(buf, M.NS, band.row, 0, {
        line_hl_group = band.hl,
        priority = BAND_PRIORITY,
        strict = false,
      })
    end
  end
  for _, removal in ipairs(spec.removals or {}) do
    set_virt(buf, removal.row, removed_chunks(removal.lines), count)
  end
  local overlay = spec.overlay
  if overlay ~= nil then
    set_virt(buf, overlay.row, annotate.virt_lines(overlay.lines, overlay.marks), count)
  end
end

--- Gives every opened buffer back: ours are wiped, so the review leaves no
--- clone buffers behind; an adopted one only loses the review's marks and keys.
--- @param keys table[] the same key table `open` was given
function M.drop(keys)
  assert(type(keys) == 'table', 'reviewbuf.drop needs the review key table')
  for path, entry in pairs(opened) do
    if vim.api.nvim_buf_is_valid(entry.buf) then
      pcall(vim.api.nvim_buf_clear_namespace, entry.buf, M.NS, 0, -1)
      if entry.adopted then
        for _, key in ipairs(keys) do
          pcall(vim.api.nvim_buf_del_keymap, entry.buf, 'n', key.lhs)
        end
      else
        pcall(vim.api.nvim_buf_delete, entry.buf, { force = true })
      end
    end
    opened[path] = nil
  end
end

--- Test hook: the buffers this review currently holds, by path.
function M.buffers()
  local out = {}
  for path, entry in pairs(opened) do
    out[path] = entry.buf
  end
  return out
end

return M
