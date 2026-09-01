--- Chat capability: wires the panel to the sidecar's `chat.*` methods.
--- Nothing here blocks — every sidecar call is a callback, and the panel is
--- only ever touched from the scheduled callbacks `rpc` hands back.
local agent = require('nvime.agent')
local config = require('nvime.config')
local context = require('nvime.context')
local panel = require('nvime.panel')
local picker = require('nvime.picker')

local M = {}

local PANEL = 'chat'

--- Writes to a closed panel are dropped, not errors: a late reply must not
--- blow up just because the user closed the surface it was headed for.
local NOOP = setmetatable({}, {
  __index = function()
    return function() end
  end,
})

--- The chat surface, or the no-op stand-in when the panel is closed.
local function surface()
  return panel.get(PANEL) or NOOP
end

local state = {
  root = nil,
  session_id = nil,
  request_id = nil,
  subscribed = false,
  -- False until the project's stored session and its history have both
  -- landed. A send before then would race the resumed transcript into the
  -- live stream and, worse, start a new session before the old one is known.
  restored = false,
  -- A send that arrived while restore was still in flight; replayed once
  -- `restored` goes true. At most one: a second send while still restoring
  -- replaces it, since only the latest prompt matters.
  pending_send = nil,
}

local function short(session_id)
  return session_id == nil and 'new session' or ('session ' .. session_id:sub(1, 8))
end

local function refresh_status(suffix)
  surface():status(short(state.session_id) .. (suffix and (' · ' .. suffix) or ''))
end

--- Writes a failure into the panel. Deliberately does NOT end a running turn:
--- a late reply to an unrelated request must not truncate the live stream.
local function show_error(err)
  surface():interject('! ' .. (err.message or 'the agent failed'), 'NvimeError')
  if err.detail ~= nil and err.detail ~= '' then
    for _, line in ipairs(vim.split(err.detail, '\n', { plain = true, trimempty = true })) do
      surface():append('  ' .. line, 'NvimeDim')
    end
  end
  surface():blank()
end

local function on_event(name, params)
  if params.id ~= nil and params.id ~= state.request_id then
    return
  end
  if name == 'chat.started' then
    state.session_id = params.sessionId
    refresh_status(params.model)
  elseif name == 'chat.delta' then
    surface():push_delta(params.text)
  elseif name == 'chat.tool' then
    surface():interject('  ' .. (params.summary or params.tool), 'NvimeDim')
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

--- Panel closed with a turn still running: nobody will read the reply, and the
--- subscription pays for it either way, so stop it.
local function on_panel_close()
  local target = state.request_id
  if target == nil then
    return
  end
  agent.request('chat.cancel', { target = target }, function(err)
    if err ~= nil then
      vim.notify('nvime: could not stop the turn: ' .. (err.message or '?'), vim.log.levels.WARN)
    end
  end)
end

--- Marks the restore pipeline done and replays a send that arrived mid-flight.
--- Must run only once history (if any) has actually been written, not once it
--- has merely been requested — otherwise the replayed send's own "you" line
--- and stream can still land ahead of the async history it raced.
local function finish_restore()
  state.restored = true
  local pending = state.pending_send
  if pending == nil then
    return
  end
  state.pending_send = nil
  M.send(pending.text, pending.extra)
end

--- Renders the resumed transcript so a reopened panel is not mysteriously empty.
local function load_history(session_id)
  agent.request('chat.history', { root = state.root, sessionId = session_id, limit = 40 }, function(err, result)
    if err ~= nil then
      -- A missing transcript is not fatal: the session still resumes.
      surface():append('  could not load the earlier turns: ' .. (err.message or '?'), 'NvimeDim')
      finish_restore()
      return
    end
    for _, turn in ipairs(result.turns or {}) do
      surface():append(turn.role == 'user' and 'you' or 'claude', turn.role == 'user' and 'NvimeUser' or 'NvimeAgent')
      surface():append_markdown(turn.text)
      surface():blank()
    end
    surface():append('— resumed —', 'NvimeDim')
    surface():blank()
    finish_restore()
  end)
end

local function restore_session()
  agent.request('chat.list', { root = state.root, limit = 25 }, function(err, result)
    if err ~= nil then
      show_error(err)
      finish_restore()
      return
    end
    state.session_id = result.current
    refresh_status(nil)
    if result.current ~= nil then
      load_history(result.current)
    else
      finish_restore()
    end
  end)
end

--- Opens (or focuses) the chat panel and resumes this project's session.
--- The root is captured once per panel, from the buffer the user was in — a
--- second `M.open()` from inside the panel must not re-root the session on the
--- prompt buffer, which has no path and would fall back to the cwd.
function M.open()
  local opts = config.get()
  subscribe_once()
  local existed = panel.is_open(PANEL)
  if not existed then
    state.root = context.project_root()
  end
  panel.open({
    name = PANEL,
    title = 'nvime chat',
    width = opts.panel.width,
    prompt_height = opts.panel.prompt_height,
    position = opts.panel.position,
    prompt_hint = 'prompt · <CR> send (i_<C-s>) · <C-r> sessions · <C-c> stop',
    root = state.root,
    on_submit = M.send,
    on_close = on_panel_close,
    keys = {
      { mode = 'n', lhs = '<C-r>', fn = M.pick_session, desc = 'nvime: pick a session', where = 'both' },
      { mode = 'n', lhs = '<C-c>', fn = M.cancel, desc = 'nvime: stop the running turn', where = 'both' },
    },
  })
  if not existed then
    state.restored = false
    refresh_status(nil)
    restore_session()
  end
end

--- @param text string the prompt
--- @param extra table|nil an additional context block (a visual selection)
function M.send(text, extra)
  assert(type(text) == 'string', 'chat.send needs prompt text')
  assert(type(state.root) == 'string', 'chat.send needs an open panel with a captured root')
  if not state.restored then
    -- Restore (session lookup + history) is still running: sending now would
    -- guess at the session and let the resumed transcript land mid-stream.
    state.pending_send = { text = text, extra = extra }
    return
  end
  if state.request_id ~= nil then
    vim.notify('nvime: a turn is already running (<C-c> to stop it)', vim.log.levels.WARN)
    return
  end
  local blocks, warnings = context.expand(text, state.root)
  if extra ~= nil then
    table.insert(blocks, 1, extra)
  end

  surface():append('you', 'NvimeUser')
  surface():append_markdown(text)
  for _, warning in ipairs(warnings) do
    surface():append('  ' .. warning, 'NvimeError')
  end
  surface():blank()
  surface():begin_stream('claude')
  surface():start_activity()

  agent.request('chat.send', {
    root = state.root,
    prompt = text,
    context = blocks,
    sessionId = state.session_id,
    projectInstructions = context.project_instructions(state.root),
  }, function(err, result)
    state.request_id = nil
    surface():stop_activity()
    surface():finish_stream()
    if err ~= nil then
      show_error(err)
      return
    end
    state.session_id = result.sessionId
    refresh_status(string.format('%d out · $%.4f', result.usage.output, result.costUsd))
  end, {
    -- A turn streams for as long as the model takes; <C-c> bounds it, not a timer.
    no_deadline = true,
    on_sent = function(id)
      state.request_id = id
    end,
  })
end

--- Sends the visual selection with its file and line range attached.
function M.send_selection()
  local block = context.selection()
  if block == nil then
    vim.notify('nvime: nothing selected', vim.log.levels.WARN)
    return
  end
  M.open()
  local where = string.format('%s:%d-%d', vim.fn.fnamemodify(block.path, ':t'), block.startLine, block.endLine)
  M.send('Explain this selection from ' .. where .. '.', block)
end

function M.cancel()
  if state.request_id == nil then
    vim.notify('nvime: nothing is running', vim.log.levels.INFO)
    return
  end
  agent.request('chat.cancel', { target = state.request_id }, function(err, result)
    if err ~= nil then
      show_error(err)
    elseif not result.cancelled then
      vim.notify('nvime: the turn had already finished', vim.log.levels.INFO)
    end
  end)
end

local function age(ms)
  local seconds = math.max(0, os.time() - math.floor(ms / 1000))
  if seconds < 3600 then
    return string.format('%dm ago', math.floor(seconds / 60))
  end
  if seconds < 86400 then
    return string.format('%dh ago', math.floor(seconds / 3600))
  end
  return string.format('%dd ago', math.floor(seconds / 86400))
end

--- `<C-r>`: pick a past session for this project and continue it.
function M.pick_session()
  -- Only reachable from a panel keybind, so the panel's root is already captured.
  assert(type(state.root) == 'string', 'chat.pick_session needs an open panel')
  agent.request('chat.list', { root = state.root, limit = 25 }, function(err, result)
    if err ~= nil then
      show_error(err)
      return
    end
    local items = {}
    for _, session in ipairs(result.sessions or {}) do
      local marker = session.sessionId == result.current and '* ' or '  '
      items[#items + 1] = {
        label = string.format('%s%-12s %s', marker, age(session.lastModified), session.title),
        value = session.sessionId,
      }
    end
    picker.open(items, {
      title = ' sessions ',
      on_choice = function(session_id)
        state.session_id = session_id
        refresh_status('switched')
        surface():append('— switched to ' .. short(session_id) .. ' —', 'NvimeDim')
        surface():blank()
        load_history(session_id)
      end,
    })
  end)
end

--- Whether a turn is in flight for this surface.
--- @return boolean
function M.is_running()
  return state.request_id ~= nil
end

--- Test hook: the live chat state.
function M.state()
  return state
end

return M
