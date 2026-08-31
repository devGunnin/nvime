--- Live application: reconciles an open buffer with a change the agent just
--- made on disk, without a reload, without losing the cursor, and without ever
--- clobbering unsaved work.
---
--- Three things make it feel live rather than jarring:
---   * only the changed hunks are rewritten, so marks and folds elsewhere live;
---   * the run's successive edits to one buffer are one undo block, so a single
---     `u` puts the file back the way it was before the run;
---   * `:write!` reruns after the edit so Neovim's idea of the file's mtime
---     matches disk — without it the next `:checktime` raises W11/W12 about a
---     file nvime itself just reconciled.
---
--- Undo semantics, honestly: `u` reverts the BUFFER. The file on disk keeps the
--- agent's version until the reverted buffer is written (`:w`).
local diffs = require('nvime.diffs')

local M = {}

M.NS = vim.api.nvim_create_namespace('nvime.edit')

--- Second fade stage lasts this fraction of the configured fade.
local CLEAR_FACTOR = 0.6

local HL = {
  add = 'NvimeEditAdd',
  change = 'NvimeEditChange',
  delete = 'NvimeEditDelete',
}

--- Buffer -> the run and changedtick nvime left it at. Only a buffer still
--- exactly as nvime left it may be undo-joined: anything else means the user
--- typed in between, and joining would swallow their edit into `u`.
local marked = {}

--- Live fade timers by buffer, so a second change restarts the fade instead of
--- letting the first one clear highlights the second just drew.
local fading = {}

--- Deferred call, injectable: tests drive the fade instead of sleeping.
--- @param ms integer
--- @param fn function
--- @return table handle with a `stop` field, safe to call more than once
function M.schedule(ms, fn)
  local timer = vim.uv.new_timer()
  local closed = false
  local function release()
    if closed then
      return
    end
    closed = true
    timer:stop()
    timer:close()
  end
  timer:start(ms, 0, function()
    release()
    vim.schedule(fn)
  end)
  return { stop = release }
end

local function real(path)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- The loaded, file-backed buffer holding `path`, or nil. A buffer that is
--- merely listed has no content to reconcile — it reads the new file when the
--- user finally opens it.
--- @param path string
--- @return integer|nil
function M.buffer_for(path)
  assert(type(path) == 'string' and path ~= '', 'apply.buffer_for needs a path')
  local wanted = real(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= '' and real(name) == wanted then
        return buf
      end
    end
  end
  return nil
end

--- @param buf integer
--- @return string the buffer's content as the file would be written
function M.buffer_text(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  return diffs.to_text(lines, vim.bo[buf].endofline)
end

local function clear_fade(buf)
  local entry = fading[buf]
  if entry == nil then
    return
  end
  fading[buf] = nil
  if entry.timer ~= nil then
    entry.timer.stop()
  end
end

--- Drops every nvime highlight from `buf` and forgets its fade timer.
--- @param buf integer
function M.clear(buf)
  clear_fade(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.NS, 0, -1)
  end
end

local function mark_rows(buf, rows, kind)
  local ids = {}
  for _, row in ipairs(rows) do
    local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, M.NS, row, 0, {
      line_hl_group = HL[kind],
      priority = 90,
    })
    if ok then
      ids[#ids + 1] = id
    end
  end
  return ids
end

local function restyle(buf, ids, group)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  for _, id in ipairs(ids) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(buf, M.NS, id, {})
    if pos[1] ~= nil then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.NS, pos[1], 0, {
        id = id,
        line_hl_group = group,
        priority = 90,
      })
    end
  end
end

--- Dims the fresh highlights after a beat, then removes them. `nofade` keeps
--- them until the next change to that buffer, or `M.clear`.
local function start_fade(buf, ids, opts)
  if opts.nofade or #ids == 0 then
    return
  end
  -- Registered before scheduling: each stage checks it is still the live fade,
  -- so a newer change's highlights are never cleared by an older one's timer.
  local entry = { ids = ids }
  fading[buf] = entry
  entry.timer = M.schedule(opts.fade_ms, function()
    if fading[buf] ~= entry then
      return
    end
    restyle(buf, ids, 'NvimeEditFade')
    entry.timer = M.schedule(math.floor(opts.fade_ms * CLEAR_FACTOR), function()
      if fading[buf] ~= entry then
        return
      end
      fading[buf] = nil
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      for _, id in ipairs(ids) do
        pcall(vim.api.nvim_buf_del_extmark, buf, M.NS, id)
      end
    end)
  end)
end

local function save_views(buf)
  local views = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      views[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    end
  end
  return views
end

local function restore_views(buf, views)
  local last = vim.api.nvim_buf_line_count(buf)
  for win, view in pairs(views) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      view.lnum = math.min(math.max(view.lnum, 1), last)
      view.topline = math.min(math.max(view.topline, 1), last)
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
      end)
    end
  end
end

--- Opens the run's undo block: joined to the previous edit when this buffer is
--- still exactly as nvime left it, and deliberately separated otherwise.
---
--- The separation is not automatic. Neovim only syncs undo on its way back to
--- the main loop, so two changes applied in one tick would otherwise share a
--- block — and a new run's `u` would take the previous run's work with it.
local function open_undo_block(buf, run_id)
  local previous = marked[buf]
  local joinable = previous ~= nil
    and previous.run_id == run_id
    and previous.changedtick == vim.api.nvim_buf_get_changedtick(buf)
  pcall(vim.api.nvim_buf_call, buf, function()
    -- `undojoin` refuses right after an undo (E790); a fresh block is then the
    -- correct outcome, not a failure.
    vim.cmd(joinable and 'undojoin' or 'let &undolevels = &undolevels')
  end)
end

--- Rewrites the file from the buffer so Neovim's stored mtime matches disk.
--- @return string|nil error
local function refresh_mtime(buf)
  local ok, err = pcall(vim.api.nvim_buf_call, buf, function()
    vim.cmd('silent noautocmd keepalt write!')
  end)
  if ok then
    return nil
  end
  return tostring(err)
end

--- Makes the buffer write back byte for byte. 'fixendofline' would otherwise
--- append a trailing newline the agent deliberately did not write.
local function match_eol(buf, after_text)
  local _, eol = diffs.to_lines(after_text)
  if not eol then
    vim.bo[buf].fixendofline = false
  end
  vim.bo[buf].endofline = eol
end

local function apply_hunks(buf, before_text, after_text)
  local after_lines, _ = diffs.to_lines(after_text)
  local hunks = diffs.hunks(before_text, after_text)
  -- Applied last-first so an earlier hunk's row numbers stay valid.
  for i = #hunks, 1, -1 do
    local edit = diffs.buffer_edit(hunks[i], after_lines)
    vim.api.nvim_buf_set_lines(buf, edit.first, edit.last, false, edit.lines)
  end
  return hunks
end

--- Each hunk is marked with its own kind: one change can both add and delete.
local function highlight_hunks(buf, hunks, opts)
  local ids = {}
  local count = vim.api.nvim_buf_line_count(buf)
  for _, hunk in ipairs(hunks) do
    local rows, kind = diffs.changed_rows(hunk, count)
    vim.list_extend(ids, mark_rows(buf, rows, kind))
  end
  start_fade(buf, ids, opts)
  return ids
end

--- Applies one recorded mutation to the buffer holding it, if any.
---
--- @param change table path, before/after snapshots as the sidecar sends them
--- @param opts table run_id (string), fade_ms (integer), nofade (boolean)
--- @return string status one of: applied, unchanged, not-open, conflict,
---   opaque, write-failed
--- @return string|nil detail
function M.apply(change, opts)
  assert(type(change) == 'table' and type(change.path) == 'string', 'apply needs a change with a path')
  assert(type(opts) == 'table' and type(opts.run_id) == 'string', 'apply needs a run id')
  local buf = M.buffer_for(change.path)
  if buf == nil then
    return 'not-open', nil
  end
  local before, after = change.before, change.after
  if type(before) ~= 'table' or before.kind ~= 'text' or type(after) ~= 'table' or after.kind ~= 'text' then
    return 'opaque', 'nvime cannot diff a binary or oversized file'
  end

  local current = M.buffer_text(buf)
  if current == after.text then
    -- Already what the agent wrote: nothing to rewrite, but the stored mtime
    -- still has to catch up or the next :checktime complains.
    match_eol(buf, after.text)
    local err = refresh_mtime(buf)
    marked[buf] = { run_id = opts.run_id, changedtick = vim.api.nvim_buf_get_changedtick(buf) }
    return err == nil and 'unchanged' or 'write-failed', err
  end
  if current ~= before.text then
    return 'conflict', 'the buffer has unsaved edits the agent did not see'
  end

  clear_fade(buf)
  local views = save_views(buf)
  match_eol(buf, after.text)
  open_undo_block(buf, opts.run_id)
  local hunks = apply_hunks(buf, before.text, after.text)
  local write_err = refresh_mtime(buf)
  restore_views(buf, views)
  marked[buf] = { run_id = opts.run_id, changedtick = vim.api.nvim_buf_get_changedtick(buf) }
  highlight_hunks(buf, hunks, {
    fade_ms = opts.fade_ms or 1500,
    nofade = opts.nofade == true,
  })
  if write_err ~= nil then
    return 'write-failed', write_err
  end
  return 'applied', nil
end

--- Test hook: forget the per-buffer undo bookkeeping.
function M.reset()
  marked = {}
  for buf in pairs(fading) do
    clear_fade(buf)
  end
  fading = {}
end

return M
