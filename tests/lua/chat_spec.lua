local t = require('harness')
local config = require('nvime.config')
local palette = require('nvime.palette')
local panel = require('nvime.panel')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Stands in for the sidecar: records every request and hands back canned
--- replies, so the chat wiring is exercised without a process or a login.
local fake = { requests = {}, replies = {}, deferred = {}, subscriber = nil }

function fake.request(method, params, cb, opts)
  fake.requests[#fake.requests + 1] = { method = method, params = params, opts = opts }
  if opts ~= nil and opts.on_sent ~= nil then
    opts.on_sent(#fake.requests)
  end
  local reply = fake.replies[method]
  if reply ~= nil and reply.defer then
    -- Answered later via fake.answer, so a caller can interleave other calls
    -- in between the way a real async reply would.
    fake.deferred[method] = fake.deferred[method] or {}
    table.insert(fake.deferred[method], cb)
    return
  end
  if reply ~= nil then
    cb(reply.err, reply.result)
  end
end

--- Answers the oldest deferred call to `method`, simulating a reply that
--- lands on its own tick instead of synchronously with the request.
function fake.answer(method, err, result)
  local queue = fake.deferred[method]
  if queue == nil or #queue == 0 then
    error('no deferred ' .. method .. ' call to answer', 2)
  end
  local cb = table.remove(queue, 1)
  cb(err, result)
end

function fake.on_event(fn)
  fake.subscriber = fn
  return function() end
end

local real_agent = require('nvime.agent')
package.loaded['nvime.agent'] = {
  request = fake.request,
  on_event = fake.on_event,
  is_running = function()
    return true
  end,
}
package.loaded['nvime.chat'] = nil
local chat = require('nvime.chat')

--- A project root: `project_root` looks for `.git`, else it falls back to cwd.
local function sandbox()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir .. '/.git', 'p')
  vim.fn.writefile({ 'local a = 1' }, dir .. '/a.lua')
  return dir
end

--- Opens chat with `dir/a.lua` as the current buffer and a clean fake sidecar.
local function open_on(dir)
  panel.close('chat')
  fake.requests = {}
  fake.deferred = {}
  fake.replies = { ['chat.list'] = { err = nil, result = { current = nil, sessions = {} } } }
  local live = chat.state()
  live.request_id, live.session_id, live.root, live.pending_send = nil, nil, nil, nil
  live.restored = false
  config.setup({})
  palette.apply()
  vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/a.lua'))
  chat.open()
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
  return vim.api.nvim_buf_get_lines(panel.get('chat').buf, 0, -1, false)
end

--- Runs `fn` from a cwd that is not the project, the case finding 1 lived in.
local function from_elsewhere(fn)
  local before = vim.uv.cwd()
  vim.cmd('cd /')
  local okay, err = pcall(fn)
  vim.cmd('cd ' .. vim.fn.fnameescape(before))
  if not okay then
    error(err, 0)
  end
end

describe('chat.open', function()
  it('captures the project root from the buffer the user was in', function()
    local dir = sandbox()
    from_elsewhere(function()
      open_on(dir)
      eq(dir, chat.state().root)
      eq(nil, sent('chat.list'), 'opening starts fresh instead of silently resuming history')
      ok(table.concat(scrollback(), '\n'):find('new conversation', 1, true) ~= nil, 'the fresh state is explicit')
    end)
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('keeps the root when reopened from inside the panel', function()
    local dir = sandbox()
    from_elsewhere(function()
      open_on(dir)
      -- `<leader>nc` from the prompt buffer: `nvime://prompt` is not a real
      -- path, so recomputing here would silently re-root the session on the cwd.
      chat.open()
      eq(dir, chat.state().root)
      local lists = vim.tbl_filter(function(request)
        return request.method == 'chat.list'
      end, fake.requests)
      eq(0, #lists, 'and reopening does not implicitly restore a session')
    end)
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('chat.send', function()
  it('resolves a relative @path against the project root, not the editor cwd', function()
    local dir = sandbox()
    from_elsewhere(function()
      open_on(dir)
      chat.send('explain @a.lua')
      local request = sent('chat.send')
      ok(request ~= nil, 'the turn was sent')
      eq(dir, request.params.root)
      eq(1, #request.params.context, 'the referenced file is attached')
      eq(dir .. '/a.lua', request.params.context[1].path)
      ok(request.opts.no_deadline, 'a streaming turn carries no deadline')
    end)
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('warns in the panel when a reference does not resolve', function()
    local dir = sandbox()
    open_on(dir)
    chat.send('explain @nope.lua')
    ok(
      vim.iter(scrollback()):any(function(line)
        return line:find('did not resolve') ~= nil
      end),
      'the warning reaches the scrollback'
    )
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('refuses a second turn while one is running', function()
    local dir = sandbox()
    open_on(dir)
    chat.send('first')
    chat.send('second')
    eq(1, #vim.tbl_filter(function(request)
      return request.method == 'chat.send'
    end, fake.requests))
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it("threads the chat lane's model dial into chat.send", function()
    local dir = sandbox()
    local models = require('nvime.models')
    open_on(dir)
    models.set('chat', 'claude-opus-5', 'high')
    chat.send('hello')
    local request = sent('chat.send')
    eq('claude-opus-5', request.params.model)
    eq('high', request.params.effort)
    models.reset('chat')
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('sends no model or effort when the dial is at the CLI default', function()
    local dir = sandbox()
    local models = require('nvime.models')
    models.reset('chat')
    open_on(dir)
    chat.send('hello')
    local request = sent('chat.send')
    eq(nil, request.params.model)
    eq(nil, request.params.effort)
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('resuming conversations', function()
  it('defers a send until explicitly selected history is fully written', function()
    local dir = sandbox()
    from_elsewhere(function()
      open_on(dir)
      fake.replies['chat.list'] = {
        err = nil,
        result = {
          current = 'sess-1',
          sessions = { { sessionId = 'sess-1', title = 'earlier question', lastModified = 0 } },
        },
      }
      fake.replies['chat.history'] = { defer = true }
      chat.pick_session()
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, true, true), 'x', false)

      chat.send('explain this')
      eq(nil, sent('chat.send'), 'the send must wait for restore, not race it')

      fake.answer('chat.history', nil, { turns = { { role = 'user', text = 'earlier question' } } })
      local request = sent('chat.send')
      ok(request ~= nil, 'the deferred send is replayed once restore finishes')
      eq('sess-1', request.params.sessionId, 'and resumes the session restore found, not a new one')

      -- The history's own turns legitimately contain a "you" line too, so look
      -- for the new turn's marker specifically: the first "you" after "resumed".
      local rendered = scrollback()
      local resumed_row, new_turn_row = nil, nil
      for i, line in ipairs(rendered) do
        if line == '— resumed —' then
          resumed_row = i
        elseif resumed_row ~= nil and line == 'you' and new_turn_row == nil then
          new_turn_row = i
        end
      end
      ok(resumed_row ~= nil, 'the resumed transcript was rendered')
      ok(new_turn_row ~= nil, 'the new turn was rendered')
      ok(resumed_row < new_turn_row, 'the resumed transcript lands before the new turn, never spliced into it')
    end)
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('starts a clean conversation without deleting resumable history', function()
    local dir = sandbox()
    open_on(dir)
    local live = chat.state()
    live.session_id = 'sess-old'
    panel.get('chat'):append('old transcript')
    chat.new_session()
    eq(nil, live.session_id)
    ok(table.concat(scrollback(), '\n'):find('old transcript', 1, true) == nil, 'the old transcript leaves the surface')
    eq(nil, sent('chat.list'), 'history is retained server-side and remains available through resume')
    chat.send('hello')
    eq(nil, sent('chat.send').params.sessionId, 'the next turn creates a new sidecar session')
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('does not abandon a running turn to start another conversation', function()
    local dir = sandbox()
    open_on(dir)
    chat.send('keep working')
    local live = chat.state()
    live.session_id = 'sess-live'
    chat.new_session()
    eq('sess-live', live.session_id)
    ok(live.request_id ~= nil, 'the active request remains owned and cancellable')
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('chat events', function()
  it('renders only the events belonging to the running turn', function()
    local dir = sandbox()
    open_on(dir)
    chat.send('hello')
    local id = chat.state().request_id
    ok(id ~= nil, 'the request id was captured')

    fake.subscriber('chat.delta', { id = id, text = 'mine' })
    fake.subscriber('chat.delta', { id = id + 99, text = 'someone else' })
    local rendered = table.concat(scrollback(), '\n')
    ok(rendered:find('mine', 1, true) ~= nil, 'the running turn streams')
    ok(rendered:find('someone else', 1, true) == nil, 'a stale id must not')
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('shows a sidecar error without ending the turn', function()
    local dir = sandbox()
    open_on(dir)
    chat.send('hello')
    fake.subscriber('rpc.error', { error = { code = 'bad_request', message = 'nope' } })
    ok(
      vim.iter(scrollback()):any(function(line)
        return line:find('nope', 1, true) ~= nil
      end),
      'the failure is rendered, not swallowed'
    )
    ok(chat.state().request_id ~= nil, 'and an unrelated failure does not truncate the stream')
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('closing the panel', function()
  it('stops the turn nobody will read', function()
    local dir = sandbox()
    open_on(dir)
    chat.send('a long one')
    local id = chat.state().request_id
    ok(id ~= nil)

    panel.close('chat')
    local cancel = sent('chat.cancel')
    ok(cancel ~= nil, 'the subscription pays for a turn nobody sees')
    eq(id, cancel.params.target)
    vim.fn.delete(dir, 'rf')
  end)

  it('says nothing when there is no turn running', function()
    local dir = sandbox()
    open_on(dir)
    panel.close('chat')
    eq(nil, sent('chat.cancel'))
    vim.fn.delete(dir, 'rf')
  end)
end)

-- `chat.lua` captured the stub when it was required; every later spec gets the
-- real module back.
package.loaded['nvime.agent'] = real_agent
