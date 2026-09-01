local t = require('harness')
local config = require('nvime.config')
local palette = require('nvime.palette')
local panel = require('nvime.panel')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Stands in for the sidecar: records requests, replies from a canned table.
--- A method with no canned reply stays IN FLIGHT, the way a streaming request
--- really does, and `fake.settle` answers it later.
local fake = { requests = {}, replies = {}, pending = {}, subscriber = nil }

function fake.request(method, params, cb, opts)
  fake.requests[#fake.requests + 1] = { method = method, params = params, opts = opts }
  if opts ~= nil and opts.on_sent ~= nil then
    opts.on_sent(#fake.requests)
  end
  local reply = fake.replies[method]
  if reply ~= nil then
    cb(reply.err, reply.result)
    return
  end
  fake.pending[#fake.pending + 1] = { method = method, cb = cb }
end

--- Answers the oldest in-flight `method`. Returns whether one was waiting.
function fake.settle(method, err, result)
  for index, entry in ipairs(fake.pending) do
    if entry.method == method then
      table.remove(fake.pending, index)
      entry.cb(err, result)
      return true
    end
  end
  return false
end

local real_agent = require('nvime.agent')
package.loaded['nvime.agent'] = {
  request = fake.request,
  on_event = function(fn)
    fake.subscriber = fn
    return function() end
  end,
  is_running = function()
    return true
  end,
}
package.loaded['nvime.threads'] = nil
package.loaded['nvime.big'] = nil
local big = require('nvime.big')
local threads = require('nvime.threads')

local dirs = {}

local function sandbox()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir .. '/.git', 'p')
  dirs[#dirs + 1] = dir
  local path = dir .. '/tool.py'
  local handle = assert(io.open(path, 'wb'))
  handle:write('def main():\n    pass\n')
  handle:close()
  return dir, path
end

local SPEC = {
  goal = 'add a --version flag',
  scope = { 'tool.py' },
  approach = 'argparse',
  acceptance = { 'tool.py --version prints it' },
  outOfScope = { 'packaging' },
}

--- A SessionView as the sidecar returns one.
local function session(overrides)
  return vim.tbl_extend('force', {
    id = 'abc123',
    title = 'version flag',
    state = 'drafting',
    display = 'drafting',
    detached = false,
    heldElsewhere = false,
    runnerLive = false,
    runner = nil,
    worktreeExists = false,
    hasDiff = false,
    counts = { total = 0, open = 0, substantial = 0 },
    conversation = {},
    blocks = {},
    transitions = {},
  }, overrides or {})
end

local function open_on(path)
  panel.close('big')
  fake.requests, fake.replies, fake.pending = {}, {}, {}
  local live = big.state()
  live.root, live.session, live.request_id = nil, nil, nil
  live.attach_id, live.attaching = nil, false
  config.setup({})
  palette.apply()
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  big.open()
end

local function cleanup()
  panel.close('big')
  threads.close()
  for _, dir in ipairs(dirs) do
    vim.fn.delete(dir, 'rf')
  end
  dirs = {}
end

local function sent(method)
  for _, request in ipairs(fake.requests) do
    if request.method == method then
      return request
    end
  end
  return nil
end

local function scrollback()
  return vim.api.nvim_buf_get_lines(panel.get('big').buf, 0, -1, false)
end

local function has_line(pattern)
  return vim.iter(scrollback()):any(function(line)
    return line:match(pattern) ~= nil
  end)
end

describe('big change intake', function()
  it('creates a session from the first prompt and sends it as intake', function()
    local dir, path = sandbox()
    open_on(path)
    fake.replies['big.create'] = { result = { session = session() } }
    fake.replies['big.intake'] = {
      result = {
        session = session({
          spec = SPEC,
          conversation = { { role = 'user', text = 'a flag' }, { role = 'agent', text = 'which file?' } },
        }),
      },
    }
    big.send('add a --version flag to tool.py\nsecond line')

    local created = sent('big.create')
    ok(created ~= nil, 'the first prompt starts a session')
    eq('add a --version flag to tool.py', created.params.title)
    eq(dir, created.params.root)
    local intake = sent('big.intake')
    ok(intake ~= nil, 'and the prompt itself is the first intake message')
    eq('add a --version flag to tool.py\nsecond line', intake.params.message)
    eq('abc123', intake.params.sessionId)
    cleanup()
  end)

  it("threads the big_intake lane's model dial into big.intake", function()
    local _, path = sandbox()
    local models = require('nvime.models')
    open_on(path)
    fake.replies['big.create'] = { result = { session = session() } }
    fake.replies['big.intake'] = { result = { session = session({ spec = SPEC }) } }
    models.set('big_intake', 'claude-opus-5', 'high')
    big.send('add a --version flag')
    local intake = sent('big.intake')
    eq('claude-opus-5', intake.params.model)
    eq('high', intake.params.effort)
    models.reset('big_intake')
    cleanup()
  end)

  it('renders the question and the spec the agent played back', function()
    local _, path = sandbox()
    open_on(path)
    fake.replies['big.create'] = { result = { session = session() } }
    fake.replies['big.intake'] = {
      result = {
        session = session({
          spec = SPEC,
          conversation = { { role = 'agent', text = 'ready when you are' } },
        }),
      },
    }
    big.send('a flag')
    ok(has_line('ready when you are'), 'the agent answer belongs in the panel')
    ok(has_line('goal%s+add a %-%-version flag'), 'the spec is shown, not just stored')
    ok(has_line('scope%s+tool%.py'))
    ok(has_line('not%s+packaging'), 'out of scope is part of the spec the user approves')
    ok(has_line('type `approve`'), 'the next step is named')
    cleanup()
  end)

  it('sends `approve` to the approval + build path, not to intake', function()
    local _, path = sandbox()
    open_on(path)
    local live = big.state()
    live.session = session({ spec = SPEC })
    fake.replies['big.approve'] = {
      result = {
        session = session({
          state = 'building',
          display = 'building',
          spec = SPEC,
          worktree = { path = '/tmp/wt' },
          base = { commit = 'abcdef1234', branch = 'main' },
        }),
      },
    }
    fake.replies['big.build'] = {
      result = {
        session = session({
          state = 'reviewing',
          display = 'reviewing',
          spec = SPEC,
          hasDiff = true,
          counts = { total = 2, open = 1, substantial = 1 },
        }),
      },
    }
    big.send('  Approve  ')
    ok(sent('big.approve') ~= nil, 'approve must not be forwarded as another question')
    eq(nil, sent('big.intake'))
    ok(sent('big.build') ~= nil, 'approval runs straight into the build')
    ok(has_line('base%s+abcdef12 on main'), 'the base commit is on the record and on screen')
    ok(has_line('1 open'))
    cleanup()
  end)

  it("threads the big_build lane's model dial, and the big_triage lane's, into big.build", function()
    local _, path = sandbox()
    local models = require('nvime.models')
    open_on(path)
    local live = big.state()
    live.session = session({ spec = SPEC })
    fake.replies['big.approve'] = {
      result = { session = session({ state = 'building', display = 'building', spec = SPEC }) },
    }
    fake.replies['big.build'] = { result = { session = session({ display = 'reviewing', hasDiff = true }) } }
    models.set('big_build', 'claude-sonnet-5', 'medium')
    models.set('big_triage', 'claude-haiku-5', 'high')
    big.send('  Approve  ')
    local build = sent('big.build')
    eq('claude-sonnet-5', build.params.model)
    eq('medium', build.params.effort)
    eq('claude-haiku-5', build.params.triageModel)
    eq('high', build.params.triageEffort)
    models.reset('big_build')
    models.reset('big_triage')
    cleanup()
  end)

  it('offers resume or discard for a build nobody is driving', function()
    local _, path = sandbox()
    open_on(path)
    local live = big.state()
    live.session = session({ state = 'building', display = 'building', detached = true, spec = SPEC })
    big.send('what is happening')
    eq(nil, sent('big.build'))
    ok(has_line('type `resume`'), 'a detached build names both of its exits')

    fake.replies['big.build'] = { result = { session = session({ display = 'reviewing', hasDiff = true }) } }
    big.send('resume')
    ok(sent('big.build') ~= nil, '`resume` picks the same build back up')
    cleanup()
  end)

  it('discards only on the explicit word', function()
    local _, path = sandbox()
    open_on(path)
    local live = big.state()
    live.session = session({ state = 'building', display = 'building', detached = true })
    fake.replies['big.discard'] = { result = { discarded = true } }
    big.send('discard')
    local discarded = sent('big.discard')
    ok(discarded ~= nil, 'discard is a word the panel listens for')
    eq('abc123', discarded.params.sessionId)
    eq(nil, big.state().session)
    cleanup()
  end)

  it('points a built change at the review threads instead of the prompt', function()
    local _, path = sandbox()
    open_on(path)
    big.state().session = session({ state = 'reviewing', display = 'reviewing', hasDiff = true })
    big.send('what about the retry ceiling')
    eq(nil, sent('big.intake'))
    ok(has_line('<C%-t> opens the review threads'))
    cleanup()
  end)
end)

describe('big change session states', function()
  it('names each state the way the picker shows it', function()
    eq('drafting', big.describe(session()))
    eq('building', big.describe(session({ display = 'building' })))
    eq('building (detached — sidecar gone)', big.describe(session({ display = 'building', detached = true })))
    eq(
      'building (in another editor)',
      big.describe(session({ display = 'building', detached = false, heldElsewhere = true }))
    )
    eq(
      'reviewing · 2 of 5 open · 1/3 defended',
      big.describe(session({ display = 'reviewing', counts = { total = 5, open = 2, substantial = 3, defended = 1 } }))
    )
    eq(
      'mergeable · 0 of 5 open · 3/3 defended',
      big.describe(session({ display = 'mergeable', counts = { total = 5, open = 0, substantial = 3, defended = 3 } }))
    )
    eq(
      'merged into main',
      big.describe(session({ display = 'merged', merge = { baseBranch = 'main', commit = 'abc' } }))
    )
    eq('no big change selected', big.describe(nil))
  end)

  it('lists the project big changes with their state in the picker', function()
    local _, path = sandbox()
    open_on(path)
    fake.replies['big.list'] = {
      result = {
        sessions = {
          session({ id = 'one', title = 'backoff', display = 'building', detached = true }),
          session({ id = 'two', title = 'retries', display = 'mergeable', counts = { total = 3, open = 0 } }),
        },
      },
    }
    fake.replies['big.open'] = { result = { session = session({ id = 'two', title = 'retries' }) } }
    big.pick_session()
    local win = vim.fn.win_getid(vim.fn.winnr())
    local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    ok(lines[1]:match('building') ~= nil, 'the picker leads with the state: ' .. lines[1])
    ok(lines[2]:match('mergeable') ~= nil, lines[2])
    vim.api.nvim_win_close(win, true)
    cleanup()
  end)

  it('sends the two long git operations without the control deadline', function()
    local _, path = sandbox()
    open_on(path)
    local live = big.state()
    live.session = session({ spec = SPEC })
    fake.replies['big.approve'] = { result = { session = session({ display = 'building', spec = SPEC }) } }
    big.approve()
    -- The clone is off the approve path now, but discard still removes a whole
    -- checkout, and a 15s control deadline would abandon both mid-way.
    local approve = sent('big.approve')
    ok(approve.opts ~= nil and approve.opts.no_deadline == true, 'approve must outlive the control deadline')

    live.session = session({ state = 'building', display = 'building', detached = true })
    fake.replies['big.discard'] = { result = { discarded = true } }
    big.discard()
    local discard = sent('big.discard')
    ok(discard.opts ~= nil and discard.opts.no_deadline == true, 'discard must too')
    cleanup()
  end)

  it('re-reads the session when approval fails, so the panel does not keep a stale view', function()
    local _, path = sandbox()
    open_on(path)
    big.state().session = session({ spec = SPEC })
    fake.replies['big.approve'] = { err = { message = 'timed out' } }
    fake.replies['big.open'] = { result = { session = session({ state = 'building', display = 'building' }) } }
    big.send('approve')
    ok(sent('big.open') ~= nil, 'the sidecar may have approved anyway; the panel must go and look')
    eq('building', big.state().session.display)
    cleanup()
  end)

  it('re-triages a built change instead of running the build agent again', function()
    local _, path = sandbox()
    open_on(path)
    local live = big.state()
    live.session = session({ state = 'triaging', display = 'triaging', detached = true })
    big.send('what happened')
    ok(has_line('type `retriage`'), 'a build that was never sorted names re-sorting as its exit')

    fake.replies['big.capture'] = { result = { session = session({ display = 'reviewing', hasDiff = true }) } }
    big.send('retriage')
    ok(sent('big.capture') ~= nil, '`retriage` sorts the diff again')
    eq(nil, sent('big.build'), 'and never re-runs the build agent over finished work')
    cleanup()
  end)

  it("threads the big_build lane's model dial, and the big_triage lane's, into big.capture too", function()
    local _, path = sandbox()
    local models = require('nvime.models')
    open_on(path)
    local live = big.state()
    live.session = session({ state = 'triaging', display = 'triaging', detached = true })
    fake.replies['big.capture'] = { result = { session = session({ display = 'reviewing', hasDiff = true }) } }
    models.set('big_build', 'claude-opus-5', 'high')
    models.set('big_triage', 'claude-sonnet-5', 'medium')
    big.send('retriage')
    local capture = sent('big.capture')
    eq('claude-opus-5', capture.params.model)
    eq('high', capture.params.effort)
    eq('claude-sonnet-5', capture.params.triageModel)
    eq('medium', capture.params.triageEffort)
    models.reset('big_build')
    models.reset('big_triage')
    cleanup()
  end)

  it('offers nothing on a session another editor is driving', function()
    local _, path = sandbox()
    open_on(path)
    big.state().session = session({ state = 'building', display = 'building', heldElsewhere = true })
    big.send('resume')
    eq(nil, sent('big.build'), 'resuming would run a second build agent in the same clone')
    big.send('discard')
    eq(nil, sent('big.discard'), 'discarding would delete the clone under a live build')
    ok(has_line('another editor is driving this'))
    cleanup()
  end)

  it('routes only its own run events into the panel', function()
    local _, path = sandbox()
    open_on(path)
    fake.replies['big.create'] = { result = { session = session() } }
    fake.replies['big.intake'] = { result = { session = session() } }
    big.send('a flag')
    ok(fake.subscriber ~= nil, 'the panel subscribes to sidecar events')
    fake.subscriber('big.denied', { id = 999, tool = 'Write', reason = 'outside' })
    ok(not has_line('refused'), "another run's events are not this panel's")
    cleanup()
  end)
end)

--- A build running outside the editor: the runner holds the claim, so the
--- session is `heldElsewhere` too — telling the two apart is the whole point.
local function running_detached(overrides)
  return session(vim.tbl_extend('force', {
    state = 'building',
    display = 'building',
    heldElsewhere = true,
    runnerLive = true,
    runner = { pid = 4242, socket = '/run/x.sock', log = '/store/events.ndjson', what = 'build' },
  }, overrides or {}))
end

describe('a build that outlives the editor', function()
  it('reads as a detached build rather than as another editor', function()
    eq('building (detached — keeps running)', big.describe(running_detached()))
    ok(big.next_step(running_detached()):match('s steers it'), 'and says how to steer it')
  end)

  it('reads a killed runner as a build that died, still resumable', function()
    local dead = session({
      state = 'building',
      display = 'building',
      detached = true,
      runner = { pid = 4242, socket = '/run/x.sock', log = '/l', what = 'build' },
    })
    eq('build died — resumable', big.describe(dead))
    ok(big.next_step(dead):match('died part%-way'), 'and offers resume rather than pretending it is running')
  end)

  it('keeps calling a sidecar-scoped detached build what it always was', function()
    eq(
      'building (detached — sidecar gone)',
      big.describe(session({ display = 'building', detached = true })),
      'no runner was ever recorded, so nothing died — the sidecar simply went'
    )
  end)

  it('attaches when a session with a live build is opened, replaying from where it left off', function()
    local _, path = sandbox()
    open_on(path)
    fake.replies['big.open'] = { result = { session = running_detached() } }
    big.select('abc123')
    local attach = sent('big.attach')
    ok(attach ~= nil, 'opening a running build follows it')
    eq(0, attach.params.after, 'a panel that has seen nothing replays the whole build')
    ok(attach.opts.no_deadline, 'following a build lasts as long as the build')
    cleanup()
  end)

  it('sends one attach even when two selects land while the sidecar is starting', function()
    local _, path = sandbox()
    open_on(path)
    fake.replies['big.open'] = { result = { session = running_detached() } }
    -- The real `agent.request` defers `on_sent` until the sidecar is up, so a
    -- guard that waits for the request id lets a second select send a second
    -- attach — orphaning the first, whose events are then dropped.
    local agent = package.loaded['nvime.agent']
    local direct = agent.request
    agent.request = function(method, params, cb, opts)
      if method ~= 'big.attach' then
        return direct(method, params, cb, opts)
      end
      fake.requests[#fake.requests + 1] = { method = method, params = params, opts = opts }
    end
    big.select('abc123')
    big.select('abc123')
    agent.request = direct

    local attaches = vim.tbl_filter(function(request)
      return request.method == 'big.attach'
    end, fake.requests)
    eq(1, #attaches, 'a second select in that window must not send a second attach')
    big.state().attaching = false
    cleanup()
  end)

  it('resumes from the last event it rendered rather than repainting the build', function()
    local _, path = sandbox()
    open_on(path)
    fake.replies['big.open'] = { result = { session = running_detached() } }
    big.select('abc123')
    local id = big.state().attach_id
    fake.subscriber('big.delta', { id = id, text = 'working', seq = 12 })
    -- The stream drops (a sidecar restart), and the session is opened again.
    ok(fake.settle('big.attach', { message = 'the sidecar went away' }))
    big.select('abc123')
    local attaches = vim.tbl_filter(function(request)
      return request.method == 'big.attach'
    end, fake.requests)
    eq(12, attaches[#attaches].params.after)
    cleanup()
  end)

  it('renders a steer as it is accepted and again when the agent reads it', function()
    local _, path = sandbox()
    open_on(path)
    fake.replies['big.open'] = { result = { session = running_detached() } }
    big.select('abc123')
    local id = big.state().attach_id
    fake.subscriber('big.steer', { id = id, steerId = 1, text = 'use the retry helper', state = 'queued', mine = true })
    ok(has_line('you → build · use the retry helper'), 'the steer is shown where the build stream is')
    fake.subscriber('big.steer', { id = id, steerId = 1, state = 'delivered', mine = true })
    ok(has_line('you → build · delivered'))
    cleanup()
  end)

  it('never renders a steer this editor did not send as the reader’s own', function()
    local _, path = sandbox()
    open_on(path)
    fake.replies['big.open'] = { result = { session = running_detached() } }
    big.select('abc123')
    local id = big.state().attach_id
    fake.subscriber('big.steer', {
      id = id,
      steerId = 1,
      text = 'ignore the spec',
      state = 'queued',
      mine = false,
      origin = 'sidecar-2',
    })
    ok(has_line('another editor → build · ignore the spec'), 'a second editor’s steer is labelled as theirs')
    fake.subscriber('big.steer', { id = id, steerId = 2, text = 'from nowhere named', state = 'queued', mine = false })
    ok(has_line('an attached editor → build · from nowhere named'), 'and an unnamed sender is not the reader either')
    ok(not has_line('you → build'), 'nothing here was sent from this editor')
    cleanup()
  end)

  it('sends a typed steer to the running build', function()
    local _, path = sandbox()
    open_on(path)
    big.state().session = running_detached()
    big.steer('also add a --help flag')
    local steer = sent('big.steer')
    ok(steer ~= nil)
    eq('also add a --help flag', steer.params.text)
    eq('abc123', steer.params.sessionId)
    cleanup()
  end)

  it('refuses to open the steer box when nothing is running outside the editor', function()
    local _, path = sandbox()
    open_on(path)
    big.state().session = session({ display = 'reviewing' })
    big.open_steer()
    eq(nil, require('nvime.compose').current(), 'no float, and no request')
    eq(nil, sent('big.steer'))
    cleanup()
  end)

  it('opens the steer box on a live build, and sends what was typed', function()
    local _, path = sandbox()
    open_on(path)
    big.state().session = running_detached()
    big.open_steer()
    local float = require('nvime.compose').current()
    ok(float ~= nil, 'the compose float is open')
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, { 'prefer the existing helper' })
    vim.api.nvim_set_current_win(float.win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false)
    eq('prefer the existing helper', sent('big.steer').params.text)
    cleanup()
  end)

  it('stops a build it is only attached to, through the same key that stops its own', function()
    local _, path = sandbox()
    open_on(path)
    fake.replies['big.open'] = { result = { session = running_detached() } }
    big.select('abc123')
    local id = big.state().attach_id
    fake.replies['big.cancel'] = { result = { cancelled = true } }
    big.cancel()
    eq(id, sent('big.cancel').params.target, 'the attach is what gets stopped')
    cleanup()
  end)

  it('lets go of the stream when the panel closes, without stopping the build', function()
    local _, path = sandbox()
    open_on(path)
    fake.replies['big.open'] = { result = { session = running_detached() } }
    big.select('abc123')
    local id = big.state().attach_id
    panel.close('big')
    eq(id, sent('big.detach').params.target)
    eq(nil, sent('big.cancel'), 'closing a window never stops a build')
    cleanup()
  end)
end)

package.loaded['nvime.agent'] = real_agent
package.loaded['nvime.big'] = nil
package.loaded['nvime.threads'] = nil
