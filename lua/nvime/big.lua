--- Big Change mode: the intake conversation, the worktree build, and the
--- handoff to the review threads.
---
--- The sidecar owns the session record and reconciles it against disk, so this
--- module never caches a state of its own — every action re-reads the view the
--- sidecar hands back. A build that outlived the editor therefore reappears as
--- "building (detached)", not as something this side guessed at.
local agent = require('nvime.agent')
local config = require('nvime.config')
local context = require('nvime.context')
local panel = require('nvime.panel')
local picker = require('nvime.picker')
local threads = require('nvime.threads')

local M = {}

local PANEL = 'big'

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
  --- The last SessionView the sidecar returned, or nil when none is selected.
  session = nil,
  request_id = nil,
  subscribed = false,
}

local function show_error(err)
  surface():interject('! ' .. (err.message or 'the big change failed'), 'NvimeError')
  if err.detail ~= nil and err.detail ~= '' then
    for _, line in ipairs(vim.split(err.detail, '\n', { plain = true, trimempty = true })) do
      surface():append('  ' .. line, 'NvimeDim')
    end
  end
  surface():blank()
end

--- One line describing where a session is, in the words the picker uses.
--- @param session table a SessionView or list summary
--- @return string
function M.describe(session)
  if session == nil then
    return 'no big change selected'
  end
  local label = session.display or 'drafting'
  if session.detached and (label == 'building' or label == 'triaging') then
    return label .. ' (detached — sidecar gone)'
  end
  if label == 'reviewing' or label == 'mergeable' then
    local counts = session.counts or { open = 0, total = 0 }
    return string.format('%s · %d of %d threads open', label, counts.open, counts.total)
  end
  return label
end

local function refresh_status()
  local session = state.session
  if session == nil then
    surface():status('big change · no session')
    return
  end
  surface():status(string.format('%s · %s', session.title, M.describe(session)))
end

local function render_spec(spec)
  if spec == nil then
    return
  end
  local self = surface()
  self:append('spec', 'NvimeHeading')
  self:append('  goal      ' .. spec.goal, 'NvimeDim')
  if spec.approach ~= nil and spec.approach ~= '' then
    self:append('  approach  ' .. spec.approach, 'NvimeDim')
  end
  local sections = {
    { 'scope', spec.scope },
    { 'accept', spec.acceptance },
    { 'not', spec.outOfScope },
  }
  for _, section in ipairs(sections) do
    for _, item in ipairs(section[2] or {}) do
      self:append(string.format('  %-9s %s', section[1], item), 'NvimeDim')
    end
  end
  self:blank()
end

--- What the user can do next, given where the session is. Shown after every
--- transition so the panel never leaves them guessing at the keystroke.
local function render_next_step()
  local session = state.session
  if session == nil then
    return
  end
  local hints = {
    drafting = session.spec ~= nil and 'answer, revise, or type `approve` to build it'
      or 'answer the question to sharpen the spec',
    building = session.detached and 'type `resume` to pick the build back up, or `discard` to throw it away'
      or 'building — <C-c> stops it',
    triaging = 'sorting the diff into threads',
    reviewing = '<C-t> opens the review threads',
    mergeable = '<C-t> opens the review threads',
  }
  local hint = hints[session.display]
  if hint ~= nil then
    surface():append('  ' .. hint, 'NvimeActivity')
    surface():blank()
  end
end

--- Adopts a view the sidecar returned as the panel's current session.
local function adopt(session)
  state.session = session
  refresh_status()
end

local function on_event(name, params)
  if params.id ~= nil and params.id ~= state.request_id then
    return
  end
  if name == 'big.started' then
    surface():interject(string.format('  %s · %s', params.phase, params.model or '?'), 'NvimeDim')
  elseif name == 'big.delta' then
    surface():push_delta(params.text)
  elseif name == 'big.tool' then
    surface():interject('  ' .. (params.summary or params.tool), 'NvimeDim')
  elseif name == 'big.denied' then
    surface():interject(string.format('  ! %s refused — %s', params.tool, params.reason or ''), 'NvimeError')
  elseif name == 'big.notice' then
    surface():interject('  ' .. params.text, 'NvimeError')
  elseif name == 'big.state' then
    surface():interject('  → ' .. params.state, 'NvimeSession')
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

--- Panel closed mid-run. The build keeps going in the sidecar on purpose — it
--- is meant to survive the editor — so only the streaming subscription ends.
local function on_panel_close()
  state.request_id = nil
end

--- Sends one request that streams into the panel, and settles the surface once.
--- @param method string
--- @param params table
--- @param done fun(session: table) called with the returned SessionView
local function stream(method, params, done)
  if state.request_id ~= nil then
    vim.notify('nvime: this big change is already running (<C-c> to stop it)', vim.log.levels.WARN)
    return
  end
  surface():begin_stream('claude')
  surface():start_activity()
  agent.request(method, params, function(err, result)
    state.request_id = nil
    surface():stop_activity()
    surface():finish_stream()
    if err ~= nil then
      show_error(err)
      M.refresh()
      return
    end
    adopt(result.session)
    done(result.session)
  end, {
    -- A build runs for as long as it takes; <C-c> bounds it, not a timer.
    no_deadline = true,
    on_sent = function(id)
      state.request_id = id
    end,
  })
end

--- Re-reads the selected session so the panel shows the sidecar's truth.
function M.refresh()
  if state.root == nil or state.session == nil then
    return
  end
  agent.request('big.open', { root = state.root, sessionId = state.session.id }, function(err, result)
    if err ~= nil then
      return
    end
    adopt(result.session)
  end)
end

local function title_from(text)
  local first = vim.split(text, '\n', { plain = true })[1] or text
  return vim.trim(first):sub(1, 80)
end

local function start_new(text)
  agent.request('big.create', { root = state.root, title = title_from(text) }, function(err, result)
    if err ~= nil then
      show_error(err)
      return
    end
    adopt(result.session)
    surface():append('— ' .. result.session.title .. ' —', 'NvimeSession')
    surface():blank()
    M.ask(text)
  end)
end

--- One intake exchange: the user's message, then the agent's next question.
--- @param text string
function M.ask(text)
  assert(type(text) == 'string' and text ~= '', 'big.ask needs a message')
  assert(state.session ~= nil, 'big.ask needs a selected session')
  stream('big.intake', { root = state.root, sessionId = state.session.id, message = text }, function(session)
    local last = session.conversation[#session.conversation]
    if last ~= nil and last.role == 'agent' then
      surface():append('claude', 'NvimeAgent')
      surface():append_markdown(last.text)
      surface():blank()
    end
    render_spec(session.spec)
    render_next_step()
  end)
end

--- Freezes the spec, creates the worktree, and starts the build.
function M.approve()
  assert(state.session ~= nil, 'big.approve needs a selected session')
  local id = state.session.id
  surface():append('— approved; building in a worktree —', 'NvimeSession')
  agent.request('big.approve', { root = state.root, sessionId = id }, function(err, result)
    if err ~= nil then
      show_error(err)
      return
    end
    adopt(result.session)
    local base = result.session.worktree or {}
    surface():append(string.format('  worktree %s', base.path or '?'), 'NvimeDim')
    surface():append(
      string.format('  base     %s on %s', (base.baseCommit or '?'):sub(1, 8), base.baseBranch or '-'),
      'NvimeDim'
    )
    surface():blank()
    M.build()
  end)
end

--- Runs (or resumes) the build, then captures and triages what it produced.
function M.build()
  assert(state.session ~= nil, 'big.build needs a selected session')
  stream('big.build', { root = state.root, sessionId = state.session.id }, function(session)
    surface():append(
      string.format(
        '— %d thread%s, %d open —',
        session.counts.total,
        session.counts.total == 1 and '' or 's',
        session.counts.open
      ),
      'NvimeDim'
    )
    surface():blank()
    render_next_step()
    if session.counts.total > 0 then
      M.open_threads()
    end
  end)
end

--- Throws the worktree and the record away. Only ever on an explicit `discard`.
function M.discard()
  assert(state.session ~= nil, 'big.discard needs a selected session')
  local title = state.session.title
  agent.request('big.discard', { root = state.root, sessionId = state.session.id }, function(err)
    if err ~= nil then
      show_error(err)
      return
    end
    state.session = nil
    refresh_status()
    surface():append('— discarded ' .. title .. ' —', 'NvimeDim')
    surface():blank()
  end)
end

--- The panel's prompt. What it means depends on where the session is, and the
--- panel says which words it is listening for at every step.
--- @param text string
function M.send(text)
  assert(type(text) == 'string', 'big.send needs prompt text')
  assert(type(state.root) == 'string', 'big.send needs an open panel with a captured root')
  surface():append('you', 'NvimeUser')
  surface():append_markdown(text)
  surface():blank()

  if state.session == nil then
    start_new(text)
    return
  end
  local word = vim.trim(text):lower()
  local display = state.session.display
  if display == 'drafting' then
    if word == 'approve' then
      M.approve()
    else
      M.ask(text)
    end
  elseif display == 'building' or display == 'triaging' then
    M.resume_or_discard(word)
  else
    surface():append('  this change is built — <C-t> opens the review threads', 'NvimeActivity')
    surface():blank()
  end
end

--- The two answers a detached build accepts. Anything else is refused rather
--- than guessed at: both of them are expensive to get wrong.
--- @param word string the prompt, trimmed and lowercased
function M.resume_or_discard(word)
  if word == 'resume' then
    M.build()
  elseif word == 'discard' then
    M.discard()
  elseif state.session ~= nil and state.session.detached then
    surface():append('  type `resume` to pick the build back up, or `discard` to throw it away', 'NvimeActivity')
    surface():blank()
  else
    surface():append('  the build is running — <C-c> stops it', 'NvimeActivity')
    surface():blank()
  end
end

function M.cancel()
  if state.request_id == nil then
    vim.notify('nvime: no big change is running', vim.log.levels.INFO)
    return
  end
  agent.request('big.cancel', { target = state.request_id }, function(err, result)
    if err ~= nil then
      show_error(err)
    elseif not result.cancelled then
      vim.notify('nvime: it had already finished', vim.log.levels.INFO)
    end
  end)
end

--- `<C-t>`: the review threads for the selected session.
function M.open_threads()
  if state.session == nil then
    vim.notify('nvime: no big change selected', vim.log.levels.WARN)
    return
  end
  -- The thread view owns the session while it is open (a revision re-triages
  -- it), so it hands every new view back rather than letting the two drift.
  threads.open(state.root, state.session, adopt)
end

--- `<C-r>`: pick one of this project's big changes and load it into the panel.
function M.pick_session()
  assert(type(state.root) == 'string', 'big.pick_session needs an open panel')
  agent.request('big.list', { root = state.root }, function(err, result)
    if err ~= nil then
      show_error(err)
      return
    end
    local items = {}
    for _, session in ipairs(result.sessions or {}) do
      items[#items + 1] = {
        label = string.format('%-14s %s', M.describe(session):sub(1, 14), session.title),
        value = session.id,
      }
    end
    if #items == 0 then
      vim.notify('nvime: no big changes yet — describe one in the prompt', vim.log.levels.INFO)
      return
    end
    picker.open(items, {
      title = ' big changes ',
      on_choice = function(id)
        M.select(id)
      end,
    })
  end)
end

--- Loads one session into the panel and replays its conversation.
--- @param id string
function M.select(id)
  agent.request('big.open', { root = state.root, sessionId = id }, function(err, result)
    if err ~= nil then
      show_error(err)
      return
    end
    adopt(result.session)
    local self = surface()
    self:append('— ' .. result.session.title .. ' —', 'NvimeSession')
    for _, turn in ipairs(result.session.conversation or {}) do
      self:append(turn.role == 'user' and 'you' or 'claude', turn.role == 'user' and 'NvimeUser' or 'NvimeAgent')
      self:append_markdown(turn.text)
      self:blank()
    end
    render_spec(result.session.spec)
    render_next_step()
  end)
end

--- Opens (or focuses) the big-change panel. The root is captured once per
--- panel, from the buffer the user was in.
function M.open()
  local opts = config.get()
  subscribe_once()
  local existed = panel.is_open(PANEL)
  if not existed then
    state.root = context.project_root()
    state.session = nil
  end
  panel.open({
    name = PANEL,
    title = 'nvime big change',
    width = opts.panel.width,
    prompt_height = opts.panel.prompt_height,
    position = opts.panel.position,
    prompt_hint = 'describe it · <CR> send · <C-r> sessions · <C-t> threads · <C-c> stop',
    on_submit = M.send,
    on_close = on_panel_close,
    keys = {
      { mode = 'n', lhs = '<C-r>', fn = M.pick_session, desc = 'nvime: pick a big change', where = 'both' },
      { mode = 'n', lhs = '<C-t>', fn = M.open_threads, desc = 'nvime: open the review threads', where = 'both' },
      { mode = 'n', lhs = '<C-c>', fn = M.cancel, desc = 'nvime: stop the big change', where = 'both' },
    },
  })
  if not existed then
    refresh_status()
    surface():append('describe the change you want. claude will ask until the spec is real.', 'NvimeDim')
    surface():append('<C-r> lists the big changes already going in this project.', 'NvimeDim')
    surface():blank()
  end
end

--- Whether a big-change request is in flight from this editor.
--- @return boolean
function M.is_running()
  return state.request_id ~= nil
end

--- Test hook: the live big-change state.
function M.state()
  return state
end

return M
