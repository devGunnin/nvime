--- The review pane as the real file: what the reader actually gets a buffer of,
--- what the diff looks like on top of it, and what is left behind afterwards.
local t = require('harness')
local palette = require('nvime.palette')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Stands in for the sidecar. Only `big.diff` is ever asked for here.
local fake = { replies = {} }

package.loaded['nvime.agent'] = {
  request = function(method, _, cb)
    local reply = fake.replies[method]
    if reply ~= nil then
      cb(reply.err, reply.result)
    end
  end,
  on_event = function()
    return function() end
  end,
  is_running = function()
    return true
  end,
}
package.loaded['nvime.threads'] = nil
local threads = require('nvime.threads')
local reviewbuf = require('nvime.reviewbuf')

--- The build clone: real files on disk, exactly as the diff below describes
--- them AFTER the change.
local clone = vim.fs.normalize(vim.fn.tempname())
local FILES = {
  ['pool.lua'] = {
    'local M = {}',
    '',
    'function M.next_delay(attempt)',
    '  local base = math.min(cap, 2 ^ attempt)',
    '  return math.random() * base',
    'end',
  },
  ['notes.md'] = { '# notes', '', 'backoff notes' },
  ['stale.txt'] = { 'keep' },
}

vim.fn.mkdir(clone, 'p')
for name, lines in pairs(FILES) do
  vim.fn.writefile(lines, clone .. '/' .. name)
end

--- The capture the sidecar hands over. `HUNKS` indexes it the way the sidecar
--- does: `offset` is the 0-based line of the `@@`, `lineCount` spans from
--- there to the end of the hunk body.
local DIFF_LINES = {
  'diff --git a/pool.lua b/pool.lua',
  '--- a/pool.lua',
  '+++ b/pool.lua',
  '@@ -1,5 +1,6 @@',
  ' local M = {}',
  '',
  ' function M.next_delay(attempt)',
  '-  return 2 ^ attempt',
  '+  local base = math.min(cap, 2 ^ attempt)',
  '+  return math.random() * base',
  ' end',
  'diff --git a/notes.md b/notes.md',
  '--- a/notes.md',
  '+++ b/notes.md',
  '@@ -1,2 +1,3 @@',
  ' # notes',
  '',
  '+backoff notes',
  'diff --git a/stale.txt b/stale.txt',
  '--- a/stale.txt',
  '+++ b/stale.txt',
  '@@ -1,2 +1 @@',
  ' keep',
  '-gone',
}

local DIFF = table.concat(DIFF_LINES, '\n')

local HUNKS = {
  { id = 'hp', file = 'pool.lua', offset = 3, lineCount = 8 },
  { id = 'hn', file = 'notes.md', offset = 14, lineCount = 4 },
  { id = 'hs', file = 'stale.txt', offset = 21, lineCount = 3 },
  { id = 'hbin', file = 'logo.png', offset = -1, lineCount = 0, note = 'binary content changed' },
}

local function block(overrides)
  return vim.tbl_extend('force', {
    id = 'b1',
    title = 'jitter strategy',
    files = { 'pool.lua' },
    hunkIds = { 'hp' },
    substantial = true,
    rationale = 'full jitter, not equal jitter',
    state = 'open',
    reopened = false,
    signatures = { 'sig1' },
    rounds = {},
  }, overrides or {})
end

local function session(blocks, overrides)
  return vim.tbl_extend('force', {
    id = 'abc123',
    title = 'backoff',
    display = 'reviewing',
    state = 'reviewing',
    difficulty = 'medium',
    detached = false,
    hasDiff = true,
    worktreeExists = true,
    worktree = { path = clone },
    base = { commit = 'abcdef', branch = 'main' },
    counts = { total = #blocks, open = 1, substantial = 1, defended = 0 },
    blocks = blocks,
    conversation = {},
    transitions = {},
  }, overrides or {})
end

local function open_review(blocks, overrides)
  threads.close()
  palette.apply()
  fake.replies['big.diff'] = { result = { diff = { text = DIFF, hunks = HUNKS } } }
  threads.open(clone, session(blocks, overrides))
end

local function press(buf, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.lhs == lhs and map.callback ~= nil then
      map.callback()
      return true
    end
  end
  return false
end

--- The buffer the pane window is actually showing.
local function pane_buf()
  local win = threads.view().pane_win
  ok(win ~= nil and vim.api.nvim_win_is_valid(win), 'the review pane must be open')
  return vim.api.nvim_win_get_buf(win)
end

local function marks_of(buf)
  return vim.api.nvim_buf_get_extmarks(buf, reviewbuf.NS, 0, -1, { details = true })
end

--- 0-based row -> the band highlight it carries.
local function bands(buf)
  local out = {}
  for _, mark in ipairs(marks_of(buf)) do
    if mark[4].line_hl_group ~= nil then
      out[mark[2]] = mark[4].line_hl_group
    end
  end
  return out
end

--- Every virtual line hung off `buf`, as { row, above, text }.
local function virtuals(buf)
  local out = {}
  for _, mark in ipairs(marks_of(buf)) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      local text = ''
      for _, chunk in ipairs(line) do
        text = text .. chunk[1]
      end
      out[#out + 1] = { row = mark[2], above = mark[4].virt_lines_above == true, text = text }
    end
  end
  return out
end

local function has_virtual(buf, pattern)
  return vim.iter(virtuals(buf)):any(function(entry)
    return entry.text:match(pattern) ~= nil
  end)
end

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

local function said(seen, pattern)
  return vim.iter(seen):any(function(message)
    return message:match(pattern) ~= nil
  end)
end

describe('the review pane is the real file', function()
  it('opens the clone’s own file as a normal, read-only buffer', function()
    open_review({ block() })
    local buf = pane_buf()
    eq(clone .. '/pool.lua', vim.api.nvim_buf_get_name(buf))
    eq('lua', vim.bo[buf].filetype)
    eq('', vim.bo[buf].buftype, 'a normal file buffer is what treesitter and an LSP attach to')
    eq(false, vim.bo[buf].modifiable, 'a stray key must not edit the sandbox')
    eq(FILES['pool.lua'], vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'the bytes stay the file’s')
    threads.close()
  end)

  it('lands the reader on the change, not on line 1', function()
    open_review({ block() })
    eq(4, vim.api.nvim_win_get_cursor(threads.view().pane_win)[1])
    threads.close()
  end)

  it('names the file under review on its own bar', function()
    open_review({ block() })
    ok(threads.pane_title():match('^pool%.lua · backoff$') ~= nil, threads.pane_title())
    threads.close()
  end)

  it('bands what the hunk changed and leaves the rest of the file alone', function()
    open_review({ block() })
    eq({ [3] = 'NvimeEditChange', [4] = 'NvimeEditChange' }, bands(pane_buf()))
    threads.close()
  end)

  it('renders a removed line as a virtual line above what replaced it', function()
    open_review({ block() })
    local buf = pane_buf()
    local removed = vim
      .iter(virtuals(buf))
      :filter(function(entry)
        return entry.text:match('return 2 %^ attempt') ~= nil
      end)
      :totable()
    eq(1, #removed, 'the removed line renders exactly once')
    eq(3, removed[1].row)
    eq(true, removed[1].above)
    ok(removed[1].text:match('^%- ') ~= nil, 'it is prefixed, so it cannot be mistaken for file text')
    threads.close()
  end)

  it('anchors the thread’s question and its graded rounds at the hunk', function()
    open_review({
      block({
        rounds = {
          {
            at = 1,
            answer = 'full jitter spreads retries across the whole window',
            result = { grade = 87, verdict = 'clear', hint = '', followup = 'and what does cap protect?' },
          },
        },
      }),
    })
    local buf = pane_buf()
    ok(has_virtual(buf, 'jitter strategy'), 'the thread title')
    ok(has_virtual(buf, 'why · full jitter'), 'why it exists')
    ok(has_virtual(buf, 'you · full jitter spreads'), 'the answer')
    ok(has_virtual(buf, '87 · clear'), 'the grade')
    ok(has_virtual(buf, 'next: and what does cap protect'), 'the follow-up')
    local overlay = vim
      .iter(virtuals(buf))
      :filter(function(entry)
        return entry.text:match('jitter strategy') ~= nil
      end)
      :totable()
    eq(3, overlay[1].row, 'the overlay sits at the thread’s first hunk in this file')
    threads.close()
  end)

  it('keeps the file’s bytes out of the overlay: it is all virtual', function()
    open_review({ block() })
    local buf = pane_buf()
    ok(not vim.iter(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):any(function(line)
      return line:match('jitter strategy') ~= nil
    end), 'nothing the review draws is in the buffer text')
    threads.close()
  end)
end)

describe('walking a review that is real files', function()
  local function two_file_block()
    return block({
      id = 'b2',
      title = 'notes and stale',
      files = { 'notes.md', 'stale.txt' },
      hunkIds = { 'hn', 'hs' },
    })
  end

  it(']c walks to the next hunk, switching files when the thread spans two', function()
    open_review({ two_file_block() })
    local buf = pane_buf()
    eq(clone .. '/notes.md', vim.api.nvim_buf_get_name(buf))
    eq({ [2] = 'NvimeEditAdd' }, bands(buf))
    ok(press(buf, ']c'), ']c must be bound in the review pane')
    local next_buf = pane_buf()
    eq(clone .. '/stale.txt', vim.api.nvim_buf_get_name(next_buf))
    ok(press(next_buf, '[c'), '[c must be bound too')
    eq(clone .. '/notes.md', vim.api.nvim_buf_get_name(pane_buf()))
    threads.close()
  end)

  --- The row the deletion belongs to is past the end of a one-line file.
  it('hangs a deletion past the last line below it instead of dropping it', function()
    open_review({ two_file_block() })
    press(pane_buf(), ']c')
    local buf = pane_buf()
    local gone = vim
      .iter(virtuals(buf))
      :filter(function(entry)
        return entry.text:match('gone') ~= nil
      end)
      :totable()
    eq(1, #gone)
    eq(0, gone[1].row, 'clamped onto the last real line')
    eq(false, gone[1].above)
    threads.close()
  end)

  it(']t switches the pane to the next thread’s file, cleanly', function()
    open_review({ block(), two_file_block() })
    eq(clone .. '/pool.lua', vim.api.nvim_buf_get_name(pane_buf()))
    ok(press(threads.view().tree_buf, ']t'))
    local buf = pane_buf()
    eq(clone .. '/notes.md', vim.api.nvim_buf_get_name(buf))
    ok(not has_virtual(buf, 'jitter strategy'), 'the thread left behind takes its overlay with it')
    ok(has_virtual(buf, 'notes and stale'))
    press(threads.view().tree_buf, '[t')
    eq(clone .. '/pool.lua', vim.api.nvim_buf_get_name(pane_buf()))
    threads.close()
  end)
end)

describe('the unified diff, demoted to a toggle', function()
  it('t swaps to the rendered diff and back to the file', function()
    open_review({ block() })
    local file_buf = pane_buf()
    ok(press(file_buf, 't'), 't must be bound in the review pane')
    local unified = pane_buf()
    ok(unified ~= file_buf, 't leaves the file buffer')
    eq(threads.view().pane_buf, unified)
    local text = vim.api.nvim_buf_get_lines(unified, 0, -1, false)
    ok(
      vim.iter(text):any(function(line)
        return line == '+  return math.random() * base'
      end),
      'the unified render is the diff itself'
    )
    ok(press(unified, 't'))
    eq(clone .. '/pool.lua', vim.api.nvim_buf_get_name(pane_buf()), 'and back to the same file')
    eq({ [3] = 'NvimeEditChange', [4] = 'NvimeEditChange' }, bands(pane_buf()), 'with its annotations again')
    threads.close()
  end)

  it('falls back to the diff for a thread with no file to show, and says so on a press', function()
    open_review({ block({ id = 'bin', title = 'the logo', files = { 'logo.png' }, hunkIds = { 'hbin' } }) })
    eq(threads.view().pane_buf, pane_buf(), 'a binary hunk has no file to annotate')
    local seen = with_notices(function()
      press(threads.view().pane_buf, 't')
      press(threads.view().pane_buf, 't')
    end)
    ok(said(seen, 'no file to show for this thread'), vim.inspect(seen))
    threads.close()
  end)

  it('<CR> refuses to open a second, unmapped copy of the file the pane already is', function()
    open_review({ block() })
    local before = #vim.api.nvim_list_tabpages()
    local seen = with_notices(function()
      press(pane_buf(), '<CR>')
    end)
    eq(before, #vim.api.nvim_list_tabpages())
    ok(said(seen, 'this pane is the file'), vim.inspect(seen))
    threads.close()
  end)
end)

describe('a clone that is not there', function()
  it('degrades to the unified diff and says why', function()
    threads.close()
    palette.apply()
    fake.replies['big.diff'] = { result = { diff = { text = DIFF, hunks = HUNKS } } }
    local seen = with_notices(function()
      threads.open(clone, session({ block() }, { worktreeExists = false }))
    end)
    eq(threads.view().pane_buf, pane_buf())
    ok(said(seen, 'the build clone is gone'), vim.inspect(seen))
    threads.close()
  end)

  it('says it once, not once per redraw', function()
    threads.close()
    palette.apply()
    fake.replies['big.diff'] = { result = { diff = { text = DIFF, hunks = HUNKS } } }
    local seen = with_notices(function()
      threads.open(clone, session({ block(), block({ id = 'b2', title = 'second' }) }, { worktreeExists = false }))
      press(threads.view().tree_buf, ']t')
      press(threads.view().tree_buf, '[t')
    end)
    local count = 0
    for _, message in ipairs(seen) do
      if message:match('the build clone is gone') then
        count = count + 1
      end
    end
    eq(1, count, vim.inspect(seen))
    threads.close()
  end)
end)

describe('what the review leaves behind', function()
  it('wipes every clone buffer it opened when the tab closes', function()
    open_review({ block(), block({ id = 'b2', title = 'notes', files = { 'notes.md' }, hunkIds = { 'hn' } }) })
    press(threads.view().tree_buf, ']t')
    local opened = vim.tbl_keys(reviewbuf.buffers())
    eq(2, #opened, 'both files were opened: ' .. vim.inspect(opened))
    local buffers = vim.tbl_values(reviewbuf.buffers())
    threads.close()
    eq({}, reviewbuf.buffers())
    for _, buf in ipairs(buffers) do
      eq(false, vim.api.nvim_buf_is_valid(buf), 'no clone buffer survives the review')
    end
    ok(not vim.iter(vim.api.nvim_list_bufs()):any(function(buf)
      return vim.api.nvim_buf_get_name(buf):find(clone, 1, true) ~= nil
    end), 'and none is left in the buffer list')
  end)

  it('re-reads the clone when a new capture lands', function()
    open_review({ block() })
    local first = pane_buf()
    threads.reload(session({ block() }))
    eq(false, vim.api.nvim_buf_is_valid(first), 'the stale buffer is dropped, not re-annotated')
    eq(clone .. '/pool.lua', vim.api.nvim_buf_get_name(pane_buf()))
    eq({ [3] = 'NvimeEditChange', [4] = 'NvimeEditChange' }, bands(pane_buf()))
    threads.close()
  end)

  it('binds the review’s keys only on its own buffers', function()
    open_review({ block() })
    local buf = pane_buf()
    local bound = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      bound[map.lhs] = true
    end
    for _, lhs in ipairs({ 'a', 'e', 'r', 'X', 't', ']c', '[c', ']t', '[t', 'M', 'q' }) do
      ok(bound[lhs], lhs .. ' must be bound in the file pane')
    end
    for _, map in ipairs(vim.api.nvim_get_keymap('n')) do
      ok(map.lhs ~= 't' and map.lhs ~= ']c', 'the review must not map ' .. map.lhs .. ' globally')
    end
    threads.close()
    local scratch = vim.api.nvim_create_buf(false, true)
    eq({}, vim.api.nvim_buf_get_keymap(scratch, 'n'), 'and nothing leaks into a fresh buffer')
    vim.api.nvim_buf_delete(scratch, { force = true })
  end)
end)
