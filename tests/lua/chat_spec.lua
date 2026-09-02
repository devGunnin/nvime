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

--- What the prompt box currently holds.
local function prompt_text()
  local live = panel.get('chat')
  return table.concat(vim.api.nvim_buf_get_lines(live.prompt_buf, 0, -1, false), '\n')
end

--- Runs `fn` with vim.notify captured, and returns everything it said.
local function capture_notices(fn)
  local said = {}
  local real = vim.notify
  vim.notify = function(message)
    said[#said + 1] = message
  end
  local okay, err = pcall(fn)
  vim.notify = real
  if not okay then
    error(err, 0)
  end
  return table.concat(said, '\n')
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
      -- Row 1 is the picker's own "new conversation" entry; row 2 is sess-1.
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
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

  it('tells the sidecar new:true, so it cannot fall back to a session on record', function()
    -- issue #11: a nil sessionId alone is not "start fresh" — the sidecar
    -- reads an absent one as "resume whatever this project last used" unless
    -- told otherwise. `open_on` already leaves the panel in the fresh state.
    local dir = sandbox()
    open_on(dir)
    chat.send('hello')
    local request = sent('chat.send')
    eq(nil, request.params.sessionId)
    eq(true, request.params.new, 'a fresh conversation must refuse the stored-session fallback')
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('stops asking for new:true once the fresh conversation has a session id', function()
    local dir = sandbox()
    open_on(dir)
    fake.replies['chat.send'] = { err = nil, result = { sessionId = 'sess-new', usage = { output = 1 }, costUsd = 0 } }
    chat.send('hello')
    eq(true, sent('chat.send').params.new)

    fake.requests = {}
    chat.send('carry on')
    local second = sent('chat.send')
    eq('sess-new', second.params.sessionId, 'the second turn continues the session the first one opened')
    eq(false, second.params.new)
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

--- Opens chat under `chat.default = 'resume-last'`, otherwise like `open_on`.
local function open_resuming(dir)
  panel.close('chat')
  fake.requests = {}
  fake.deferred = {}
  local live = chat.state()
  live.request_id, live.session_id, live.root, live.pending_send = nil, nil, nil, nil
  config.setup({ chat = { default = 'resume-last' } })
  palette.apply()
  vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/a.lua'))
  chat.open()
end

describe("chat.default = 'resume-last'", function()
  it('resumes this project’s last conversation on open instead of starting fresh', function()
    local dir = sandbox()
    fake.replies['chat.list'] = {
      err = nil,
      result = { current = 'sess-1', sessions = { { sessionId = 'sess-1', title = 'earlier', lastModified = 0 } } },
    }
    fake.replies['chat.history'] = { err = nil, result = { turns = { { role = 'user', text = 'earlier' } } } }
    open_resuming(dir)
    ok(sent('chat.list') ~= nil, 'resume-last looks up the stored session on open')
    ok(table.concat(scrollback(), '\n'):find('— resumed —', 1, true) ~= nil, 'the stored conversation is replayed')
    eq('sess-1', chat.state().session_id)
    eq(false, chat.state().explicit_new, 'a resumed session must not ask the sidecar for a fresh one')
    panel.close('chat')
    config.setup({})
    vim.fn.delete(dir, 'rf')
  end)

  it('falls back to a fresh start when this project has no stored session', function()
    local dir = sandbox()
    fake.replies['chat.list'] = { err = nil, result = { current = nil, sessions = {} } }
    open_resuming(dir)
    ok(table.concat(scrollback(), '\n'):find('new conversation', 1, true) ~= nil)
    eq(nil, chat.state().session_id)
    chat.send('hello')
    eq(true, sent('chat.send').params.new)
    panel.close('chat')
    config.setup({})
    vim.fn.delete(dir, 'rf')
  end)

  it('queues a send that lands while the lookup is still in flight, on a reopened panel', function()
    local dir = sandbox()
    fake.replies['chat.list'] = { defer = true }
    fake.replies['chat.history'] = { defer = true }
    open_resuming(dir)
    fake.answer('chat.list', nil, { current = 'sess-1', sessions = {} })
    fake.answer('chat.history', nil, { turns = {} })

    -- <C-n> leaves explicit_new/restored set; `state` outlives the panel, so a
    -- reopen that does not reset them sends on the previous panel's flags.
    chat.new_session()
    panel.close('chat')
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/a.lua'))
    fake.requests = {}
    -- The one path that opens and sends in a single tick: no race to win.
    chat.send_selection()
    eq(nil, sent('chat.send'), 'nothing may go out while the stored session is still unknown')

    fake.answer('chat.list', nil, { current = 'sess-1', sessions = {} })
    fake.answer('chat.history', nil, { turns = {} })
    local send = sent('chat.send')
    ok(send ~= nil, 'the queued prompt is replayed once the restore lands')
    eq('sess-1', send.params.sessionId)
    eq(false, send.params.new, 'the replayed prompt must not fork a brand-new conversation')
    panel.close('chat')
    config.setup({})
    fake.replies['chat.history'] = nil
    vim.fn.delete(dir, 'rf')
  end)

  it('surfaces a failed lookup instead of silently starting fresh', function()
    local dir = sandbox()
    fake.replies['chat.list'] = { err = { message = 'sidecar exploded' }, result = nil }
    open_resuming(dir)
    local rendered = table.concat(scrollback(), '\n')
    ok(rendered:find('sidecar exploded', 1, true) ~= nil, 'the user opted into resuming and must hear it failed')
    ok(rendered:find('new conversation', 1, true) ~= nil, 'and is left in a usable, explicitly fresh state')
    eq(true, chat.state().explicit_new)
    chat.send('hello')
    eq(true, sent('chat.send').params.new, 'a failed lookup must not leave the send guessing at a session')
    panel.close('chat')
    config.setup({})
    vim.fn.delete(dir, 'rf')
  end)
end)

local GAP_PROMPT = 'what did we decide yesterday?'

describe('a prompt queued while a restore is still in flight', function()
  --- Opens under `resume-last` with the lookup still unanswered, and sends a
  --- prompt into that gap. It is queued for the session being restored.
  local function send_in_the_gap(dir)
    fake.replies['chat.list'] = { defer = true }
    fake.replies['chat.history'] = { defer = true }
    open_resuming(dir)
    chat.send(GAP_PROMPT)
    eq(nil, sent('chat.send'), 'a send during the restore gap is queued, not delivered')
  end

  local function cleanup(dir)
    panel.close('chat')
    config.setup({})
    fake.replies['chat.history'] = nil
    fake.replies['chat.list'] = nil
    vim.fn.delete(dir, 'rf')
  end

  it('is handed back unsent when the user resumes a different conversation', function()
    local dir = sandbox()
    send_in_the_gap(dir)
    fake.replies['chat.list'] = {
      err = nil,
      result = { current = 'sess-A', sessions = { { sessionId = 'sess-B', title = 'other', lastModified = 0 } } },
    }
    chat.pick_session()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, true, true), 'x', false)
    eq('sess-B', chat.state().session_id, 'the picked session is now live')
    fake.answer('chat.history', nil, { turns = {} })
    eq(nil, sent('chat.send'), 'a prompt is never sent to a conversation the user did not address it to')
    eq(GAP_PROMPT, prompt_text(), 'the words come back to the prompt box')
    cleanup(dir)
  end)

  it('is handed back unsent when <C-n> starts a fresh conversation instead', function()
    local dir = sandbox()
    send_in_the_gap(dir)
    chat.new_session()
    eq(nil, sent('chat.send'), 'the queued prompt was written for the session being restored')
    eq(GAP_PROMPT, prompt_text(), '<C-n> must not destroy what the user typed')
    cleanup(dir)
  end)

  it('is dropped with a notice, never billed, when the panel is gone', function()
    local dir = sandbox()
    send_in_the_gap(dir)
    local said = capture_notices(function()
      panel.close('chat')
    end)
    ok(said:find(GAP_PROMPT, 1, true) ~= nil, 'a prompt with nowhere to go is given back as a notice')
    fake.answer('chat.list', nil, { current = 'sess-1', sessions = {} })
    fake.answer('chat.history', nil, { turns = {} })
    eq(nil, sent('chat.send'), 'a closed panel must not bill a turn nobody can read')
    cleanup(dir)
  end)
end)

describe('a turn that finishes on a panel that has moved on', function()
  it('does not name the conversation of a panel closed and reopened since', function()
    local dir = sandbox()
    open_on(dir)
    fake.replies['chat.send'] = { defer = true }
    chat.send('hello')
    ok(chat.state().request_id ~= nil, 'the turn is in flight')

    panel.close('chat')
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/a.lua'))
    chat.open()
    eq(nil, chat.state().session_id, 'the reopened panel is explicitly a new conversation')

    fake.answer('chat.send', nil, { sessionId = 'sess-OLD', usage = { output = 1 }, costUsd = 0 })
    eq(nil, chat.state().session_id, 'the old turn must not silently resume itself on the new panel')
    eq(true, chat.state().explicit_new)
    panel.close('chat')
    fake.replies['chat.send'] = nil
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('deleting a conversation while a turn is running', function()
  it('refuses to delete the live one, and leaves its picker row usable', function()
    local dir = sandbox()
    open_on(dir)
    local live = chat.state()
    live.session_id, live.explicit_new = 'sess-1', false
    fake.replies['chat.list'] = {
      err = nil,
      result = { current = 'sess-1', sessions = { { sessionId = 'sess-1', title = 'earlier', lastModified = 0 } } },
    }
    fake.replies['chat.forget'] = { err = nil, result = { forgotten = true } }
    chat.pick_session()
    -- The turn was started from the prompt while the picker sat open.
    fake.replies['chat.send'] = { defer = true }
    live.request_id = 99

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local said = capture_notices(function()
      vim.api.nvim_feedkeys('d', 'x', false)
      vim.api.nvim_feedkeys('y', 'x', false)
    end)
    eq(nil, sent('chat.forget'), 'the live conversation is not deleted out from under its own stream')
    ok(said:find('stop the running turn', 1, true) ~= nil, 'and the user is told why')
    eq('sess-1', live.session_id, 'the panel keeps the conversation it is still streaming into')
    live.request_id = nil
    panel.close('chat')
    fake.replies['chat.send'] = nil
    vim.fn.delete(dir, 'rf')
  end)

  it('never lets the finishing turn reinstate a conversation deleted meanwhile', function()
    local dir = sandbox()
    open_on(dir)
    local live = chat.state()
    fake.replies['chat.list'] = {
      err = nil,
      result = { current = nil, sessions = { { sessionId = 'sess-1', title = 'earlier', lastModified = 0 } } },
    }
    fake.replies['chat.forget'] = { err = nil, result = { forgotten = true } }
    chat.pick_session()
    -- A fresh conversation's turn: it has no id yet, so deleting `sess-1` is
    -- not deleting the live one and the guard above does not apply.
    fake.replies['chat.send'] = { defer = true }
    chat.send('hello')
    eq(nil, live.session_id)

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys('d', 'x', false)
    vim.api.nvim_feedkeys('y', 'x', false)
    ok(sent('chat.forget') ~= nil, 'the delete goes through')

    fake.answer('chat.send', nil, { sessionId = 'sess-1', usage = { output = 1 }, costUsd = 0 })
    eq(nil, live.session_id, 'the finished turn must not resurrect the conversation just deleted')
    eq(true, live.explicit_new, 'and the next send must not try to resume it')
    panel.close('chat')
    fake.replies['chat.send'] = nil
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('chat.pick_session: the new-conversation row and delete', function()
  it('starts fresh from the picker’s top row instead of only listing past sessions', function()
    local dir = sandbox()
    open_on(dir)
    fake.replies['chat.list'] = {
      err = nil,
      result = { current = 'sess-1', sessions = { { sessionId = 'sess-1', title = 'earlier', lastModified = 0 } } },
    }
    local live = chat.state()
    live.session_id = 'sess-1'
    chat.pick_session()
    -- Row 1 is the picker's own "new conversation" entry.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, true, true), 'x', false)
    eq(nil, live.session_id, 'the top row started a clean conversation')
    eq(nil, sent('chat.history'), 'picking "new conversation" never resumes an existing one')
    ok(table.concat(scrollback(), '\n'):find('new conversation', 1, true) ~= nil)
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('deletes a session through chat.forget, after the picker’s own confirm', function()
    local dir = sandbox()
    open_on(dir)
    fake.replies['chat.list'] = {
      err = nil,
      result = { current = nil, sessions = { { sessionId = 'sess-1', title = 'earlier', lastModified = 0 } } },
    }
    fake.replies['chat.forget'] = { err = nil, result = { forgotten = true } }
    chat.pick_session()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys('d', 'x', false)
    vim.api.nvim_feedkeys('y', 'x', false)
    local request = sent('chat.forget')
    ok(request ~= nil, 'd, then y, deletes the session under the cursor')
    eq('sess-1', request.params.sessionId)
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('drops back to fresh when the session deleted is the one live in the panel', function()
    local dir = sandbox()
    open_on(dir)
    local live = chat.state()
    live.session_id = 'sess-1'
    live.explicit_new = false
    fake.replies['chat.list'] = {
      err = nil,
      result = { current = 'sess-1', sessions = { { sessionId = 'sess-1', title = 'earlier', lastModified = 0 } } },
    }
    fake.replies['chat.forget'] = { err = nil, result = { forgotten = true } }
    chat.pick_session()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys('d', 'x', false)
    vim.api.nvim_feedkeys('y', 'x', false)
    eq(nil, live.session_id, 'the panel drops the id of the conversation it just deleted')
    eq(true, live.explicit_new, 'the next send must not try to resume what no longer exists')
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('clears the deleted conversation off the panel and drops its in-flight restore', function()
    local dir = sandbox()
    open_on(dir)
    local one = { { sessionId = 'sess-1', title = 'earlier', lastModified = 0 } }
    fake.replies['chat.list'] = { err = nil, result = { current = 'sess-1', sessions = one } }
    fake.replies['chat.history'] = { defer = true }
    fake.replies['chat.forget'] = { err = nil, result = { forgotten = true } }

    chat.pick_session()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, true, true), 'x', false)
    eq('sess-1', chat.state().session_id, 'the session is live, its history still loading')

    chat.pick_session()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_feedkeys('d', 'x', false)
    vim.api.nvim_feedkeys('y', 'x', false)
    local after_delete = table.concat(scrollback(), '\n')
    ok(after_delete:find('that conversation was deleted', 1, true) ~= nil)
    ok(after_delete:find('new conversation', 1, true) ~= nil, 'the panel says how to start again')
    ok(after_delete:find('switched to', 1, true) == nil, 'the dead conversation is off the surface')

    fake.answer('chat.history', nil, { turns = { { role = 'user', text = 'ghost turn' } } })
    local settled = table.concat(scrollback(), '\n')
    ok(settled:find('ghost turn', 1, true) == nil, 'a deleted transcript must not replay after its own notice')
    ok(settled:find('— resumed —', 1, true) == nil)
    panel.close('chat')
    fake.replies['chat.history'] = nil
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

--- The reply the sidecar hands back when the model offered a choice.
local function done_with_options(block)
  return {
    err = nil,
    result = {
      sessionId = 's1',
      usage = { output = 1 },
      costUsd = 0,
      options = block,
    },
  }
end

local function two_choices()
  return { prompt = 'which retry?', options = { { label = 'fixed backoff' }, { label = 'exponential' } } }
end

describe('chat: a choice offered in the conversation', function()
  it('renders the choice under the reply and answers it on a digit', function()
    local dir = sandbox()
    open_on(dir)
    fake.replies['chat.send'] = done_with_options(two_choices())
    chat.send('how should retries work?')

    local rendered = scrollback()
    ok(vim.tbl_contains(rendered, '  1  fixed backoff'), vim.inspect(rendered))
    ok(chat.state().offer ~= nil, 'the choice is live until it is answered')

    fake.requests = {}
    fake.replies['chat.send'] = done_with_options(nil)
    vim.api.nvim_set_current_win(panel.get('chat').win)
    vim.api.nvim_feedkeys('2', 'x', false)
    eq('2: exponential', sent('chat.send').params.prompt)
    ok(vim.tbl_contains(scrollback(), '→ 2: exponential'), 'the pick reads back as the reply it was')
    eq(nil, chat.state().offer, 'answering retires the choice')
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('reads a typed number as the pick it plainly is', function()
    local dir = sandbox()
    open_on(dir)
    fake.replies['chat.send'] = done_with_options(two_choices())
    chat.send('how should retries work?')
    fake.requests = {}
    chat.send('1')
    eq('1: fixed backoff', sent('chat.send').params.prompt)
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  it('sends anything else as the reader’s own words, and retires the choice', function()
    local dir = sandbox()
    open_on(dir)
    fake.replies['chat.send'] = done_with_options(two_choices())
    chat.send('how should retries work?')
    fake.requests = {}
    fake.replies['chat.send'] = done_with_options(nil)
    chat.send('neither — just fail loudly')
    eq('neither — just fail loudly', sent('chat.send').params.prompt)
    eq(nil, chat.state().offer)
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  --- `M.offer` retires whatever was open before attaching a new block, so a
  --- caller cannot leave a stale handle's spare keys bound no matter how it
  --- got there — not just on the one path (`M.send`) that happens to retire
  --- first today.
  it('retires a still-open choice before offering a new one, so its stray keys go dead', function()
    local dir = sandbox()
    open_on(dir)
    local function block(count)
      local options = {}
      for index = 1, count do
        options[index] = { label = 'choice ' .. index }
      end
      return { options = options }
    end

    chat.offer(block(9))
    vim.api.nvim_set_current_win(panel.get('chat').win)
    ok(vim.fn.maparg('9', 'n') ~= '', 'the first block bound all nine digits')

    chat.offer(block(2))
    ok(vim.fn.maparg('9', 'n') == '', 'the retired block gives its spare digit back')
    ok(vim.fn.maparg('2', 'n') ~= '', 'the new block is live')
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  --- <CR> used to answer (or swallow) from anywhere in the scrollback for a
  --- multi-select question; now it is scoped like the digits, and `]o` is the
  --- reader's way back onto the block from wherever they scrolled to.
  it('scopes <CR> to the block, and lets ]o jump onto it from anywhere', function()
    local dir = sandbox()
    open_on(dir)
    fake.replies['chat.send'] = done_with_options({
      prompt = 'which retries?',
      multi = true,
      options = { { label = 'fixed backoff' }, { label = 'exponential' } },
    })
    chat.send('how should retries work?')

    local win = panel.get('chat').win
    vim.api.nvim_set_current_win(win)
    vim.api.nvim_win_set_cursor(win, { 1, 0 })

    vim.api.nvim_feedkeys('\r', 'x', false)
    ok(chat.state().offer ~= nil, '<CR> far from the block must not have answered it')
    eq(2, vim.api.nvim_win_get_cursor(win)[1], '<CR> must still move the cursor down a line')

    chat.jump_to_offer()
    vim.api.nvim_feedkeys('1', 'x', false)
    fake.requests = {}
    fake.replies['chat.send'] = done_with_options(nil)
    vim.api.nvim_feedkeys('\r', 'x', false)
    eq('1: fixed backoff', sent('chat.send').params.prompt, '<CR> answers once ]o put the cursor on the block')
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)

  --- The block crosses a process boundary. An unusable one is not a choice —
  --- the prose question is already in the transcript and still gets answered.
  it('offers nothing when the sidecar sent no usable block', function()
    local dir = sandbox()
    open_on(dir)
    for _, bad in ipairs({ vim.NIL, {}, { options = { { label = 'only' } } } }) do
      fake.replies['chat.send'] = done_with_options(bad ~= vim.NIL and bad or nil)
      chat.send('ask me something')
      eq(nil, chat.state().offer, vim.inspect(bad))
    end
    panel.close('chat')
    vim.fn.delete(dir, 'rf')
  end)
end)

-- `chat.lua` captured the stub when it was required; every later spec gets the
-- real module back.
package.loaded['nvime.agent'] = real_agent
