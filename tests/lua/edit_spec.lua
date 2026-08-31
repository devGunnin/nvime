local t = require('harness')
local apply = require('nvime.apply')
local approval = require('nvime.approval')
local config = require('nvime.config')
local palette = require('nvime.palette')
local panel = require('nvime.panel')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Stands in for the sidecar: records requests, replies from a canned table.
local fake = { requests = {}, replies = {}, subscriber = nil }

function fake.request(method, params, cb, opts)
  fake.requests[#fake.requests + 1] = { method = method, params = params, opts = opts }
  if opts ~= nil and opts.on_sent ~= nil then
    opts.on_sent(#fake.requests)
  end
  local reply = fake.replies[method]
  if reply ~= nil then
    cb(reply.err, reply.result)
  end
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
package.loaded['nvime.edit'] = nil
local edit = require('nvime.edit')

local dirs = {}

--- A project with a real file, opened in a real buffer.
local function sandbox(text)
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir .. '/.git', 'p')
  dirs[#dirs + 1] = dir
  local path = dir .. '/queue.py'
  local handle = assert(io.open(path, 'wb'))
  handle:write(text or 'def drain():\n    pass\n')
  handle:close()
  return dir, path
end

local function cleanup()
  panel.close('edit')
  approval.dismiss_all()
  for _, dir in ipairs(dirs) do
    vim.fn.delete(dir, 'rf')
  end
  dirs = {}
end

local function open_on(path)
  panel.close('edit')
  fake.requests = {}
  fake.replies = {}
  local live = edit.state()
  live.request_id, live.session_id, live.run_id, live.root, live.scope = nil, nil, nil, nil, nil
  config.setup({ edit = { nofade = true } })
  palette.apply()
  apply.reset()
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  edit.instruct()
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
  return vim.api.nvim_buf_get_lines(panel.get('edit').buf, 0, -1, false)
end

local function has_line(pattern)
  return vim.iter(scrollback()):any(function(line)
    return line:find(pattern, 1, true) ~= nil
  end)
end

--- The agent's half: writes the file, then pushes the recorded mutation.
local function agent_edits(path, before, after)
  local handle = assert(io.open(path, 'wb'))
  handle:write(after)
  handle:close()
  fake.subscriber('edit.applied', {
    id = edit.state().request_id,
    runId = 'r1',
    index = 0,
    path = path,
    tool = 'Edit',
    before = { kind = 'text', text = before },
    after = { kind = 'text', text = after },
  })
end

describe('edit.instruct', function()
  it('scopes the next instruction to the file in the current buffer', function()
    local dir, path = sandbox()
    open_on(path)
    eq(dir, edit.state().root, 'the run is rooted at the project, not the cwd')
    eq({ kind = 'file', path = path }, edit.state().scope)
    cleanup()
  end)

  it('sends the scope with the instruction, then falls back for follow-ups', function()
    local dir, path = sandbox()
    open_on(path)
    edit.send('add a lock')
    local request = sent('edit.start')
    ok(request ~= nil)
    eq(dir, request.params.root)
    eq({ kind = 'file', path = path }, request.params.scope)
    ok(request.opts.no_deadline, 'a run is bounded by <C-c>, not a timer')

    edit.state().request_id = nil
    edit.send('now the other one')
    local follow_up = fake.requests[#fake.requests]
    eq('edit.start', follow_up.method)
    eq({ kind = 'project' }, follow_up.params.scope, 'a follow-up rides the session, not the old scope')
    cleanup()
  end)

  it('refuses a second run while one is going', function()
    local _, path = sandbox()
    open_on(path)
    edit.send('first')
    edit.send('second')
    local starts = vim.tbl_filter(function(request)
      return request.method == 'edit.start'
    end, fake.requests)
    eq(1, #starts)
    cleanup()
  end)
end)

describe('edit: live application', function()
  it('applies a pushed mutation to the open buffer and says so', function()
    local _, path = sandbox()
    open_on(path)
    edit.send('add a lock')
    vim.cmd('wincmd p')
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()

    agent_edits(path, 'def drain():\n    pass\n', 'def drain():\n    lock()\n')
    eq({ 'def drain():', '    lock()' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    eq(false, vim.bo[buf].modified, 'no reload, no unsaved state')
    ok(has_line('updated queue.py'), 'and the panel names the file')
    cleanup()
  end)

  it('leaves a modified buffer alone and reports the conflict', function()
    local _, path = sandbox()
    open_on(path)
    edit.send('add a lock')
    vim.cmd('wincmd p')
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { '    mine' })

    agent_edits(path, 'def drain():\n    pass\n', 'def drain():\n    lock()\n')
    eq({ 'def drain():', '    mine' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    ok(has_line('has unsaved edits'), 'and the panel says the hunk was left unapplied')
    eq(1, edit.state().tally.conflicts)
    cleanup()
  end)

  it('does not blame the user when a shell step, not they, changed the file', function()
    local _, path = sandbox()
    open_on(path)
    edit.send('reformat it')
    vim.cmd('wincmd p')
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()

    -- An approved `prettier --write`: nvime has no before/after for it.
    local handle = assert(io.open(path, 'wb'))
    handle:write('def drain():\n    formatted()\n')
    handle:close()
    fake.subscriber('edit.external_change', {
      id = edit.state().request_id,
      runId = 'r1',
      root = edit.state().root,
      reason = 'a shell command ran; nvime did not record what it changed',
    })

    eq({ 'def drain():', '    formatted()' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    ok(has_line('reloaded queue.py'), 'and the panel says so, naming it as unrecorded')
    ok(has_line('not in the changeset'))

    -- The next recorded edit now starts from what the buffer really holds.
    agent_edits(path, 'def drain():\n    formatted()\n', 'def drain():\n    lock()\n')
    ok(has_line('updated queue.py'), 'no phantom conflict blaming unsaved edits')
    ok(not has_line('has unsaved edits'))
    cleanup()
  end)

  it('tells the user when a shell step deleted a file they have open', function()
    local _, path = sandbox()
    open_on(path)
    edit.send('clean the build')
    vim.cmd('wincmd p')
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    eq(0, vim.fn.delete(path))

    fake.subscriber('edit.external_change', {
      id = edit.state().request_id,
      runId = 'r1',
      root = edit.state().root,
      reason = 'a shell command ran; nvime did not record what it changed',
    })
    ok(has_line('queue.py'), 'the panel names the file')
    ok(has_line('gone from disk'), 'and says what happened to it')
    eq({ 'def drain():', '    pass' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'the buffer is untouched')
    vim.cmd('silent! bwipeout! ' .. buf)
    cleanup()
  end)

  it('reports a file no buffer holds instead of silently doing nothing', function()
    local _, path = sandbox()
    open_on(path)
    vim.cmd('silent! bwipeout! ' .. vim.fn.bufnr(path))
    edit.send('add a lock')
    agent_edits(path, 'def drain():\n    pass\n', 'def drain():\n    lock()\n')
    ok(has_line('changed on disk'), 'the panel still tells the user it changed')
    cleanup()
  end)

  it('ignores events belonging to another request', function()
    local _, path = sandbox()
    open_on(path)
    edit.send('go')
    fake.subscriber('edit.delta', { id = edit.state().request_id, text = 'mine' })
    fake.subscriber('edit.delta', { id = edit.state().request_id + 99, text = 'someone else' })
    local rendered = table.concat(scrollback(), '\n')
    ok(rendered:find('mine', 1, true) ~= nil)
    ok(rendered:find('someone else', 1, true) == nil)
    cleanup()
  end)
end)

describe('edit: approvals', function()
  it('asks in a float and sends the answer back', function()
    local _, path = sandbox()
    open_on(path)
    edit.send('go')
    fake.subscriber('edit.approval', {
      id = edit.state().request_id,
      approvalId = 'r1:t1',
      tool = 'Bash',
      summary = 'running npm test',
      reason = 'runs a shell command',
    })
    ok(approval.current() ~= nil, 'a float, never vim.fn.confirm')
    vim.api.nvim_set_current_win(approval.current().win)
    vim.cmd('normal y')

    local answer = sent('edit.answer')
    ok(answer ~= nil, 'the answer reaches the sidecar')
    eq('r1:t1', answer.params.approvalId)
    eq(true, answer.params.allow)
    cleanup()
  end)

  it('withdraws the float when the sidecar stopped waiting', function()
    local _, path = sandbox()
    open_on(path)
    edit.send('go')
    local id = edit.state().request_id
    fake.subscriber('edit.approval', { id = id, approvalId = 'r1:t1', tool = 'Bash', summary = 'x', reason = 'y' })
    fake.subscriber('edit.approval_settled', { id = id, approvalId = 'r1:t1', allowed = false })
    eq(nil, approval.current())
    eq(nil, sent('edit.answer'), 'and no answer is invented for it')
    cleanup()
  end)

  it('denies anything outstanding when the panel closes', function()
    local _, path = sandbox()
    open_on(path)
    edit.send('go')
    fake.subscriber('edit.approval', {
      id = edit.state().request_id,
      approvalId = 'r1:t1',
      tool = 'Bash',
      summary = 'x',
      reason = 'y',
    })
    panel.close('edit')
    eq(nil, approval.current())
    local answer = sent('edit.answer')
    ok(answer ~= nil)
    eq(false, answer.params.allow, 'an ask nobody can see is a denial, never an allow')
    ok(sent('edit.cancel') ~= nil, 'and the run nobody will read is stopped')
    cleanup()
  end)
end)

-- `edit.lua` captured the stub when it was required; every later spec gets the
-- real module back.
package.loaded['nvime.agent'] = real_agent
