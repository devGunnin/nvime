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

--- What this review opened, by path: { buf, adopted, prior }. `adopted` means
--- the buffer already existed, so it is the reader's: it is handed back rather
--- than wiped. `prior` is what the options were before the review locked the
--- buffer, recorded for every entry so the restore below has nothing to check.
--- Adoption governs OWNERSHIP only — the read-only contract applies to every
--- buffer the pane shows, whoever owns it.
local opened = {}

--- Owns the re-lock watchers, so they go with `drop`/`release` rather than
--- outliving the review that installed them.
local GROUP = vim.api.nvim_create_augroup('nvime.reviewbuf', { clear = true })

--- The read-only contract. The clone is a sandbox to read: neither a stray
--- key nor a `BufWritePre` formatter may rewrite the file the captured diff
--- was taken from, or the pane's bands land on rows that have moved.
local function lock(buf)
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
end

--- Re-locks after a reload. `:edit!` re-reads the file and clears `readonly`
--- with it, which quietly turns `:w` from an `E45` into a real write.
--- @param buf integer
local function watch_reload(buf)
  vim.api.nvim_create_autocmd('BufReadPost', {
    group = GROUP,
    buffer = buf,
    desc = 'nvime: a reload must not unlock a review buffer',
    callback = function()
      lock(buf)
    end,
  })
end

--- @param buf integer
--- @param keys table[] each { lhs, fn, desc }
local function install_keys(buf, keys)
  for _, key in ipairs(keys) do
    vim.keymap.set('n', key.lhs, key.fn, { buffer = buf, nowait = true, silent = true, desc = key.desc })
  end
end

--- True when `buf` is on screen in a window outside the review's own tab.
--- Locking such a buffer read-only and hanging the review's keys off it turns
--- an ordinary tab the reader opened into a control surface where `q` tears
--- the review down and `M` merges.
--- @param buf integer
--- @param review_tab integer|nil the review's tabpage; nil means none is ours
local function shown_outside(buf, review_tab)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) ~= review_tab then
      return true
    end
  end
  return false
end

--- Re-reads `buf` from disk. `:edit`, not `:checktime`: with `autoread` off a
--- checktime opens a modal prompt nothing here can answer.
--- @return boolean whether it was re-read
local function reread(buf)
  local was_modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  local ok = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd('edit')
  end)
  vim.bo[buf].modifiable = was_modifiable
  return ok
end

--- The clone's copy of `path`, loaded, locked and keyed for the review.
---
--- Refused, rather than adopted, for a buffer already on screen outside the
--- review's tab: the caller degrades to the unified diff and the reader keeps
--- their ordinary window.
--- @param path string absolute, inside the build clone
--- @param keys table[] the review's buffer-local keys, each { lhs, fn, desc }
--- @param review_tab integer|nil the review's tabpage
--- @return integer|nil buffer
--- @return string|nil why it could not be opened
--- @return string|nil a one-time notice about the buffer that was adopted
function M.open(path, keys, review_tab)
  assert(type(path) == 'string' and path ~= '', 'reviewbuf.open needs a path')
  assert(type(keys) == 'table', 'reviewbuf.open needs the review key table')
  local known = opened[path]
  if known ~= nil and vim.api.nvim_buf_is_valid(known.buf) then
    -- Re-applied rather than assumed: a reload, or anything else that touched
    -- the buffer since, can have left it writable or stripped its keys.
    lock(known.buf)
    install_keys(known.buf, keys)
    return known.buf
  end
  -- Ownership is "this review created the buffer", so it has to be read
  -- BEFORE `bufadd`. A listed-but-unloaded buffer (`:badd`, an arglist, a
  -- restored session) is an ordinary buffer of the reader's, not ours to wipe.
  local adopted = vim.fn.bufexists(path) == 1
  local buf = vim.fn.bufadd(path)
  if buf == 0 then
    return nil, 'neovim would not open ' .. path
  end
  local name = vim.fn.fnamemodify(path, ':t')
  if adopted and shown_outside(buf, review_tab) then
    return nil, name .. ' is open in another tab (close it there, or <CR> to go to it)'
  end
  -- Nothing below may leave a buffer of ours behind on a failure.
  local function abandon(why)
    if not adopted then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
    return nil, why
  end
  if not adopted then
    -- Before the load: a swap file for a sandbox copy is litter, and a stale
    -- one opens an E325 modal that no pcall around the draw can answer.
    vim.bo[buf].swapfile = false
  end
  -- Reading a file runs the reader's own autocmds; one that raises must
  -- degrade the pane with a reason, not throw out of a redraw.
  local ok, err = pcall(vim.fn.bufload, buf)
  if not ok then
    return abandon(tostring(err))
  end
  if not vim.api.nvim_buf_is_loaded(buf) then
    return abandon('could not read ' .. path)
  end
  local notice = nil
  if adopted then
    -- The pane is about to grade what the reader has in front of them, which
    -- is not what is on disk and not what a merge would land.
    notice = vim.bo[buf].modified and (name .. ' has unsaved changes — the pane is showing yours, not the clone’s')
      or nil
  else
    vim.bo[buf].buflisted = false
  end
  local prior = { modifiable = vim.bo[buf].modifiable, readonly = vim.bo[buf].readonly }
  lock(buf)
  watch_reload(buf)
  install_keys(buf, keys)
  opened[path] = { buf = buf, adopted = adopted, prior = prior }
  return buf, nil, notice
end

--- Re-reads every buffer this review adopted. Ours are wiped and read again by
--- the redraw a new capture triggers; an adopted one is the reader's, stays
--- loaded, and would otherwise be annotated with the new diff's rows while
--- still holding the old content.
--- @return string[] paths that could not be re-read (unsaved edits), sorted
function M.refresh()
  local stale = {}
  for path, entry in pairs(opened) do
    local live = entry.adopted and vim.api.nvim_buf_is_valid(entry.buf) and vim.api.nvim_buf_is_loaded(entry.buf)
    if live and (vim.bo[entry.buf].modified or not reread(entry.buf)) then
      stale[#stale + 1] = path
    end
  end
  table.sort(stale)
  return stale
end

--- One removed line per virtual line: the marker carries the diff colour, the
--- text itself stays dim — it is not in the file any more.
--- @param lines string[]
--- @return table[] one chunk list per line
local function removed_chunks(lines)
  local out = {}
  for index, text in ipairs(lines) do
    -- The `\r` of a CRLF file belongs to the line ending; left in, it renders
    -- as a `^M` the file's own lines do not show.
    local shown = annotate.strip_cr(text)
    local chunks = { { annotate.REMOVED_PREFIX, 'NvimeRemoved' } }
    if shown ~= '' then
      chunks[#chunks + 1] = { shown, 'NvimeDim' }
    end
    out[index] = chunks
  end
  return out
end

--- Hangs `virt` off `row`, above it when there is such a row — a deletion past
--- the last line has nothing to sit above, so it goes below the last one.
---
--- The row is clamped here rather than trusted: it comes from patch arithmetic
--- over a file that may have moved, and `strict = false` does not cover the
--- line argument — an out-of-range one raises out of the draw.
local function set_virt(buf, row, virt, count)
  assert(count > 0, 'reviewbuf.set_virt needs a non-empty buffer')
  local at = math.max(0, math.min(row, count - 1))
  vim.api.nvim_buf_set_extmark(buf, M.NS, at, 0, {
    virt_lines = virt,
    virt_lines_above = row < count,
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
    if band.row >= 0 and band.row < count then
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

--- Gives one entry's buffer back: ours is wiped, so the review leaves no clone
--- buffers behind; an adopted one gets its marks, keys and options back
--- exactly as the reader had them.
---
--- It runs in teardown loops where a raise would leak every buffer still to
--- come, so every step that can fail is guarded — and `prior` is recorded for
--- every entry, so the restore itself has no missing-state case to assert on.
--- @param entry table
--- @param keys table[]
local function give_back(entry, keys)
  if not vim.api.nvim_buf_is_valid(entry.buf) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, entry.buf, M.NS, 0, -1)
  pcall(vim.api.nvim_clear_autocmds, { group = GROUP, buffer = entry.buf })
  if not entry.adopted then
    pcall(vim.api.nvim_buf_delete, entry.buf, { force = true })
    return
  end
  for _, key in ipairs(keys) do
    pcall(vim.api.nvim_buf_del_keymap, entry.buf, 'n', key.lhs)
  end
  vim.bo[entry.buf].modifiable = entry.prior.modifiable
  vim.bo[entry.buf].readonly = entry.prior.readonly
end

--- Gives one path back, so a thread the pane could not vouch for stops being
--- held: a released path is one `<CR>` can open in an ordinary tab again.
--- @param path string
--- @param keys table[] the same key table `open` was given
function M.release(path, keys)
  assert(type(path) == 'string' and path ~= '', 'reviewbuf.release needs a path')
  assert(type(keys) == 'table', 'reviewbuf.release needs the review key table')
  local entry = opened[path]
  if entry == nil then
    return
  end
  opened[path] = nil
  give_back(entry, keys)
end

--- Gives every opened buffer back.
--- @param keys table[] the same key table `open` was given
function M.drop(keys)
  assert(type(keys) == 'table', 'reviewbuf.drop needs the review key table')
  for path, entry in pairs(opened) do
    opened[path] = nil
    give_back(entry, keys)
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
