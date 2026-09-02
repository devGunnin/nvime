local t = require('harness')
local compose = require('nvime.compose')
local config = require('nvime.config')
local palette = require('nvime.palette')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Stands in for the sidecar: records requests, replies from a canned table.
--- A method with no canned reply stays IN FLIGHT, the way an agent turn really
--- does, and `fake.settle` answers it later.
local fake = { requests = {}, replies = {}, pending = {}, subscribers = {} }

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

--- One server-pushed event, to every listener.
function fake.emit(name, params)
  for _, fn in ipairs(fake.subscribers) do
    fn(name, params)
  end
end

local real_agent = require('nvime.agent')
package.loaded['nvime.agent'] = {
  request = fake.request,
  on_event = function(fn)
    fake.subscribers[#fake.subscribers + 1] = fn
    return function() end
  end,
  is_running = function()
    return true
  end,
}
package.loaded['nvime.organization'] = nil
require('nvime.organization')
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
    rounds = {},
  }, overrides or {})
end

--- A graded round, as the sidecar records it.
local function round(grade, overrides)
  return vim.tbl_extend('force', {
    at = 1,
    answer = 'my answer',
    result = { grade = grade, verdict = 'scored ' .. grade, hint = '', followup = '' },
  }, overrides or {})
end

--- Runs `fn` with vim.notify captured, and returns what it said.
local function with_notices(fn)
  local seen = {}
  local real = vim.notify
  vim.notify = function(message)
    seen[#seen + 1] = message
  end
  local finished, err = pcall(fn)
  vim.notify = real
  if not finished then
    error(err, 0)
  end
  return seen
end

--- True when any captured notice matches `pattern`.
local function said(seen, pattern)
  return vim.iter(seen):any(function(message)
    return message:match(pattern) ~= nil
  end)
end

local function session(blocks, overrides)
  local open = 0
  for _, entry in ipairs(blocks) do
    if entry.state == 'open' then
      open = open + 1
    end
  end
  return vim.tbl_extend('force', {
    id = 'abc123',
    title = 'backoff',
    display = 'reviewing',
    state = 'reviewing',
    difficulty = 'medium',
    detached = false,
    hasDiff = true,
    worktree = { path = '/tmp/nvime-wt' },
    base = { commit = 'abcdef', branch = 'main' },
    counts = { total = #blocks, open = open, substantial = 1, defended = 1 - open },
    blocks = blocks,
    conversation = {},
    transitions = {},
  }, overrides or {})
end

--- @param session_overrides table|nil so a test can reopen on a DIFFERENT
--- change (a different `id`) instead of the default one.
local function open_review(blocks, session_overrides)
  threads.close()
  compose.dismiss()
  -- `fake.pending` deliberately survives: reopening the review must not lose
  -- track of a request the sidecar is still working on (issue-#10
  -- regression), and a test that reopens mid-request needs to settle it
  -- after, same as the real sidecar answering late.
  fake.requests, fake.replies = {}, {}
  palette.apply()
  fake.replies['big.diff'] = { result = { diff = { text = DIFF, hunks = HUNKS } } }
  threads.open('/tmp/project', session(blocks, session_overrides))
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

local THREADS_NS = vim.api.nvim_create_namespace('nvime.threads')

--- 0-based rows carrying a whole-line highlight (a `hunk_band` tint).
local function tinted_rows()
  local buf = threads.view().pane_buf
  local marks = vim.api.nvim_buf_get_extmarks(buf, THREADS_NS, 0, -1, { details = true })
  local rows = {}
  for _, mark in ipairs(marks) do
    if mark[4].line_hl_group ~= nil then
      rows[mark[2]] = mark[4].line_hl_group
    end
  end
  return rows
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
    eq('why · behaviour', pane[2])
    eq('--- pool.py', pane[4])
    eq('@@ -1,2 +1,3 @@', pane[5])
    eq('+new', pane[8])
    eq('--- notes.md', pane[10])
    threads.close()
  end)

  --- The `'--- ' .. file` line `pane_lines` synthesizes for a new file never
  --- goes through `hunk_band` at all (it is appended straight to `lines`,
  --- not read from `view.diff_lines`), so it can never pick up a tint —
  --- moved here from a `hunk_band('--- a/pool.py')` unit pin, since
  --- `hunk_band` itself no longer special-cases the header shape.
  it('never tints its own synthesized file-separator line', function()
    open_review({ block({ hunkIds = { 'h1.1', 'h2.1' }, files = { 'pool.py', 'notes.md' } }) })
    local pane = pane_text()
    local tinted = tinted_rows()
    eq('--- pool.py', pane[4])
    eq(nil, tinted[3], 'the pool.py separator (row 3, 0-based) must not be tinted')
    eq('--- notes.md', pane[10])
    eq(nil, tinted[9], 'the notes.md separator (row 9, 0-based) must not be tinted')
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

describe('review window resize', function()
  --- `WinResized` used to run a full `draw()`, which re-cuts the pane and
  --- always ends by putting its cursor back at line 1 — throwing a reader
  --- 200 lines into a hunk back to the top on every resize.
  it('keeps the reader’s place in the pane', function()
    open_review({ block({ hunkIds = { 'h1.1', 'h2.1' }, files = { 'pool.py', 'notes.md' } }) })
    local view = threads.view()
    vim.api.nvim_win_set_cursor(view.pane_win, { 3, 0 })
    vim.api.nvim_exec_autocmds('WinResized', {})
    eq({ 3, 0 }, vim.api.nvim_win_get_cursor(view.pane_win), 'the resize handler must not reset the cursor')
    threads.close()
  end)

  it('does not raise when the tree window is resized narrower than its bar chrome', function()
    open_review({ block() })
    local view = threads.view()
    vim.api.nvim_win_set_width(view.tree_win, 3)
    vim.v.errmsg = ''
    vim.api.nvim_exec_autocmds('WinResized', {})
    eq('', vim.v.errmsg, 'a narrow tree window must not raise from the resize handler')
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

  it("threads the big_build lane's model dial, and the big_triage lane's, into big.revise", function()
    local models = require('nvime.models')
    open_review({ block() })
    press(threads.view().tree_buf, 'r')
    vim.api.nvim_buf_set_lines(compose.current().buf, 0, -1, false, { 'use equal jitter here' })
    fake.replies['big.revise'] = { result = { session = session({ block({ state = 'open' }) }) } }
    fake.replies['big.diff'] = { result = { diff = { text = DIFF, hunks = HUNKS } } }
    models.set('big_build', 'claude-opus-5', 'high')
    models.set('big_triage', 'claude-haiku-5', 'medium')
    press(compose.current().buf, '<CR>')
    local revise = vim.iter(fake.requests):find(function(request)
      return request.method == 'big.revise'
    end)
    eq('claude-opus-5', revise.params.model)
    eq('high', revise.params.effort)
    eq('claude-haiku-5', revise.params.triageModel)
    eq('medium', revise.params.triageEffort)
    models.reset('big_build')
    models.reset('big_triage')
    threads.close()
  end)

  it('shows a rejected model as its own reason, not just "the revision failed"', function()
    open_review({ block() })
    press(threads.view().tree_buf, 'r')
    vim.api.nvim_buf_set_lines(compose.current().buf, 0, -1, false, { 'use equal jitter here' })
    fake.replies['big.revise'] =
      { err = { message = 'the big-change run failed', detail = 'Invalid model name "not-a-model"' } }
    local seen = with_notices(function()
      press(compose.current().buf, '<CR>')
    end)
    ok(said(seen, 'the big%-change run failed'), vim.inspect(seen))
    ok(said(seen, 'Invalid model name'), vim.inspect(seen))
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

  -- QA-sweep finding: the review tab can open mid-insert (the big panel's
  -- prompt is routinely left in insert after sending, and `tabnew` carries
  -- that mode along), so a raw `a`/`M` types into the buffer instead of
  -- firing its normal-mode mapping — the `aMDEFEND` corruption the sweep saw.
  it('forces normal mode when it opens mid-insert', function()
    -- Headless `-l` scripts cannot actually hold insert mode across
    -- statements (no UI is attached to carry it), so the precondition is
    -- stubbed directly rather than via `startinsert` — this still exercises
    -- the real branch in `build_tab` that checks `vim.fn.mode()`.
    local real_mode, real_cmd = vim.fn.mode, vim.cmd
    vim.fn.mode = function()
      return 'i'
    end
    local stopped = false
    vim.cmd = function(arg)
      if arg == 'stopinsert' then
        stopped = true
        return
      end
      return real_cmd(arg)
    end
    local finished, err = pcall(open_review, { block() })
    vim.fn.mode, vim.cmd = real_mode, real_cmd
    if not finished then
      error(err, 0)
    end
    ok(stopped, 'build_tab must leave insert mode when it opened mid-insert — the aMDEFEND corruption')
    threads.close()
  end)
end)

package.loaded['nvime.agent'] = real_agent
package.loaded['nvime.threads'] = nil

describe('the comprehension gate in the review', function()
  it('opens a paste-blocked answer box and sends what was typed', function()
    open_review({ block() })
    press(threads.view().tree_buf, 'a')
    local float = compose.current()
    ok(float ~= nil, 'a opens an answer box')
    vim.fn.setreg('"', 'the diff, pasted back')
    local refused = with_notices(function()
      ok(press(float.buf, 'p'), 'the box binds the puts')
    end)
    ok(said(refused, 'type it'), vim.inspect(refused))
    eq({ '' }, vim.api.nvim_buf_get_lines(float.buf, 0, -1, false), 'a defense is not pasteable')

    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, { 'it spreads retries across the whole window' })
    fake.replies['big.answer'] =
      { result = { session = session({ block({ state = 'resolved', rounds = { round(87) } }) }) } }
    with_notices(function()
      press(float.buf, '<CR>')
    end)

    local sent = vim.iter(fake.requests):find(function(request)
      return request.method == 'big.answer'
    end)
    ok(sent ~= nil, 'the answer reaches the grader')
    eq('abc123', sent.params.sessionId)
    eq({ { blockId = 'b1', text = 'it spreads retries across the whole window' } }, sent.params.answers)
    threads.close()
  end)

  it("threads the big_grade lane's model dial into big.answer", function()
    local models = require('nvime.models')
    open_review({ block() })
    press(threads.view().tree_buf, 'a')
    vim.api.nvim_buf_set_lines(compose.current().buf, 0, -1, false, { 'it spreads retries across the window' })
    fake.replies['big.answer'] =
      { result = { session = session({ block({ state = 'resolved', rounds = { round(87) } }) }) } }
    models.set('big_grade', 'claude-opus-5', 'high')
    with_notices(function()
      press(compose.current().buf, '<CR>')
    end)
    local sent = vim.iter(fake.requests):find(function(request)
      return request.method == 'big.answer'
    end)
    eq('claude-opus-5', sent.params.model)
    eq('high', sent.params.effort)
    models.reset('big_grade')
    threads.close()
  end)

  it('shows a rejected model as its own reason, not just "the grading turn failed"', function()
    open_review({ block() })
    press(threads.view().tree_buf, 'a')
    vim.api.nvim_buf_set_lines(compose.current().buf, 0, -1, false, { 'it spreads retries across the window' })
    fake.replies['big.answer'] =
      { err = { message = 'the big-change run failed', detail = 'Invalid model name "not-a-model"' } }
    local seen = with_notices(function()
      press(compose.current().buf, '<CR>')
    end)
    ok(said(seen, 'the big%-change run failed'), vim.inspect(seen))
    ok(said(seen, 'Invalid model name'), vim.inspect(seen))
    threads.close()
  end)

  it('refuses to grade what has nothing to defend', function()
    open_review({ block({ substantial = false, state = 'resolved' }) })
    local seen = with_notices(function()
      press(threads.view().tree_buf, 'a')
    end)
    ok(said(seen, 'needs no defense'), vim.inspect(seen))
    eq(nil, compose.current(), 'and no box opens')
    threads.close()

    open_review({ block({ state = 'resolved' }) })
    seen = with_notices(function()
      press(threads.view().tree_buf, 'a')
    end)
    ok(said(seen, 'already cleared'), vim.inspect(seen))
    threads.close()
  end)

  it('renders every round: the grade, the hint and the follow-up', function()
    local rounds = {
      round(41, {
        answer = 'it retries',
        result = { grade = 41, verdict = 'too generic', hint = 'what collides?', followup = 'and self.cap?' },
      }),
      round(88, { answer = 'full jitter spreads the whole window' }),
    }
    open_review({ block({ state = 'resolved', rounds = rounds }) })
    local pane = table.concat(pane_text(), '\n')
    ok(pane:match('\nthe gate\n') ~= nil, pane)
    ok(pane:match('you · it retries') ~= nil, pane)
    ok(pane:match('41 · too generic') ~= nil, pane)
    ok(pane:match('hint: what collides%?') ~= nil, pane)
    ok(pane:match('next: and self%.cap%?') ~= nil, pane)
    ok(pane:match('88 · scored 88') ~= nil, pane)
    threads.close()
  end)

  it('says a round was not graded rather than showing a score nobody gave', function()
    local ungraded = { at = 1, answer = 'my answer', ungraded = 'the grading turn did not return grades' }
    open_review({ block({ rounds = { ungraded } }) })
    local pane = table.concat(pane_text(), '\n')
    ok(pane:match('! the grading turn did not return grades') ~= nil, pane)
    ok(pane:match('stays open') ~= nil, pane)
    ok(pane:match('%d+ · ') == nil, 'and no grade is invented')
    threads.close()
  end)

  it('carries the pending follow-up into the next answer box', function()
    local pending = round(30, {
      result = { grade = 30, verdict = 'vague', hint = 'think about restarts', followup = 'what happens on restart?' },
    })
    eq('what happens on restart?', threads.followup(block({ rounds = { pending } })))
    eq(nil, threads.followup(block({ rounds = { round(90) } })), 'a cleared thread asks nothing')
    eq(nil, threads.followup(block()))

    open_review({ block({ rounds = { pending } }) })
    press(threads.view().tree_buf, 'a')
    local win = compose.current().win
    ok(vim.wo[win].winbar:match('what happens on restart%?') ~= nil, vim.wo[win].winbar)
    compose.dismiss()
    threads.close()
  end)

  it('reports what a round earned, off the session the sidecar returned', function()
    local passed = session({ block({ state = 'resolved', rounds = { round(87) } }) })
    ok(said(
      with_notices(function()
        threads.report_grade(passed, 'b1')
      end),
      'cleared %(87%)'
    ))

    local failed = session({
      block({
        rounds = { round(41, { result = { grade = 41, verdict = 'v', hint = 'what collides?', followup = 'q' } }) },
      }),
    })
    ok(said(
      with_notices(function()
        threads.report_grade(failed, 'b1')
      end),
      'what collides%?'
    ))

    local ungraded = session({ block({ rounds = { { at = 1, answer = 'x', ungraded = 'the CLI died' } } }) })
    ok(said(
      with_notices(function()
        threads.report_grade(ungraded, 'b1')
      end),
      'the CLI died'
    ))
  end)
end)

describe('the explain key', function()
  local explain = require('nvime.explain')

  it('asks the sidecar to explain a resolved thread and shows what came back', function()
    open_review({ block({ state = 'resolved' }) })
    fake.replies['big.explain'] = { result = { text = 'it adds a --version flag that prints and exits early.' } }
    press(threads.view().tree_buf, 'e')
    local request = vim.iter(fake.requests):find(function(entry)
      return entry.method == 'big.explain'
    end)
    ok(request ~= nil, 'e reaches the sidecar')
    eq('abc123', request.params.sessionId)
    eq('b1', request.params.blockId)
    local shown = table.concat(vim.api.nvim_buf_get_lines(explain.current().buf, 0, -1, false), '\n')
    ok(shown:find('%-%-version'), shown)
    threads.close()
    explain.close()
  end)

  it("threads the explain lane's model dial into big.explain", function()
    local models = require('nvime.models')
    open_review({ block({ state = 'resolved' }) })
    fake.replies['big.explain'] = { result = { text = 'it adds a --version flag.' } }
    models.set('explain', 'claude-haiku-5', 'low')
    press(threads.view().tree_buf, 'e')
    local request = vim.iter(fake.requests):find(function(entry)
      return entry.method == 'big.explain'
    end)
    eq('claude-haiku-5', request.params.model)
    eq('low', request.params.effort)
    models.reset('explain')
    threads.close()
    explain.close()
  end)

  it('explains trivia even while it is reopened', function()
    open_review({ block({ substantial = false, state = 'open', reopened = true }) })
    fake.replies['big.explain'] = { result = { text = 'this reformats a comment; nothing behavioral changed.' } }
    press(threads.view().tree_buf, 'e')
    ok(
      vim.iter(fake.requests):any(function(entry)
        return entry.method == 'big.explain'
      end),
      'trivia needs no defense, so it is never refused'
    )
    threads.close()
    explain.close()
  end)

  it('refuses locally to explain an open, substantial thread — never reaching the sidecar', function()
    open_review({ block({ state = 'open' }) })
    local seen = with_notices(function()
      press(threads.view().tree_buf, 'e')
    end)
    ok(said(seen, 'hand over the answer'), vim.inspect(seen))
    eq(nil, explain.current(), 'no float opens on a refusal')
    eq(
      nil,
      vim.iter(fake.requests):find(function(entry)
        return entry.method == 'big.explain'
      end),
      'the sidecar is never asked'
    )
    threads.close()
  end)

  it('shows a sidecar refusal in the float rather than failing silently', function()
    open_review({ block({ state = 'resolved' }) })
    fake.replies['big.explain'] = { err = { message = 'the build clone is gone' } }
    press(threads.view().tree_buf, 'e')
    local shown = table.concat(vim.api.nvim_buf_get_lines(explain.current().buf, 0, -1, false), '\n')
    ok(shown:find('build clone is gone', 1, true) ~= nil, shown)
    threads.close()
    explain.close()
  end)

  it('shows a rejected model as its own reason too, not just "could not explain this thread"', function()
    open_review({ block({ state = 'resolved' }) })
    fake.replies['big.explain'] =
      { err = { message = 'the big-change run failed', detail = 'Invalid model name "not-a-model"' } }
    press(threads.view().tree_buf, 'e')
    local shown = table.concat(vim.api.nvim_buf_get_lines(explain.current().buf, 0, -1, false), '\n')
    ok(shown:find('the big%-change run failed') ~= nil, shown)
    ok(shown:find('Invalid model name', 1, true) ~= nil, shown)
    threads.close()
    explain.close()
  end)
end)

describe('the merge key', function()
  it('asks the sidecar rather than deciding for itself', function()
    open_review({ block({ state = 'resolved' }) })
    fake.replies['big.merge'] = {
      result = {
        merged = true,
        refusals = {},
        session = session({ block({ state = 'resolved' }) }, {
          display = 'merged',
          state = 'merged',
          merge = { branch = 'nvime/big/backoff', commit = 'deadbeefcafe', baseBranch = 'main' },
        }),
      },
    }
    with_notices(function()
      press(threads.view().tree_buf, 'M')
    end)
    local sent = vim.iter(fake.requests):find(function(request)
      return request.method == 'big.merge'
    end)
    ok(sent ~= nil, 'M is a request, not a local decision')
    eq('abc123', sent.params.sessionId)
    eq(false, sent.params.cleanup, 'the clone is kept unless the config says otherwise')
    threads.close()
  end)

  it('automatically submits managed evidence after the reviewed commit lands', function()
    config.setup({
      organization = {
        control_plane_url = 'http://127.0.0.1:4817',
        trust_core = '/bin/true',
        github = '/bin/true',
      },
    })
    open_review({ block({ state = 'resolved' }) })
    fake.replies['big.merge'] = {
      result = {
        merged = true,
        refusals = {},
        session = session({ block({ state = 'resolved' }) }, {
          display = 'merged',
          state = 'merged',
          merge = { branch = 'nvime/big/backoff', commit = 'deadbeefcafe', baseBranch = 'main' },
        }),
      },
    }
    fake.replies['organization.attest'] = { result = { commitSha = 'deadbeefcafe' } }
    with_notices(function()
      press(threads.view().tree_buf, 'M')
    end)
    local attestation = vim.iter(fake.requests):find(function(request)
      return request.method == 'organization.attest'
    end)
    ok(attestation ~= nil, 'a managed merge must submit its evidence')
    eq('abc123', attestation.params.sessionId)
    eq('/tmp/project', attestation.params.root)
    config.setup({})
    threads.close()
  end)

  it('shows both the message and the detail on a failed merge', function()
    open_review({ block({ state = 'resolved' }) })
    fake.replies['big.merge'] = { err = { message = 'the merge failed', detail = 'the base has moved' } }
    local seen = with_notices(function()
      press(threads.view().tree_buf, 'M')
    end)
    ok(said(seen, 'the merge failed'), vim.inspect(seen))
    ok(said(seen, 'the base has moved'), vim.inspect(seen))
    threads.close()
  end)

  it('renders every refusal, and names the rebase when the base moved', function()
    local seen = with_notices(function()
      threads.report_refusals({
        { code = 'threads-open', message = '2 threads still need clearing' },
        { code = 'base-moved', message = 'main has moved since the build started' },
      })
    end)
    ok(said(seen, '2 threads still need clearing'), vim.inspect(seen))
    ok(said(seen, 'main has moved'), vim.inspect(seen))
    ok(said(seen, 'press R to rebase'), vim.inspect(seen))

    seen = with_notices(function()
      threads.report_refusals({ { code = 'dirty-tree', message = '1 tracked file has uncommitted changes' } })
    end)
    ok(said(seen, 'uncommitted changes'), vim.inspect(seen))
    ok(not said(seen, 'press R'), 'the rebase is only offered when the base actually moved')
  end)

  it('sends R as a rebase on this session', function()
    open_review({ block() })
    fake.replies['big.rebase'] = { result = { session = session({ block() }) } }
    with_notices(function()
      press(threads.view().tree_buf, 'R')
    end)
    local sent = vim.iter(fake.requests):find(function(request)
      return request.method == 'big.rebase'
    end)
    ok(sent ~= nil)
    eq('abc123', sent.params.sessionId)
    threads.close()
  end)

  it("threads the big_build lane's model dial, and the big_triage lane's, into big.rebase", function()
    local models = require('nvime.models')
    open_review({ block() })
    fake.replies['big.rebase'] = { result = { session = session({ block() }) } }
    models.set('big_build', 'claude-sonnet-5', 'medium')
    models.set('big_triage', 'claude-haiku-5', 'high')
    with_notices(function()
      press(threads.view().tree_buf, 'R')
    end)
    local sent = vim.iter(fake.requests):find(function(request)
      return request.method == 'big.rebase'
    end)
    eq('claude-sonnet-5', sent.params.model)
    eq('medium', sent.params.effort)
    eq('claude-haiku-5', sent.params.triageModel)
    eq('high', sent.params.triageEffort)
    models.reset('big_build')
    models.reset('big_triage')
    threads.close()
  end)

  it('shows a rejected model as its own reason on a rebase too', function()
    open_review({ block() })
    fake.replies['big.rebase'] =
      { err = { message = 'the big-change run failed', detail = 'Invalid model name "not-a-model"' } }
    local seen = with_notices(function()
      press(threads.view().tree_buf, 'R')
    end)
    ok(said(seen, 'the big%-change run failed'), vim.inspect(seen))
    ok(said(seen, 'Invalid model name'), vim.inspect(seen))
    threads.close()
  end)

  it('says what is left before the merge, in the words the gate uses', function()
    eq(
      '1/3 defended · 2 open · merge locked',
      threads.gate_status({ counts = { total = 5, open = 2, substantial = 3, defended = 1 } })
    )
    eq(
      '3/3 defended · M merges into your branch',
      threads.gate_status({ counts = { total = 5, open = 0, substantial = 3, defended = 3 } })
    )
    eq(
      'merged into main as deadbeef',
      threads.gate_status({ display = 'merged', merge = { baseBranch = 'main', commit = 'deadbeefcafe' } })
    )
  end)
end)

describe('the review’s own typography', function()
  it('names the speaker once per answer, not once per line', function()
    local lines = threads.gate_lines(block({
      rounds = { round(90, { answer = 'first line\nsecond line\nthird line' }) },
    }))
    local speakers = 0
    for _, line in ipairs(lines) do
      if line:match('^you · ') ~= nil then
        speakers = speakers + 1
      end
    end
    eq(1, speakers, vim.inspect(lines))
    local first = lines[3]
    local continuation = lines[4]
    eq(
      vim.fn.strdisplaywidth(first:sub(1, first:find('first') - 1)),
      vim.fn.strdisplaywidth(continuation:sub(1, continuation:find('second') - 1)),
      'a continuation aligns under the first line: ' .. vim.inspect(lines)
    )
  end)

  it('marks the score green only on the round that actually cleared the thread', function()
    local _, cleared = threads.gate_lines(block({ state = 'resolved', rounds = { round(40), round(90) } }))
    local _, still_open = threads.gate_lines(block({ state = 'open', rounds = { round(40) } }))
    local function grade_groups(marks)
      local out = {}
      for _, mark in ipairs(marks) do
        if mark.hl == 'NvimeOk' or mark.hl == 'NvimeWarn' then
          out[#out + 1] = mark.hl
        end
      end
      return out
    end
    eq({ 'NvimeWarn', 'NvimeOk' }, grade_groups(cleared))
    eq({ 'NvimeWarn' }, grade_groups(still_open))
  end)

  it('bands human answers separately from grader feedback', function()
    local _, marks = threads.gate_lines(block({
      rounds = {
        round(41, { answer = 'it retries', result = { grade = 41, verdict = 'too generic', hint = 'why?' } }),
      },
    }))
    local bands = vim
      .iter(marks)
      :filter(function(mark)
        return mark.col == nil
      end)
      :map(function(mark)
        return mark.hl
      end)
      :totable()
    eq({ 'NvimeUserBody', 'NvimeAgentBody', 'NvimeAgentBody' }, bands)
  end)

  --- github.com/devGunnin/nvime/issues/9: the pane rendered as an
  --- undifferentiated grey/white mix, with the reader's own answer and the
  --- grader's verdict in different colours for no reason a reader could learn.
  --- One rule now: the LABEL carries the colour, the content is always body.
  it('colours the label and leaves every piece of content in one body colour', function()
    local _, marks = threads.gate_lines(block({
      state = 'open',
      rounds = {
        round(41, {
          answer = 'it retries',
          result = { grade = 41, verdict = 'too generic', hint = 'what collides?', followup = 'and self.cap?' },
        }),
      },
    }))
    local by_group = {}
    for _, mark in ipairs(marks) do
      by_group[mark.hl] = (by_group[mark.hl] or 0) + 1
    end
    -- The gate header, plus the two guidance labels.
    eq(3, by_group.NvimeDim)
    eq(1, by_group.NvimeUser, 'the speaker label')
    eq(1, by_group.NvimeWarn, 'the score')
    eq(4, by_group.NvimeBody, 'the answer, the verdict, the hint and the follow-up')
  end)

  it('does not draw a rule across the pane to introduce the gate', function()
    local lines = threads.gate_lines(block({ rounds = { round(90) } }))
    eq('the gate', lines[2])
    for _, line in ipairs(lines) do
      ok(line:match('──') == nil, 'a rule survived: ' .. line)
    end
  end)

  --- Context used to render in the same white as an added line, leaving a
  --- faint band as the only thing telling the change from what surrounds it.
  it('recedes diff context and gives an added or removed line its own colour', function()
    eq('NvimeAdded', threads.hunk_fg('+    added'))
    eq('NvimeRemoved', threads.hunk_fg('-    removed'))
    eq('NvimeDim', threads.hunk_fg(' context'))
    eq('NvimeDim', threads.hunk_fg('@@ -1,2 +1,3 @@'))
  end)

  it('bands a changed diff line, ignores context and the hunk marker', function()
    eq('NvimeEditAdd', threads.hunk_band('+    added'))
    eq('NvimeEditDelete', threads.hunk_band('-    removed'))
    eq(nil, threads.hunk_band(' context'))
    eq(nil, threads.hunk_band('@@ -1,2 +1,3 @@'))
  end)

  --- `hunk_band` used to guess at the `+++`/`---` file-header shape and skip
  --- it, but `pane_lines` never hands it a real header — only diff-body
  --- lines bounded by `readHunk`'s own counters — so the guess only produced
  --- false negatives. A removed Lua comment or bulleted item is exactly the
  --- shape it wrongly matched, and still must be tinted.
  it('bands a removed comment or bullet, even one that starts with a repeated marker', function()
    eq('NvimeEditDelete', threads.hunk_band('-- a Lua comment being removed'))
    eq('NvimeEditAdd', threads.hunk_band('++nested added'))
    eq('NvimeEditDelete', threads.hunk_band('-  -- indented Lua comment removed'))
    -- Removing a `-- comment` line prepends the diff's own `-`, producing
    -- `--- comment` — the file-header shape exactly. The bug this regresses.
    eq('NvimeEditDelete', threads.hunk_band('--- a plain Lua comment that is about to go'))
  end)

  it('cuts a long thread title to the list width instead of wrapping it', function()
    local lines = threads.tree_lines({ block({ title = string.rep('long ', 40) }) }, 40)
    eq(1, #lines, 'one thread is one row, whatever its title')
    ok(vim.fn.strchars(lines[1]) <= 40, lines[1])
  end)

  it('offers only the keys that still do something once the change has landed', function()
    local landed = threads.keys_hint({ display = 'merged' })
    ok(landed:find('answer') == nil, landed)
    ok(landed:find('M merge') == nil, landed)
    ok(threads.keys_hint({ display = 'reviewing' }):find('a answer') ~= nil)
  end)
end)

describe('the grade the reader is told about', function()
  it('clips a long verdict so the toast never stops the editor on hit-enter', function()
    local verdict = string.rep('a long verdict sentence. ', 20)
    local graded = {
      blocks = {
        block({
          id = 'b1',
          state = 'resolved',
          rounds = {
            round(88, {
              result = {
                grade = 88,
                verdict = verdict,
                hint = '',
                followup = '',
              },
            }),
          },
        }),
      },
    }
    local seen = with_notices(function()
      threads.report_grade(graded, 'b1')
    end)
    eq(1, #seen)
    ok(seen[1]:find('\n') == nil, 'one line only: ' .. seen[1])
    ok(vim.fn.strchars(seen[1]) < vim.fn.strchars(verdict), seen[1])
    ok(seen[1]:find('88', 1, true) ~= nil, seen[1])
  end)
end)

--- The winbar the tree window is currently rendering.
local function tree_bar()
  return vim.wo[threads.view().tree_win].winbar
end

local function pane_bar()
  return vim.wo[threads.view().pane_win].winbar
end

--- Waits until the indicator has outlived its delay and painted, or gives up.
local function wait_for_spinner()
  return vim.wait(2000, function()
    return (threads.activity() or {}).shown == true
  end, 20)
end

describe('issue #10: the base moved, R rebases, M merges', function()
  it('walks the whole stuck sequence: M refused, R, then M lands it', function()
    open_review({ block({ state = 'resolved' }) })
    -- M, with the base moved out from under the build.
    fake.replies['big.merge'] = {
      result = {
        merged = false,
        refusals = { { code = 'base-moved', message = 'main has moved since the build started' } },
        session = session({ block({ state = 'resolved' }) }),
      },
    }
    local seen = with_notices(function()
      press(threads.view().tree_buf, 'M')
    end)
    ok(said(seen, 'press R to rebase'), vim.inspect(seen))

    -- R: a real rebase is an agent turn, so it stays in flight.
    fake.replies['big.merge'] = nil
    local rebased = session({ block({ state = 'resolved' }) }, { base = { commit = 'aa9fb774', branch = 'main' } })
    with_notices(function()
      press(threads.view().tree_buf, 'R')
    end)
    ok(threads.activity() ~= nil, 'the rebase is in flight and the tab says so')
    eq('rebasing the build onto the updated base', threads.activity().label)

    seen = with_notices(function()
      ok(fake.settle('big.rebase', nil, { session = rebased }))
    end)
    eq(nil, threads.activity(), 'the indicator clears when the rebase settles')
    ok(said(seen, 'rebased onto the updated base'), vim.inspect(seen))

    -- M again, on the rebased build: it lands.
    fake.replies['big.merge'] = {
      result = {
        merged = true,
        refusals = {},
        session = session({ block({ state = 'resolved' }) }, {
          display = 'merged',
          state = 'merged',
          merge = { branch = 'nvime/big/backoff', commit = 'deadbeefcafe', baseBranch = 'main' },
        }),
      },
    }
    seen = with_notices(function()
      press(threads.view().tree_buf, 'M')
    end)
    ok(said(seen, 'merged'), vim.inspect(seen))
    threads.close()
  end)

  it('shows a spinner and what the rebase is doing until it settles', function()
    open_review({ block({ state = 'resolved' }) })
    with_notices(function()
      press(threads.view().tree_buf, 'R')
    end)
    ok(wait_for_spinner(), 'a request past the delay paints an indicator')
    ok(tree_bar():find('rebasing the build', 1, true) ~= nil, tree_bar())

    -- The runner's progress is addressed to the request that started it.
    local id = fake.requests[#fake.requests].opts.on_sent ~= nil and threads.activity().request_id or nil
    ok(id ~= nil, 'the review tab tracks the request id its events carry')
    fake.emit('big.tool', { id = id, tool = 'Edit', summary = 'Edit lua/nvime/big.lua' })
    ok(pane_bar():find('Edit lua/nvime/big.lua', 1, true) ~= nil, pane_bar())
    fake.emit('big.tool', { id = id + 99, summary = 'somebody else’s build' })
    ok(pane_bar():find('somebody', 1, true) == nil, 'another request’s progress is not this tab’s')

    with_notices(function()
      ok(fake.settle('big.rebase', nil, { session = session({ block({ state = 'resolved' }) }) }))
    end)
    eq(nil, threads.activity())
    ok(tree_bar():find('rebasing', 1, true) == nil, tree_bar())
    ok(pane_bar():find('M merge', 1, true) ~= nil, 'the keys come back once the tab is idle')
    threads.close()
  end)

  it('says what is running instead of stacking a second request on it', function()
    open_review({ block({ state = 'resolved' }) })
    with_notices(function()
      press(threads.view().tree_buf, 'R')
    end)
    local before = #fake.requests
    local seen = with_notices(function()
      press(threads.view().tree_buf, 'M')
      press(threads.view().tree_buf, 'R')
    end)
    eq(before, #fake.requests, 'neither keystroke sent a request the sidecar would only refuse')
    ok(said(seen, 'rebasing the build onto the updated base'), vim.inspect(seen))
    ok(said(seen, 'wait for that to finish'), vim.inspect(seen))

    -- Closing the tab must not drop a request that is still running on the
    -- sidecar (issue-#10 regression): the latch survives, only its timer pauses.
    threads.close()
    ok(threads.activity() ~= nil, 'the latch survives the close while the rebase is still in flight')

    with_notices(function()
      ok(fake.settle('big.rebase', nil, { session = session({ block({ state = 'resolved' }) }) }))
    end)
    eq(nil, threads.activity(), 'it clears once the still-running rebase actually settles')
  end)

  it('keeps a fast round trip silent — no spinner flashes for a toggle', function()
    open_review({ block({ substantial = false, state = 'resolved' }) })
    fake.replies['big.toggle'] = { result = { session = session({ block({ substantial = false }) }) } }
    with_notices(function()
      press(threads.view().tree_buf, 'X')
    end)
    eq(nil, threads.activity(), 'it settled before the indicator was ever due')
    ok(tree_bar():find('defended', 1, true) ~= nil, tree_bar())
    threads.close()
  end)

  -- Coldstart review finding 1 (HIGH): a stale request's completion used to
  -- tear down a LATER request's indicator and reopen the one-at-a-time latch.
  -- Reproduces the reviewer's own reopen-mid-rebase probe.
  it('re-adopts an in-flight rebase across a reopen, and a stale answer never touches what runs after it', function()
    open_review({ block({ state = 'resolved' }) })
    with_notices(function()
      press(threads.view().tree_buf, 'R')
    end)
    ok(threads.activity() ~= nil, 'R put the rebase in flight')
    local rebase_generation = threads.activity().generation

    -- The reader closes and reopens the review tab (big.lua's `<C-t>`, or any
    -- close/reopen) while the rebase keeps running on the sidecar.
    open_review({ block({ state = 'resolved' }) })
    ok(threads.activity() ~= nil, 'reopening the tab must re-adopt the still-running rebase, not orphan it')
    eq(rebase_generation, threads.activity().generation, 'the same request, not a fresh one')

    -- With the latch re-armed, a second request is refused rather than sent
    -- while the sidecar still holds the session for the rebase.
    local before = #fake.requests
    local seen = with_notices(function()
      press(threads.view().tree_buf, 'M')
    end)
    eq(before, #fake.requests, 'a merge must not be sent while the rebase is still in flight')
    ok(said(seen, 'wait for that to finish'), vim.inspect(seen))

    -- The only local escape is `<C-c>`: it frees the latch, but the abandoned
    -- rebase keeps its old generation, so a late answer cannot relatch it.
    seen = with_notices(function()
      press(threads.view().tree_buf, '<C-C>')
    end)
    eq(nil, threads.activity(), '<C-c> frees the latch locally')
    ok(said(seen, 'gave up waiting'), vim.inspect(seen))

    -- A fresh request takes the latch under its own, later, generation.
    with_notices(function()
      press(threads.view().tree_buf, 'M')
    end)
    ok(threads.activity() ~= nil, 'M took the freed latch')
    local merge_generation = threads.activity().generation
    ok(merge_generation ~= rebase_generation, 'the merge is its own request, not the abandoned rebase')

    -- The stale, abandoned rebase finally answers.
    seen = with_notices(function()
      ok(fake.settle('big.rebase', nil, { session = session({ block({ state = 'resolved' }) }) }))
    end)
    ok(threads.activity() ~= nil, "BUG regression: a stale answer must not clear a LATER request's indicator")
    eq(
      merge_generation,
      (threads.activity() or {}).generation,
      "the merge's own indicator must survive the stale rebase settling under it"
    )
    -- N2 fix: a stale on_result no longer runs at all (it used to fire
    -- `M.reload`, mutating `view.session` out from under the merge in
    -- flight) — only a generic outcome line renders now.
    ok(
      said(seen, 'rebasing the build onto the updated base finished'),
      vim.inspect(seen),
      'the stale answer still renders an outcome line, but never mutates state'
    )
    eq('abc123', threads.view().session.id, "the stale rebase's own on_result must not have run")

    -- Settle the merge too, so nothing is left in flight for the next test.
    with_notices(function()
      ok(
        fake.settle(
          'big.merge',
          nil,
          { merged = true, refusals = {}, session = session({ block({ state = 'resolved' }) }) }
        )
      )
    end)
    threads.close()
  end)

  -- Fix-round-1 delta finding N1/N2: the latch was per-module, not
  -- per-session, so reopening the review on a DIFFERENT change inherited
  -- the old one's latch — the reviewer's A-rebase, pick B, `<C-t>` probe.
  it('does not inherit a stale latch when the tab reopens on a different change', function()
    open_review({ block({ state = 'resolved' }) })
    with_notices(function()
      press(threads.view().tree_buf, 'R')
    end)
    ok(threads.activity() ~= nil, 'a rebase on change A is in flight')

    -- The reader picks a different change from the panel (`<C-r>`) and opens
    -- its review (`<C-t>`) while A's rebase is still running on the sidecar.
    open_review(
      { block({ id = 'b2', title = 'other change', state = 'resolved' }) },
      { id = 'session-B', title = 'other change' }
    )
    eq('session-B', threads.view().session.id)
    ok(threads.activity() == nil, "change B must not inherit change A's latch")

    -- B's own M must reach the sidecar rather than being refused as busy
    -- because of a rebase running on a change the reader has left.
    fake.replies['big.merge'] = {
      result = {
        merged = true,
        refusals = {},
        session = session({ block({ id = 'b2', title = 'other change', state = 'resolved' }) }, {
          id = 'session-B',
          display = 'merged',
          state = 'merged',
          merge = { branch = 'nvime/big/other', commit = 'deadbeefcafe', baseBranch = 'main' },
        }),
      },
    }
    local seen = with_notices(function()
      press(threads.view().tree_buf, 'M')
    end)
    ok(said(seen, 'merged'), vim.inspect(seen))

    -- Drain A's stale rebase so it does not leak into a later test.
    with_notices(function()
      ok(fake.settle('big.rebase', nil, { session = session({ block({ state = 'resolved' }) }) }))
    end)
    threads.close()
  end)

  it('quarantines a stale rebase that settles after the tab has moved to another change', function()
    open_review({ block({ state = 'resolved' }) })
    with_notices(function()
      press(threads.view().tree_buf, 'R')
    end)

    open_review(
      { block({ id = 'b2', title = 'other change', state = 'resolved' }) },
      { id = 'session-B', title = 'other change' }
    )
    local requests_before = #fake.requests

    -- A's stale rebase finally answers. It must still tell the reader
    -- something happened, but it must not touch the tab that has since
    -- moved to B: no mutated `view.session`, no `big.diff` re-issued.
    local seen = with_notices(function()
      ok(fake.settle('big.rebase', nil, { session = session({ block({ state = 'resolved' }) }) }))
    end)
    eq('session-B', threads.view().session.id, "A's stale answer must not flip the tab back to A")
    eq(requests_before, #fake.requests, 'a stale settle must not issue big.diff for the change it belongs to')
    ok(said(seen, 'rebas'), 'the stale settle still renders its own outcome line: ' .. vim.inspect(seen))
    threads.close()
  end)

  -- Coldstart review finding 2 (MEDIUM-HIGH): the streamed detail went into
  -- the winbar unbounded and with newlines intact.
  it('bounds a long, multi-line streamed detail before it reaches the winbar', function()
    open_review({ block({ state = 'resolved' }) })
    with_notices(function()
      press(threads.view().tree_buf, 'R')
    end)
    local id = threads.activity().request_id
    ok(id ~= nil, 'the review tab tracks the request id its events carry')

    local pane_width = vim.api.nvim_win_get_width(threads.view().pane_win)
    local long = 'git rebase --onto ' .. string.rep('very-long-branch-name/', 20) .. 'main'
    fake.emit('big.tool', { id = id, summary = long })
    local rendered = pane_bar():gsub('%%#%w+#', ''):gsub('%%=', ''):gsub('%%%%', '%%')
    ok(
      vim.fn.strdisplaywidth(rendered) <= pane_width,
      string.format('pane width=%d, rendered width=%d: %s', pane_width, vim.fn.strdisplaywidth(rendered), rendered)
    )

    local multi = 'the detached build runner could not start (Error: spawn ENOENT\n'
      .. '  at ChildProcess\n  at onErrorNT) — building in this editor instead'
    local ok_set = pcall(fake.emit, 'big.notice', { id = id, text = multi })
    ok(ok_set, 'a multi-line notice must not raise when it becomes a winbar')
    ok(pane_bar():find('\n', 1, true) == nil, 'the winbar must hold no raw newline: ' .. vim.inspect(pane_bar()))

    with_notices(function()
      ok(fake.settle('big.rebase', nil, { session = session({ block({ state = 'resolved' }) }) }))
    end)
    threads.close()
  end)
end)

describe('issue #10: a merge check that runs long says so', function()
  it('spins on the merge check and stops on the next event', function()
    open_review({ block({ state = 'resolved' }) })
    with_notices(function()
      press(threads.view().tree_buf, 'M')
    end)
    ok(wait_for_spinner(), 'the merge check paints an indicator once it outlives the delay')
    ok(tree_bar():find('checking the merge preconditions', 1, true) ~= nil, tree_bar())
    local first = threads.activity().frame
    ok(
      vim.wait(2000, function()
        return (threads.activity() or {}).frame > first
      end, 20),
      'the spinner keeps ticking while the check runs'
    )
    with_notices(function()
      ok(fake.settle('big.merge', nil, {
        merged = false,
        refusals = { { code = 'base-moved', message = 'main has moved' } },
        session = session({ block({ state = 'resolved' }) }),
      }))
    end)
    eq(nil, threads.activity(), 'the spinner stops on the answer')
    ok(tree_bar():find('checking the merge', 1, true) == nil, tree_bar())
    threads.close()
  end)

  it('names :Nvime bundle once the check has run past the slow mark', function()
    open_review({ block({ state = 'resolved' }) })
    with_notices(function()
      press(threads.view().tree_buf, 'M')
    end)
    ok(wait_for_spinner(), 'the merge check paints an indicator')
    ok(threads.activity_line():find('Nvime bundle', 1, true) == nil, 'a check that just started is not slow yet')

    -- Backdate the record rather than waiting out the real threshold.
    local current = threads.activity()
    current.started_ms = current.started_ms - (threads.SLOW_ACTIVITY_MS + 1000)
    local line = threads.activity_line()
    ok(line:find('still checking', 1, true) ~= nil, line)
    ok(line:find(':Nvime bundle', 1, true) ~= nil, line)

    with_notices(function()
      ok(fake.settle('big.merge', nil, {
        merged = false,
        refusals = { { code = 'base-moved', message = 'main has moved' } },
        session = session({ block({ state = 'resolved' }) }),
      }))
    end)
    eq(nil, threads.activity())
    threads.close()
  end)
end)
