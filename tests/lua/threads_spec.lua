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
    ok(pane:match('── the gate ──') ~= nil, pane)
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

  it('bands a changed diff line and leaves the file headers alone', function()
    eq('NvimeEditAdd', threads.hunk_band('+    added'))
    eq('NvimeEditDelete', threads.hunk_band('-    removed'))
    eq(nil, threads.hunk_band('+++ b/pool.py'))
    eq(nil, threads.hunk_band('--- a/pool.py'))
    eq(nil, threads.hunk_band(' context'))
    eq(nil, threads.hunk_band('@@ -1,2 +1,3 @@'))
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
