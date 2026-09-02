--- Chat capability: wires the panel to the sidecar's `chat.*` methods.
--- Nothing here blocks — every sidecar call is a callback, and the panel is
--- only ever touched from the scheduled callbacks `rpc` hands back.
local agent = require('nvime.agent')
local config = require('nvime.config')
local context = require('nvime.context')
local models = require('nvime.models')
local options = require('nvime.options')
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

--- The session picker's "start a fresh conversation" row. A table, not a
--- string, so it can never collide with a real (SDK-issued) session id.
local NEW_SESSION = {}

local state = {
  root = nil,
  session_id = nil,
  -- True when the next `chat.send` must not fall back to this project's
  -- stored session even though `session_id` is nil — set on every path that
  -- means "start clean" (a fresh open, <C-n>, the picker's new-conversation
  -- row) and cleared once a real session (fresh or resumed) is established.
  explicit_new = true,
  request_id = nil,
  subscribed = false,
  -- False until the project's stored session and its history have both
  -- landed. A send before then would race the resumed transcript into the
  -- live stream and, worse, start a new session before the old one is known.
  restored = false,
  -- A send that arrived while restore was still in flight; replayed once
  -- `restored` goes true, and only into the conversation it was written for —
  -- it carries the `restore_token` it was queued under. At most one: a second
  -- send while still restoring replaces it, since only the latest matters.
  pending_send = nil,
  -- Sessions deleted from this editor, by id. A turn that was already in
  -- flight must not install one of these as the panel's conversation.
  deleted = {},
  -- Bumped whenever the panel walks away from a restore (reopen, <C-n>,
  -- deleting the live session). A reply carrying an older token is dropped
  -- instead of splicing a dead transcript into the current panel.
  restore_token = 0,
  -- The choice the last reply offered, while it is still unanswered:
  -- { block, handle }. At most one — a new turn retires the old question.
  offer = nil,
}

--- Retires the question the last reply offered, giving its keys back. Called
--- before every send, so a block can never outlive the turn that raised it.
local function retire_offer()
  local offer = state.offer
  state.offer = nil
  if offer ~= nil then
    offer.handle.detach()
  end
  return offer
end

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
    surface():interject('  ↳ ' .. (params.summary or params.tool), 'NvimeTool')
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

--- Gives an undelivered prompt back to the user rather than losing or
--- misdelivering it: into the prompt box when there is one and it is empty,
--- otherwise as a notice. Never sent.
local function return_prompt(pending)
  local live = panel.get(PANEL)
  if live ~= nil and live:restore_prompt(pending.text) then
    return
  end
  vim.notify('nvime: your queued prompt was not sent: ' .. pending.text, vim.log.levels.WARN)
end

--- Drops a queued send without delivering it. For every path that walks away
--- from the conversation the prompt was written for.
local function abandon_pending_send()
  local pending = state.pending_send
  state.pending_send = nil
  if pending ~= nil then
    return_prompt(pending)
  end
end

--- Panel closed with a turn still running: nobody will read the reply, and the
--- subscription pays for it either way, so stop it.
local function on_panel_close()
  -- The choice's keys are bound to a buffer that is going away; a handle left
  -- behind would answer the next panel's question with the old one's block.
  retire_offer()
  -- A prompt still queued behind a restore has nowhere to land now: sending it
  -- would bill a turn into a surface nobody can read.
  abandon_pending_send()
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
  state.pending_send = nil
  if pending == nil then
    return
  end
  if pending.token ~= state.restore_token then
    -- The panel walked away from the restore this was queued behind: sending
    -- it now would deliver it to a conversation the user never addressed.
    return_prompt(pending)
    return
  end
  M.send(pending.text, pending.extra, pending.echo)
end

--- Abandons whatever restore is in flight: its reply is dropped rather than
--- replayed into a panel that has moved on. A send queued behind it survives —
--- only the paths that really discard the user's prompt clear `pending_send`.
local function abandon_restore()
  state.restore_token = state.restore_token + 1
end

--- Renders the resumed transcript so a reopened panel is not mysteriously empty.
--- @param token integer the restore generation this reply belongs to
local function load_history(session_id, token)
  agent.request('chat.history', { root = state.root, sessionId = session_id, limit = 40 }, function(err, result)
    if token ~= state.restore_token then
      return
    end
    if err ~= nil then
      -- A missing transcript is not fatal: the session still resumes.
      surface():append('  could not load the earlier turns: ' .. (err.message or '?'), 'NvimeDim')
      finish_restore()
      return
    end
    for _, turn in ipairs(result.turns or {}) do
      surface():append(turn.role == 'user' and 'you' or 'claude', turn.role == 'user' and 'NvimeUser' or 'NvimeAgent')
      surface():append_markdown(turn.text, turn.role == 'user' and 'NvimeUserBody' or 'NvimeAgentBody')
      surface():blank()
    end
    surface():append('— resumed —', 'NvimeDim')
    surface():blank()
    finish_restore()
  end)
end

local function render_fresh_start()
  surface():append('new conversation', 'NvimeSession')
  surface():append('Ask about the project, reference @files, or select code and send it here.', 'NvimeDim')
  surface():append('<C-r> lists past conversations: resume, delete, or start fresh.', 'NvimeDim')
  surface():append('<C-n> always starts clean.', 'NvimeDim')
  surface():blank()
end

--- Puts the panel in the clean "nothing resumed" state and releases a send
--- that queued behind the restore this abandons.
local function begin_fresh_start()
  state.explicit_new = true
  refresh_status(nil)
  render_fresh_start()
  finish_restore()
end

--- Loads `session_id` as the panel's current conversation and replays its
--- transcript. Shared by the picker's resume choice and `chat.default =
--- 'resume-last'`'s open path — the only two places a specific past session
--- becomes the live one.
--- The caller owns the restore generation: a caller switching AWAY from the
--- restore in flight must `abandon_restore()` first, so a prompt queued behind
--- it is not replayed into this session. The `resume-last` open path does not
--- — landing on its own session continues the restore the user typed into.
--- @param session_id string
--- @param note string|nil status suffix; nil for a plain resume on open
local function resume(session_id, note)
  state.session_id = session_id
  state.explicit_new = false
  state.restored = false
  refresh_status(note)
  load_history(session_id, state.restore_token)
end

--- `chat.default = 'resume-last'`: looks up this project's stored session and
--- resumes it; falls back to a fresh start when there is none.
--- @param token integer the restore generation this lookup belongs to
local function open_resume_last(token)
  agent.request('chat.list', { root = state.root, limit = 1 }, function(err, result)
    if token ~= state.restore_token then
      return
    end
    if err ~= nil then
      -- Never downgrade a failed lookup into "this project has no history":
      -- the user opted into resuming and has to know it did not happen.
      show_error(err)
      begin_fresh_start()
      return
    end
    local current = result ~= nil and result.current or nil
    if current == nil then
      begin_fresh_start()
      return
    end
    resume(current, nil)
  end)
end

--- Opens (or focuses) a fresh chat panel for this project.
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
    prompt_hint = 'prompt · <CR> send (i_<C-s>) · <C-n> new · <C-r> sessions · <C-c> stop',
    root = state.root,
    on_submit = M.send,
    on_close = on_panel_close,
    keys = {
      { mode = 'n', lhs = '<C-n>', fn = M.new_session, desc = 'nvime: start a new conversation', where = 'both' },
      { mode = 'n', lhs = '<C-r>', fn = M.pick_session, desc = 'nvime: pick a session', where = 'both' },
      { mode = 'n', lhs = '<C-c>', fn = M.cancel, desc = 'nvime: stop the running turn', where = 'both' },
      { mode = 'n', lhs = ']o', fn = M.jump_to_offer, desc = 'nvime: jump to the pending choice', where = 'both' },
    },
  })
  if not existed then
    abandon_restore()
    state.session_id = nil
    state.pending_send = nil
    if opts.chat.default == 'resume-last' then
      -- The lookup is async and `state` outlives the panel: without resetting
      -- these here, a send in the gap escapes the gate on stale flags and goes
      -- out as a brand-new conversation the resume then lands on top of.
      state.explicit_new = false
      state.restored = false
      refresh_status(nil)
      open_resume_last(state.restore_token)
    else
      state.explicit_new = true
      state.restored = true
      refresh_status(nil)
      render_fresh_start()
    end
  end
end

--- @param text string the prompt
--- @param extra table|nil an additional context block (a visual selection)
--- @param echo string|nil what the transcript shows instead of `text`; a
---   picked option reads back as the choice, not as the number that made it
function M.send(text, extra, echo)
  assert(type(text) == 'string', 'chat.send needs prompt text')
  assert(type(state.root) == 'string', 'chat.send needs an open panel with a captured root')
  local offer = retire_offer()
  if offer ~= nil and echo == nil then
    -- They typed rather than pressed. A bare number in range is still the
    -- option they meant; anything else is their own words, sent as written.
    local pick = options.pick_from_text(offer.block, text)
    if pick ~= nil then
      text, echo = pick, options.echo(pick)
    end
  end
  if not state.restored then
    -- Restore (session lookup + history) is still running: sending now would
    -- guess at the session and let the resumed transcript land mid-stream.
    state.pending_send = { text = text, extra = extra, echo = echo, token = state.restore_token }
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
  surface():append_markdown(echo or text, 'NvimeUserBody')
  for _, warning in ipairs(warnings) do
    surface():append('  ' .. warning, 'NvimeError')
  end
  surface():blank()
  surface():begin_stream('claude', 'NvimeAgentBody')
  surface():start_activity()

  local dial = models.dial('chat')
  -- The reply decides which conversation the panel is in. If the panel has
  -- walked away since (reopen, <C-n>, a picked session, a delete), this turn
  -- is no longer the one on screen and must not name it.
  local token = state.restore_token
  agent.request('chat.send', {
    root = state.root,
    prompt = text,
    context = blocks,
    sessionId = state.session_id,
    new = state.explicit_new,
    projectInstructions = context.project_instructions(state.root),
    model = dial.model,
    effort = dial.effort,
  }, function(err, result)
    state.request_id = nil
    surface():stop_activity()
    surface():finish_stream()
    if err ~= nil then
      show_error(err)
      return
    end
    if token ~= state.restore_token or state.deleted[result.sessionId] then
      return
    end
    state.session_id = result.sessionId
    state.explicit_new = false
    refresh_status(string.format('%d out · $%.4f', result.usage.output, result.costUsd))
    M.offer(result.options)
  end, {
    -- A turn streams for as long as the model takes; <C-c> bounds it, not a timer.
    no_deadline = true,
    on_sent = function(id)
      state.request_id = id
    end,
  })
end

--- Renders the choice a reply offered, and binds the keys that answer it.
--- A payload the panel cannot use is simply not a choice: the prose question
--- it arrived with is already in the transcript, and that still gets answered.
--- @param raw any the `options` block the sidecar returned, or nil
function M.offer(raw)
  -- M.send already retires before it offers again, but that is an ordering
  -- accident of this one caller, not an invariant of M.offer itself.
  retire_offer()
  local block = options.parse(raw)
  local live = panel.get(PANEL)
  if block == nil or live == nil then
    return
  end
  local handle = options.attach(live, block, function(reply)
    state.offer = nil
    M.send(reply, nil, options.echo(reply))
  end, function()
    state.offer = nil
    live:focus()
  end)
  state.offer = { block = block, handle = handle }
end

--- `]o`: jumps to the pending choice from anywhere in the panel — the one way
--- back to it when the cursor is not already on the block (a reader scrolled
--- away, or a digit that would reach it fell through as a motion instead).
function M.jump_to_offer()
  local offer = state.offer
  if offer == nil or not offer.handle.jump() then
    vim.notify('nvime: no pending choice', vim.log.levels.INFO)
  end
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

--- Drops the panel back to fresh after the conversation it was showing was
--- deleted. Its transcript is gone, so nothing here could still resume it.
local function reset_after_delete()
  abandon_restore()
  state.session_id = nil
  state.explicit_new = true
  state.restored = true
  abandon_pending_send()
  surface():replace({}, {})
  surface():append('— that conversation was deleted —', 'NvimeDim')
  surface():blank()
  refresh_status(nil)
  render_fresh_start()
end

--- Deletes a stored session and its history. Called from the picker's `d`,
--- after its own y/n confirm. Drops the panel back to fresh if the deleted
--- session is the one currently live — its transcript is gone, so nothing
--- here could still resume it.
--- @param session_id string
--- @param done fun(ok: boolean) picker.open's on_delete callback
local function delete_session(session_id, done)
  if state.session_id == session_id and state.request_id ~= nil then
    -- Same reason `M.new_session` refuses: the reset below calls
    -- `surface():replace`, which cannot run into an open stream.
    vim.notify('nvime: stop the running turn before deleting this conversation', vim.log.levels.WARN)
    done(false)
    return
  end
  agent.request('chat.forget', { root = state.root, sessionId = session_id }, function(err, result)
    if err ~= nil then
      show_error(err)
      done(false)
      return
    end
    if result ~= nil and result.alreadyGone then
      vim.notify('nvime: that conversation was already gone', vim.log.levels.INFO)
    end
    state.deleted[session_id] = true
    -- The picker row must be released even if the surface work throws, or it
    -- stays dimmed and unusable for the life of the picker. The failure is
    -- re-raised after, never swallowed.
    local reset_ok, reset_err = true, nil
    if state.session_id == session_id then
      reset_ok, reset_err = pcall(reset_after_delete)
    end
    done(true)
    if not reset_ok then
      error(reset_err, 0)
    end
  end)
end

--- `<C-r>`: start fresh, or pick a past session for this project and continue it.
function M.pick_session()
  -- Only reachable from a panel keybind, so the panel's root is already captured.
  assert(type(state.root) == 'string', 'chat.pick_session needs an open panel')
  if state.request_id ~= nil then
    vim.notify('nvime: stop the running turn before switching conversations', vim.log.levels.WARN)
    return
  end
  agent.request('chat.list', { root = state.root, limit = 25 }, function(err, result)
    if err ~= nil then
      show_error(err)
      return
    end
    local items = { { label = 'new conversation', value = NEW_SESSION, deletable = false } }
    for _, session in ipairs(result.sessions or {}) do
      items[#items + 1] = {
        -- The age is metadata, the prompt is the thing being chosen: the
        -- picker dims the first `lead` cells and leaves the title alone.
        label = string.format('%-10s  %s', age(session.lastModified), session.title),
        lead = 12,
        current = session.sessionId == result.current,
        value = session.sessionId,
      }
    end
    picker.open(items, {
      title = ' sessions ',
      on_choice = function(session_id)
        if session_id == NEW_SESSION then
          M.new_session()
          return
        end
        -- The user switched conversations: the restore in flight is theirs no
        -- longer, and a prompt queued behind it was not written for this one.
        abandon_restore()
        abandon_pending_send()
        surface():replace({}, {})
        surface():append('— switched to ' .. short(session_id) .. ' —', 'NvimeDim')
        surface():blank()
        resume(session_id, 'switched')
      end,
      on_delete = delete_session,
    })
  end)
end

--- Starts a clean conversation without deleting any resumable history.
function M.new_session()
  assert(type(state.root) == 'string', 'chat.new_session needs an open panel')
  if state.request_id ~= nil then
    vim.notify('nvime: stop the running turn before starting a new conversation', vim.log.levels.WARN)
    return
  end
  surface():replace({}, {})
  abandon_restore()
  state.session_id = nil
  state.explicit_new = true
  state.restored = true
  abandon_pending_send()
  refresh_status('fresh')
  render_fresh_start()
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
