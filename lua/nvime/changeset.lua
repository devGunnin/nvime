--- Changeset review: everything the agent changed in this project, per file
--- and per hunk, with a per-hunk revert that goes back through the same live
--- application path the change itself took.
---
--- The sidecar owns the record (it holds the exact before/after), so this view
--- always re-reads it rather than keeping a second copy that could drift.
local agent = require('nvime.agent')
local apply = require('nvime.apply')
local config = require('nvime.config')
local diffs = require('nvime.diffs')
local edit = require('nvime.edit')
local panel = require('nvime.panel')

local M = {}

local PANEL = 'changeset'

local view = {
  root = nil,
  changes = {},
  --- Buffer row (1-based) -> { change = index, hunk = index|nil }.
  rows = {},
  --- Hunks reverted from this view. The sidecar's record is the run as it
  --- happened and never changes, so "already reverted" is knowledge only the
  --- view has — without it a second revert reports a drift the user did not make.
  reverted = {},
  unified = false,
}

local function hunk_key(change, hunk_index)
  return string.format('%s:%d:%d', change.runId, change.index, hunk_index)
end

local function surface()
  return panel.get(PANEL)
end

local function relative(path)
  if view.root == nil then
    return path
  end
  local prefix = view.root .. '/'
  if vim.startswith(path, prefix) then
    return path:sub(#prefix + 1)
  end
  return path
end

--- Both sides as plain text, or nil when the change cannot be diffed at all.
--- @return string|nil before
--- @return string|nil after
--- @return string|nil reason
local function texts(change)
  local before, after = change.before, change.after
  if type(before) ~= 'table' or type(after) ~= 'table' then
    return nil, nil, 'the change was not recorded with contents'
  end
  if before.kind == 'absent' then
    return nil, nil, 'that file did not exist before the run — delete it yourself'
  end
  if after.kind == 'absent' then
    return nil, nil, 'that file was removed — restore it yourself'
  end
  if before.kind ~= 'text' or after.kind ~= 'text' then
    return nil, nil, 'binary or oversized files are recorded but not diffable'
  end
  return before.text, after.text, nil
end

local function describe_hunk(hunk)
  local start_b, count_b = hunk[3], hunk[4]
  if count_b == 0 then
    return string.format('- removed %d line%s after %d', hunk[2], hunk[2] == 1 and '' or 's', start_b)
  end
  local last = start_b + count_b - 1
  local sign = hunk[2] == 0 and '+' or '~'
  if start_b == last then
    return string.format('%s line %d', sign, start_b)
  end
  return string.format('%s lines %d-%d', sign, start_b, last)
end

local function render_list()
  local lines, rows = {}, {}
  for index, change in ipairs(view.changes) do
    local before, after, reason = texts(change)
    lines[#lines + 1] = relative(change.path)
    rows[#lines] = { change = index }
    if before == nil then
      lines[#lines + 1] = '    ' .. reason
      rows[#lines] = { change = index }
    else
      for hunk_index, hunk in ipairs(diffs.hunks(before, after)) do
        local done = view.reverted[hunk_key(change, hunk_index)] == true
        lines[#lines + 1] = '    ' .. describe_hunk(hunk) .. (done and '  · reverted' or '')
        rows[#lines] = { change = index, hunk = hunk_index }
      end
    end
    lines[#lines + 1] = ''
    rows[#lines] = nil
  end
  return lines, rows
end

local function render_unified()
  local lines, rows = {}, {}
  for index, change in ipairs(view.changes) do
    local before, after, reason = texts(change)
    local text = reason
    if before ~= nil then
      text = diffs.unified(relative(change.path), before, after)
    end
    for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
      lines[#lines + 1] = line
      rows[#lines] = { change = index }
    end
    lines[#lines + 1] = ''
  end
  return lines, rows
end

local function draw()
  local self = surface()
  if self == nil then
    return
  end
  if #view.changes == 0 then
    view.rows = {}
    self:replace({ 'nothing changed in this project yet.', '', 'run an edit with <leader>ne.' })
    self:status('changeset · empty')
    return
  end
  local lines, rows
  if view.unified then
    lines, rows = render_unified()
  else
    lines, rows = render_list()
  end
  view.rows = rows
  self:replace(lines)
  self:status(
    string.format(
      'changeset · %d change%s · r revert · d diff · <CR> open',
      #view.changes,
      #view.changes == 1 and '' or 's'
    )
  )
end

--- The file as it is right now: the buffer when one holds it, else disk.
--- @return string|nil text
--- @return string|nil error
local function read_current(path)
  local buf = apply.buffer_for(path)
  if buf ~= nil then
    return apply.buffer_text(buf), nil
  end
  local handle, err = io.open(path, 'rb')
  if handle == nil then
    return nil, string.format('could not read %s (%s)', path, tostring(err))
  end
  local text = handle:read('a')
  handle:close()
  return text, nil
end

--- @return string|nil error
local function write_file(path, text)
  local handle, err = io.open(path, 'wb')
  if handle == nil then
    return string.format('could not write %s (%s)', path, tostring(err))
  end
  local ok, write_err = handle:write(text)
  handle:close()
  if not ok then
    return string.format('could not write %s (%s)', path, tostring(write_err))
  end
  return nil
end

--- Puts `text` on disk and into the buffer holding the file, through the same
--- live-application path an agent change takes.
--- @return string|nil error
local function land(path, current, text)
  if apply.buffer_for(path) == nil then
    return write_file(path, text)
  end
  local status, detail = apply.apply(
    { path = path, before = { kind = 'text', text = current }, after = { kind = 'text', text = text } },
    { run_id = 'revert', fade_ms = config.get().edit.fade_ms, nofade = config.get().edit.nofade }
  )
  if status == 'applied' or status == 'unchanged' then
    return nil
  end
  return detail or ('the revert could not be applied (' .. status .. ')')
end

--- Reverts one hunk. Refuses rather than corrupting when the lines it would
--- rewrite have been hand-edited since the agent touched them.
--- @param target table { change = index, hunk = index }
--- @return boolean ok
--- @return string|nil reason
function M.revert(target)
  assert(type(target) == 'table' and type(target.change) == 'number', 'changeset.revert needs a target')
  local change = view.changes[target.change]
  if change == nil or target.hunk == nil then
    return false, 'put the cursor on a hunk to revert it'
  end
  local before, after, reason = texts(change)
  if before == nil then
    return false, reason
  end
  local hunk = diffs.hunks(before, after)[target.hunk]
  if hunk == nil then
    return false, 'that hunk is no longer part of the change'
  end
  if view.reverted[hunk_key(change, target.hunk)] then
    return false, 'that hunk is already reverted'
  end
  local current, read_err = read_current(change.path)
  if current == nil then
    return false, read_err
  end
  local offset, drift = diffs.locate(after, current, hunk[3], hunk[4])
  if offset == nil then
    return false, drift
  end
  local current_lines, eol = diffs.to_lines(current)
  local reverse = diffs.reverse_edit(hunk, diffs.to_lines(before), offset)
  local reverted = {}
  vim.list_extend(reverted, current_lines, 1, reverse.first)
  vim.list_extend(reverted, reverse.lines)
  vim.list_extend(reverted, current_lines, reverse.last + 1, #current_lines)
  local land_err = land(change.path, current, diffs.to_text(reverted, eol))
  if land_err ~= nil then
    return false, land_err
  end
  view.reverted[hunk_key(change, target.hunk)] = true
  return true, nil
end

local function cursor_target()
  local self = surface()
  if self == nil or not vim.api.nvim_win_is_valid(self.win) then
    return nil
  end
  return view.rows[vim.api.nvim_win_get_cursor(self.win)[1]]
end

local function revert_at_cursor()
  local target = cursor_target()
  if target == nil then
    vim.notify('nvime: put the cursor on a hunk to revert it', vim.log.levels.WARN)
    return
  end
  local ok, reason = M.revert(target)
  if not ok then
    vim.notify('nvime: ' .. (reason or 'could not revert that hunk'), vim.log.levels.WARN)
    return
  end
  M.refresh()
end

local function open_at_cursor()
  local target = cursor_target()
  if target == nil then
    return
  end
  local change = view.changes[target.change]
  local line = 1
  local before, after = texts(change)
  if before ~= nil and target.hunk ~= nil then
    local hunk = diffs.hunks(before, after)[target.hunk]
    if hunk ~= nil then
      line = math.max(hunk[3], 1)
    end
  end
  vim.cmd('wincmd p')
  vim.cmd('edit ' .. vim.fn.fnameescape(change.path))
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
end

local function toggle_unified()
  view.unified = not view.unified
  draw()
end

--- Re-reads the record from the sidecar and redraws.
function M.refresh()
  if view.root == nil then
    return
  end
  agent.request('edit.list_changes', { root = view.root }, function(err, result)
    if err ~= nil then
      vim.notify('nvime: could not load the changeset: ' .. (err.message or '?'), vim.log.levels.WARN)
      return
    end
    view.changes = result.changes or {}
    draw()
  end)
end

--- Opens the changeset for the project the edit surface is bound to.
function M.open()
  local opts = config.get()
  local root = edit.root()
  if root ~= view.root then
    view.reverted = {}
  end
  view.root = root
  panel.open({
    name = PANEL,
    title = 'nvime changeset',
    width = opts.panel.width,
    position = opts.panel.position,
    filetype = 'diff',
    prompt = false,
    keys = {
      { mode = 'n', lhs = '<CR>', fn = open_at_cursor, desc = 'nvime: open the file at this hunk' },
      { mode = 'n', lhs = 'r', fn = revert_at_cursor, desc = 'nvime: revert this hunk' },
      { mode = 'n', lhs = 'd', fn = toggle_unified, desc = 'nvime: toggle the unified diff' },
    },
  })
  draw()
  M.refresh()
end

--- Test hook: the rendered model.
function M.view()
  return view
end

return M
