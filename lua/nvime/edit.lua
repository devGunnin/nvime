--- Edit capability: you point, claude changes it, and you watch it happen.
---
--- The sidecar owns the policy and the change record; this module owns the
--- surface. Every mutation the sidecar pushes is applied to the open buffer
--- immediately, so the file the user is looking at never needs `:e`.
local agent = require('nvime.agent')
local apply = require('nvime.apply')
local approval = require('nvime.approval')
local config = require('nvime.config')
local context = require('nvime.context')
local panel = require('nvime.panel')

local M = {}

local PANEL = 'edit'

--- Writes to a closed panel are dropped rather than raised: a late event must
--- not blow up because the user closed the surface it was headed for.
local NOOP = setmetatable({}, {
  __index = function()
    return function() end
  end,
})

local function surface()
  return panel.get(PANEL) or NOOP
end

local state = {
  root = nil,
  session_id = nil,
  request_id = nil,
  run_id = nil,
  subscribed = false,
  --- Scope for the NEXT instruction only. A follow-up rides the session's own
  --- context instead, so "now do the same for the other queue" is not pinned
  --- to the file the run started on.
  scope = nil,
  --- Per-run tally rendered in the closing summary.
  tally = nil,
}

local STATUS_LINE = {
  applied = { '  updated %s (%s)', 'NvimeEditChange' },
  unchanged = { '  updated %s (%s)', 'NvimeEditChange' },
  ['not-open'] = { '  changed on disk: %s (%s)', 'NvimeDim' },
  opaque = { '  changed on disk, not diffable: %s (%s)', 'NvimeDim' },
  conflict = { '  ! %s (%s) has unsaved edits — left alone, revert it from <leader>nd', 'NvimeError' },
  ['stale-buffer'] = { '  ! %s (%s) — your copy is out of date, :e to reload it', 'NvimeError' },
  ['external-change'] = { '  ! %s (%s) — something else wrote this file; nvime did not overwrite it', 'NvimeError' },
  ['write-failed'] = { '  ! %s (%s) applied in the buffer but could not be refreshed on disk', 'NvimeError' },
}

--- Statuses that mean the change is on disk but not in the buffer, so the run
--- summary can tell the user how many need them.
local UNAPPLIED = { conflict = true, ['stale-buffer'] = true, ['external-change'] = true }

--- `vim.fs.relpath` only exists from 0.11; nvime supports 0.10 onwards.
local function relative_to_root(path)
  if state.root == nil then
    return path
  end
  local prefix = state.root .. '/'
  if vim.startswith(path, prefix) then
    return path:sub(#prefix + 1)
  end
  return path
end

local function refresh_status(suffix)
  local base = state.run_id == nil and 'nvime edit' or ('run ' .. state.run_id)
  if suffix == nil then
    surface():status(base)
    return
  end
  surface():status(base .. ' · ' .. suffix)
end

local function show_error(err)
  surface():interject('! ' .. (err.message or 'the agent failed'), 'NvimeError')
  if err.detail ~= nil and err.detail ~= '' then
    for _, line in ipairs(vim.split(err.detail, '\n', { plain = true, trimempty = true })) do
      surface():append('  ' .. line, 'NvimeDim')
    end
  end
  surface():blank()
end

--- Applies one pushed mutation and reports the outcome in the panel.
local function on_applied(change)
  local opts = config.get().edit
  local status, detail = apply.apply(change, {
    run_id = change.runId or state.run_id or 'run',
    fade_ms = opts.fade_ms,
    nofade = opts.nofade,
  })
  if state.tally ~= nil then
    state.tally.hunks = state.tally.hunks + 1
    state.tally.files[change.path] = true
    if UNAPPLIED[status] then
      state.tally.conflicts = state.tally.conflicts + 1
    end
  end
  local spec = STATUS_LINE[status] or { '  %s (%s): ' .. status, 'NvimeDim' }
  surface():interject(string.format(spec[1], relative_to_root(change.path), status), spec[2])
  if detail ~= nil and status ~= 'unchanged' then
    surface():append('    ' .. detail, 'NvimeDim')
  end
end

--- An approved shell step changed files nvime has no before/after for. The
--- buffers are reconciled with disk here so they do not quietly go stale and
--- turn the next recorded change into a conflict the user did not cause.
local function on_external_change(params)
  if state.root == nil then
    return
  end
  local opts = config.get().edit
  local reloaded, left = apply.recheck(state.root, {
    run_id = params.runId or state.run_id or 'shell',
    fade_ms = opts.fade_ms,
    nofade = opts.nofade,
  })
  if #reloaded == 0 and #left == 0 then
    return
  end
  surface():interject('  ' .. (params.reason or 'files changed outside nvime'), 'NvimeDim')
  for _, path in ipairs(reloaded) do
    surface():append('    reloaded ' .. relative_to_root(path) .. ' (not in the changeset)', 'NvimeDim')
  end
  for _, entry in ipairs(left) do
    surface():append('    ! ' .. relative_to_root(entry.path) .. ' — ' .. entry.reason, 'NvimeError')
  end
end

local function on_approval(request)
  approval.ask(request, function(allow)
    agent.request('edit.answer', { approvalId = request.approvalId, allow = allow }, function(err, result)
      if err ~= nil then
        show_error(err)
        return
      end
      if not result.answered then
        surface():append('  the agent had already stopped waiting for that answer', 'NvimeDim')
      end
    end)
  end)
  surface():interject('  ? ' .. (request.summary or request.tool) .. ' — ' .. (request.reason or ''), 'NvimeActivity')
end

local function on_event(name, params)
  if params.id ~= nil and params.id ~= state.request_id then
    return
  end
  if name == 'edit.started' then
    state.session_id = params.sessionId
    state.run_id = params.runId
    refresh_status(params.model)
  elseif name == 'edit.delta' then
    surface():push_delta(params.text)
  elseif name == 'edit.tool' then
    surface():interject('  ' .. (params.summary or params.tool), 'NvimeDim')
  elseif name == 'edit.applied' then
    on_applied(params)
  elseif name == 'edit.external_change' then
    on_external_change(params)
  elseif name == 'edit.approval' then
    on_approval(params)
  elseif name == 'edit.approval_settled' then
    approval.settle(params.approvalId)
  elseif name == 'rpc.error' then
    show_error(params.error or { message = 'the sidecar rejected a frame' })
  end
end

local function subscribe_once()
  if state.subscribed then
    return
  end
  agent.on_event(on_event)
  state.subscribed = true
end

--- Panel closed mid-run: nobody will read the rest, and an approval nobody can
--- answer would sit until the sidecar's deadline. Stop both.
local function on_panel_close()
  approval.dismiss_all()
  local target = state.request_id
  if target == nil then
    return
  end
  agent.request('edit.cancel', { target = target }, function(err)
    if err ~= nil then
      vim.notify('nvime: could not stop the edit run: ' .. (err.message or '?'), vim.log.levels.WARN)
    end
  end)
end

--- Opens (or focuses) the edit panel. The root is captured once per panel,
--- from the buffer the user was in — reopening from inside the panel must not
--- re-root the run on a scratch buffer with no path.
function M.open()
  local opts = config.get()
  subscribe_once()
  if not panel.is_open(PANEL) then
    state.root = context.project_root()
    state.session_id = nil
    state.run_id = nil
  end
  panel.open({
    name = PANEL,
    title = 'nvime edit',
    width = opts.panel.width,
    prompt_height = opts.panel.prompt_height,
    position = opts.panel.position,
    prompt_hint = 'instruct · <CR> send (i_<C-s>) · <C-c> stop · <leader>nd changes',
    on_submit = M.send,
    on_close = on_panel_close,
    keys = {
      { mode = 'n', lhs = '<C-c>', fn = M.cancel, desc = 'nvime: stop the edit run', where = 'both' },
    },
  })
  refresh_status(nil)
end

--- `<leader>ne` in normal mode: instruct about the file in the current buffer.
function M.instruct()
  local path = context.current_path()
  M.open()
  if path == nil then
    surface():append('  this buffer has no file — the instruction covers the project', 'NvimeDim')
    state.scope = { kind = 'project' }
    return
  end
  state.scope = { kind = 'file', path = path }
  refresh_status(relative_to_root(path))
end

--- `<leader>ne` in visual mode: instruct about the selection.
function M.instruct_selection()
  local block = context.selection()
  if block == nil then
    vim.notify('nvime: nothing selected', vim.log.levels.WARN)
    return
  end
  M.open()
  state.scope = {
    kind = 'selection',
    path = block.path,
    startLine = block.startLine,
    endLine = block.endLine,
    text = block.text,
  }
  refresh_status(string.format('%s:%d-%d', relative_to_root(block.path), block.startLine, block.endLine))
end

local function summarise(result)
  local files = 0
  for _ in pairs(state.tally.files) do
    files = files + 1
  end
  local line = string.format(
    '— %d file%s, %d change%s · %d out · $%.4f —',
    files,
    files == 1 and '' or 's',
    state.tally.hunks,
    state.tally.hunks == 1 and '' or 's',
    result.usage.output,
    result.costUsd
  )
  surface():append(line, 'NvimeDim')
  if state.tally.conflicts > 0 then
    surface():append(
      string.format('  %d left unapplied in their buffers — <leader>nd to review', state.tally.conflicts),
      'NvimeError'
    )
  end
  surface():blank()
end

--- Sends one instruction. The panel's prompt stays armed afterwards, so the
--- next one continues the same session.
--- @param text string
function M.send(text)
  assert(type(text) == 'string', 'edit.send needs instruction text')
  assert(type(state.root) == 'string', 'edit.send needs an open panel with a captured root')
  if state.request_id ~= nil then
    vim.notify('nvime: an edit run is already going (<C-c> to stop it)', vim.log.levels.WARN)
    return
  end
  -- Consumed once: a follow-up rides the session's context, not the old scope.
  local scope = state.scope or { kind = 'project' }
  state.scope = nil
  state.tally = { files = {}, hunks = 0, conflicts = 0 }

  surface():append('you', 'NvimeUser')
  surface():append_markdown(text)
  surface():blank()
  surface():begin_stream('claude')
  surface():start_activity()

  agent.request('edit.start', {
    root = state.root,
    prompt = text,
    scope = scope,
    sessionId = state.session_id,
    projectInstructions = context.project_instructions(state.root),
  }, function(err, result)
    state.request_id = nil
    approval.dismiss_all()
    surface():stop_activity()
    surface():finish_stream()
    if err ~= nil then
      show_error(err)
      return
    end
    state.session_id = result.sessionId
    state.run_id = result.runId
    summarise(result)
    refresh_status('done')
  end, {
    -- A run streams for as long as the model takes; <C-c> bounds it, not a timer.
    no_deadline = true,
    on_sent = function(id)
      state.request_id = id
    end,
  })
end

function M.cancel()
  if state.request_id == nil then
    vim.notify('nvime: no edit run to stop', vim.log.levels.INFO)
    return
  end
  agent.request('edit.cancel', { target = state.request_id }, function(err, result)
    if err ~= nil then
      show_error(err)
    elseif not result.cancelled then
      vim.notify('nvime: the run had already finished', vim.log.levels.INFO)
    end
  end)
end

--- The project the edit surface is bound to, falling back to the current
--- buffer's project before the first run.
--- @return string
function M.root()
  if state.root ~= nil then
    return state.root
  end
  return context.project_root()
end

--- Whether a turn is in flight for this surface.
--- @return boolean
function M.is_running()
  return state.request_id ~= nil
end

--- Test hook: the live edit state.
function M.state()
  return state
end

return M
