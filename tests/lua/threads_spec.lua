local t = require('harness')
local compose = require('nvime.compose')
local palette = require('nvime.palette')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Stands in for the sidecar: records requests, replies from a canned table.
local fake = { requests = {}, replies = {} }

function fake.request(method, params, cb)
  fake.requests[#fake.requests + 1] = { method = method, params = params }
  local reply = fake.replies[method]
  if reply ~= nil then
    cb(reply.err, reply.result)
  end
end

local real_agent = require('nvime.agent')
package.loaded['nvime.agent'] = {
  request = fake.request,
  on_event = function()
    return function() end
  end,
  is_running = function()
    return true
  end,
}
package.loaded['nvime.threads'] = nil
local threads = require('nvime.threads')

local DIFF = table.concat({
  'diff --git a/pool.py b/pool.py',
  '--- a/pool.py',
  '+++ b/pool.py',
  '@@ -1,2 +1,3 @@',
  ' import time',
  '-old',
  '+new',
  'diff --git a/notes.md b/notes.md',
  '--- a/notes.md',
  '+++ b/notes.md',
  '@@ -1 +1 @@',
  '-a',
  '+b',
}, '\n')

local HUNKS = {
  { id = 'h1.1', file = 'pool.py', offset = 3, lineCount = 4 },
  { id = 'h2.1', file = 'notes.md', offset = 10, lineCount = 3 },
}

local function block(overrides)
  return vim.tbl_extend('force', {
    id = 'b1',
    title = 'jitter strategy',
    files = { 'pool.py' },
    hunkIds = { 'h1.1' },
    substantial = true,
    rationale = 'behaviour',
    state = 'open',
    reopened = false,
    signatures = { 'sig1' },
  }, overrides or {})
end

local function session(blocks)
  return {
    id = 'abc123',
    title = 'backoff',
    display = 'reviewing',
    state = 'reviewing',
    detached = false,
    hasDiff = true,
    worktree = { path = '/tmp/nvime-wt', baseCommit = 'abcdef', baseBranch = 'main' },
    counts = { total = #blocks, open = 1, substantial = 1 },
    blocks = blocks,
    conversation = {},
    transitions = {},
  }
end

local function open_review(blocks)
  threads.close()
  compose.dismiss()
  fake.requests, fake.replies = {}, {}
  palette.apply()
  fake.replies['big.diff'] = { result = { diff = { text = DIFF, hunks = HUNKS } } }
  threads.open('/tmp/project', session(blocks))
end

--- Invokes the buffer-local mapping the user would press.
local function press(buf, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.lhs == lhs and map.callback ~= nil then
      map.callback()
      return true
    end
  end
  return false
end

local function tree_text()
  return vim.api.nvim_buf_get_lines(threads.view().tree_buf, 0, -1, false)
end

local function pane_text()
  return vim.api.nvim_buf_get_lines(threads.view().pane_buf, 0, -1, false)
end

describe('review thread list', function()
  it('gives each thread the chip its state earns', function()
    local lines = threads.tree_lines({
      block(),
      block({ id = 'b2', title = 'backoff curve', state = 'resolved' }),
      block({ id = 'b3', title = 'imports', substantial = false, state = 'resolved', files = { 'a', 'b', 'c' } }),
      block({ id = 'b4', title = 'docstrings', substantial = false, state = 'open', reopened = true }),
    })
    eq('DEFEND jitter strategy', lines[1])
    eq('  ok   backoff curve', lines[2])
    eq(' auto  imports (3 files)', lines[3])
    eq(' OPEN  docstrings', lines[4])
  end)

  it('says so rather than drawing an empty list', function()
    eq({ 'nothing changed in this build.' }, threads.tree_lines({}))
  end)

  it('renders the list and the selected thread when the review opens', function()
    open_review({
      block(),
      block({
        id = 'b2',
        title = 'notes',
        substantial = false,
        state = 'resolved',
        files = { 'notes.md' },
        hunkIds = { 'h2.1' },
      }),
    })
    local lines = tree_text()
    eq(2, #lines)
    ok(lines[1]:match('DEFEND') ~= nil, lines[1])
    ok(lines[2]:match('auto') ~= nil, lines[2])
    local pane = pane_text()
    ok(
      vim.iter(pane):any(function(line)
        return line == '+new'
      end),
      'the selected thread shows its own hunk'
    )
    ok(not vim.iter(pane):any(function(line)
      return line == '+b'
    end), "and not another thread's")
    threads.close()
  end)

  it('slices each thread hunk out of the captured diff', function()
    open_review({ block({ hunkIds = { 'h1.1', 'h2.1' }, files = { 'pool.py', 'notes.md' } }) })
    local pane = pane_text()
    eq('jitter strategy', pane[1])
    eq('# behaviour', pane[2])
    eq('--- pool.py', pane[4])
    eq('@@ -1,2 +1,3 @@', pane[5])
    eq('+new', pane[8])
    eq('--- notes.md', pane[10])
    threads.close()
  end)

  it(']t and [t walk the list and follow with the pane', function()
    open_review({
      block(),
      block({ id = 'b2', title = 'notes', hunkIds = { 'h2.1' }, files = { 'notes.md' } }),
    })
    local buf = threads.view().tree_buf
    ok(press(buf, ']t'), ']t must be bound in the thread list')
    eq(2, threads.view().selected)
    ok(vim.iter(pane_text()):any(function(line)
      return line == '+b'
    end))
    press(buf, '[t')
    eq(1, threads.view().selected)
    press(buf, '[t')
    eq(1, threads.view().selected, 'the first thread is the floor, not a wrap')
    threads.close()
  end)
end)

describe('review thread actions', function()
  it('re-opens an auto-resolved thread with X', function()
    open_review({ block({ substantial = false, state = 'resolved' }) })
    fake.replies['big.toggle'] = { result = { session = session({ block({ substantial = false, state = 'open' }) }) } }
    press(threads.view().tree_buf, 'X')
    local request = fake.requests[#fake.requests]
    eq('big.toggle', request.method)
    eq('b1', request.params.blockId)
    eq(false, request.params.resolved, 'a resolved thread toggles open')
    ok(tree_text()[1]:match('OPEN') ~= nil, tree_text()[1])
    threads.close()
  end)

  it('refuses to clear a substantial thread by hand', function()
    open_review({ block() })
    press(threads.view().tree_buf, 'X')
    eq(
      nil,
      vim.iter(fake.requests):find(function(request)
        return request.method == 'big.toggle'
      end)
    )
    threads.close()
  end)

  it('sends a request for changes as a revision on that thread', function()
    open_review({ block() })
    press(threads.view().tree_buf, 'r')
    local float = compose.current()
    ok(float ~= nil, 'r opens a comment box rather than a modal prompt')
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, { 'use equal jitter here' })
    fake.replies['big.revise'] = { result = { session = session({ block({ state = 'open' }) }) } }
    fake.replies['big.diff'] = { result = { diff = { text = DIFF, hunks = HUNKS } } }
    press(float.buf, '<CR>')

    local revise = vim.iter(fake.requests):find(function(request)
      return request.method == 'big.revise'
    end)
    ok(revise ~= nil, 'the comment reaches the build agent')
    eq('b1', revise.params.blockId)
    eq('use equal jitter here', revise.params.comment)
    eq('abc123', revise.params.sessionId)
    threads.close()
  end)

  it('does not send an empty comment', function()
    open_review({ block() })
    press(threads.view().tree_buf, 'r')
    press(compose.current().buf, '<CR>')
    eq(
      nil,
      vim.iter(fake.requests):find(function(request)
        return request.method == 'big.revise'
      end)
    )
    eq(nil, compose.current(), 'an empty comment dismisses the box')
    threads.close()
  end)

  it('tells the reader the gate and the merge are not armed yet', function()
    open_review({ block() })
    local seen = {}
    local real_notify = vim.notify
    vim.notify = function(message)
      seen[#seen + 1] = message
    end
    press(threads.view().tree_buf, 'a')
    press(threads.view().tree_buf, 'M')
    vim.notify = real_notify
    ok(seen[1]:match('next release') ~= nil, seen[1])
    ok(seen[2]:match('not armed') ~= nil, seen[2])
    eq(
      nil,
      vim.iter(fake.requests):find(function(request)
        return request.method == 'big.merge'
      end)
    )
    threads.close()
  end)

  it('does not let a session title be evaluated as vimscript in the winbar', function()
    -- A winbar evaluates `%{expr}` on every redraw, and the title is the first
    -- line of the user's own prompt — routinely pasted from an issue.
    eq('%%{execute("let g:pwned = 1")}', threads.escape_winbar('%{execute("let g:pwned = 1")}'))
    open_review({ block() })
    local view = threads.view()
    view.session.title = 'backoff %{execute("let g:nvime_pwned = 1")}'
    threads.reload(view.session)
    vim.g.nvime_pwned = nil
    vim.cmd('redraw')
    eq(nil, vim.g.nvime_pwned, 'a title must render as text, never run')
    threads.close()
  end)

  it('refuses to open a review that has no captured diff', function()
    threads.close()
    fake.requests = {}
    local view = session({ block() })
    view.hasDiff = false
    threads.open('/tmp/project', view)
    eq(nil, threads.view().tree_buf)
    eq(0, #fake.requests)
  end)
end)

package.loaded['nvime.agent'] = real_agent
package.loaded['nvime.threads'] = nil
