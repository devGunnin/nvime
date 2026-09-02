--- The review pane as the real file: what the reader actually gets a buffer of,
--- what the diff looks like on top of it, and what is left behind afterwards.
local t = require('harness')
local palette = require('nvime.palette')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Stands in for the sidecar, recording every method the review asked for.
local fake = { replies = {}, sent = {} }

package.loaded['nvime.agent'] = {
  request = function(method, _, cb)
    fake.sent[#fake.sent + 1] = method
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
  --- Emptied by the change, but not deleted: still on disk, zero bytes.
  ['empty.txt'] = {},
  --- On disk as the reader's checkout has it, NOT as the capture below
  --- describes it — the drift the integrity check is there to catch.
  ['drift.lua'] = { 'local M = {}', 'return M' },
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
  -- A removed line out of a CRLF file keeps the `\r` the buffer never shows.
  '-gone\r',
  'diff --git a/empty.txt b/empty.txt',
  '--- a/empty.txt',
  '+++ b/empty.txt',
  '@@ -1,2 +0,0 @@',
  '-first',
  '-second',
  'diff --git a/drift.lua b/drift.lua',
  '--- a/drift.lua',
  '+++ b/drift.lua',
  '@@ -1,2 +1,3 @@',
  ' local M = {}',
  '+  local base = 1',
  ' return M',
}

local DIFF = table.concat(DIFF_LINES, '\n')

local HUNKS = {
  { id = 'hp', file = 'pool.lua', offset = 3, lineCount = 8 },
  { id = 'hn', file = 'notes.md', offset = 14, lineCount = 4 },
  { id = 'hs', file = 'stale.txt', offset = 21, lineCount = 3 },
  { id = 'he', file = 'empty.txt', offset = 27, lineCount = 3 },
  { id = 'hd', file = 'drift.lua', offset = 33, lineCount = 4 },
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

--- How many times the review has asked the sidecar for `method`.
local function sent(method)
  local count = 0
  for _, name in ipairs(fake.sent) do
    if name == method then
      count = count + 1
    end
  end
  return count
end

--- A buffer for one of the clone's files that the READER owns, as they would
--- have it before the review opens: `:badd` leaves it listed but unloaded,
--- `:edit` leaves it loaded.
--- @param name string relative to the clone
--- @param load boolean
--- @return integer buffer
local function user_buffer(name, load)
  local buf = vim.fn.bufadd(clone .. '/' .. name)
  vim.bo[buf].buflisted = true
  if load then
    vim.fn.bufload(buf)
  end
  return buf
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

  it('drops the carriage return a CRLF file’s removed line carries', function()
    open_review({ two_file_block() })
    press(pane_buf(), ']c')
    local buf = pane_buf()
    ok(not has_virtual(buf, '\r'), 'a ^M is not something the file’s own lines show')
    ok(has_virtual(buf, '^%- gone$'), vim.inspect(virtuals(buf)))
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

  it('gives its own buffers no swap file', function()
    open_review({ block() })
    eq(false, vim.bo[pane_buf()].swapfile, 'a sandbox copy leaves no swap litter, and no E325 modal')
    threads.close()
  end)

  it('closing the pane window closes the review rather than wedging it', function()
    open_review({ block() })
    vim.api.nvim_win_close(threads.view().pane_win, true)
    vim.wait(200, function()
      return threads.view().tab == nil
    end)
    eq(nil, threads.view().tab, 'a review with a dead pane answers nothing, so it goes down')
    eq({}, reviewbuf.buffers())
  end)
end)

--- The buffer the reader already had is theirs. Ownership decides whether it
--- is wiped or handed back — never whether the read-only contract applies.
describe('a file the reader already had open', function()
  it('locks it for the review and hands it back exactly as it was', function()
    local buf = user_buffer('pool.lua', true)
    eq(true, vim.bo[buf].modifiable)
    open_review({ block() })
    eq(buf, pane_buf(), 'the review shows the reader’s own buffer')
    eq(false, vim.bo[buf].modifiable, 'the clone is not editable from the review tab')
    eq(true, vim.bo[buf].readonly)
    eq(false, pcall(vim.api.nvim_buf_set_lines, buf, 0, 1, false, { 'PWNED' }), 'a write is refused')
    threads.close()
    ok(vim.api.nvim_buf_is_valid(buf), 'and it survives the review')
    eq(true, vim.bo[buf].modifiable, 'with the options it came with')
    eq(false, vim.bo[buf].readonly)
    eq(FILES['pool.lua'], vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('re-applies the lock on every redraw, not only the first', function()
    open_review({ block() })
    local buf = pane_buf()
    vim.bo[buf].modifiable = true
    press(buf, 't')
    press(threads.view().pane_buf, 't')
    eq(buf, pane_buf())
    eq(false, vim.bo[buf].modifiable, 'showing an already-open file re-locks it')
    threads.close()
  end)

  --- `:badd`, an arglist, a restored session: listed, not loaded. Claiming one
  --- as the review's own unlists it and wipes it on teardown.
  it('does not claim a listed-but-unloaded buffer as its own', function()
    local buf = user_buffer('pool.lua', false)
    eq(false, vim.api.nvim_buf_is_loaded(buf), 'the case is a buffer nvim has not read yet')
    open_review({ block() })
    eq(buf, pane_buf())
    eq(true, vim.bo[buf].buflisted, 'the reader’s buffer stays in :ls during the review')
    threads.close()
    ok(vim.api.nvim_buf_is_valid(buf), 'and is not wiped with the review')
    eq(true, vim.bo[buf].buflisted)
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('re-reads it when a new capture lands, with autoread off', function()
    local autoread = vim.o.autoread
    vim.o.autoread = false
    local buf = user_buffer('notes.md', true)
    local notes = block({ id = 'bn', title = 'notes', files = { 'notes.md' }, hunkIds = { 'hn' } })
    open_review({ notes })
    eq(buf, pane_buf())
    local rewritten = { '# notes', '', 'backoff notes', 'and jitter notes' }
    vim.fn.writefile(rewritten, clone .. '/notes.md')
    threads.reload(session({ notes }))
    eq(rewritten, vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'a revision rewrites the clone under the review')
    threads.close()
    vim.fn.writefile(FILES['notes.md'], clone .. '/notes.md')
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.o.autoread = autoread
  end)

  it('names one it cannot re-read instead of annotating it stale', function()
    local buf = user_buffer('notes.md', true)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { 'my own unsaved note' })
    eq(true, vim.bo[buf].modified)
    local notes = block({ id = 'bn', title = 'notes', files = { 'notes.md' }, hunkIds = { 'hn' } })
    open_review({ notes })
    local seen = with_notices(function()
      threads.reload(session({ notes }))
    end)
    ok(said(seen, 'notes%.md could not be re%-read'), vim.inspect(seen))
    eq(true, vim.bo[buf].modified, 'the reader’s unsaved edits are still theirs')
    threads.close()
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)

describe('the pane refuses to paint what it cannot vouch for', function()
  --- `@@ -1,3 +0,0 @@` — a tracked file truncated to zero bytes. It is still
  --- readable, so the hunk reaches the pane; its row used to be -1.
  it('draws a file the change emptied, and keeps drawing it', function()
    local emptied = block({ id = 'be', title = 'emptied', files = { 'empty.txt' }, hunkIds = { 'he' } })
    open_review({ emptied, block() })
    local buf = pane_buf()
    eq(clone .. '/empty.txt', vim.api.nvim_buf_get_name(buf))
    ok(has_virtual(buf, 'first'), 'the removed lines still render')
    -- The thread list redraws the pane on every cursor move; the throw this
    -- covers repeated once per keystroke.
    press(threads.view().tree_buf, ']t')
    press(threads.view().tree_buf, '[t')
    eq(clone .. '/empty.txt', vim.api.nvim_buf_get_name(pane_buf()))
    threads.close()
  end)

  it('degrades to the unified diff when the file no longer matches the capture', function()
    local drifted = block({ id = 'bd', title = 'drift', files = { 'drift.lua' }, hunkIds = { 'hd' } })
    local seen = with_notices(function()
      open_review({ drifted })
    end)
    eq(threads.view().pane_buf, pane_buf(), 'a band on a row that moved is indistinguishable from a right one')
    ok(said(seen, 'drift%.lua on disk no longer matches the captured diff'), vim.inspect(seen))
    threads.close()
  end)
end)

describe('the destructive keys on a real code surface', function()
  local function merge_reply()
    return {
      result = {
        merged = false,
        refusals = { { code = 'open-threads', message = 'a thread is still open' } },
        session = session({ block() }),
      },
    }
  end

  it('M on the file pane dispatches nothing until the reader says yes', function()
    open_review({ block() })
    local buf = pane_buf()
    vim.api.nvim_set_current_win(threads.view().pane_win)
    eq(buf, vim.api.nvim_get_current_buf(), 'the pane is a real source buffer, where M is a motion')
    fake.replies['big.merge'] = merge_reply()
    local before = sent('big.merge')
    ok(press(buf, 'M'), 'M must be bound in the file pane')
    eq(before, sent('big.merge'), 'a stray M must not merge the change')
    local float = require('nvime.confirm').current()
    ok(float ~= nil, 'it asks first')
    local seen = with_notices(function()
      ok(press(float.buf, 'y'), 'y must answer the float')
    end)
    eq(before + 1, sent('big.merge'), 'and merges once answered')
    ok(said(seen, 'not merging'), vim.inspect(seen))
    threads.close()
  end)

  it('n on the float leaves the change alone', function()
    open_review({ block() })
    vim.api.nvim_set_current_win(threads.view().pane_win)
    fake.replies['big.merge'] = merge_reply()
    local before = sent('big.merge')
    press(pane_buf(), 'M')
    local float = require('nvime.confirm').current()
    ok(float ~= nil)
    ok(press(float.buf, 'n'))
    eq(before, sent('big.merge'))
    eq(nil, require('nvime.confirm').current(), 'and the float is gone')
    threads.close()
  end)

  it('R on the file pane asks too', function()
    open_review({ block() })
    vim.api.nvim_set_current_win(threads.view().pane_win)
    local before = sent('big.rebase')
    press(pane_buf(), 'R')
    eq(before, sent('big.rebase'))
    local float = require('nvime.confirm').current()
    ok(float ~= nil)
    ok(press(float.buf, 'n'))
    threads.close()
  end)

  --- The thread list is not a navigable code surface, so nothing there is a
  --- reflex motion and the keys stay immediate.
  it('M on the thread list stays immediate', function()
    open_review({ block() })
    vim.api.nvim_set_current_win(threads.view().tree_win)
    fake.replies['big.merge'] = merge_reply()
    local before = sent('big.merge')
    with_notices(function()
      ok(press(threads.view().tree_buf, 'M'))
    end)
    eq(before + 1, sent('big.merge'))
    eq(nil, require('nvime.confirm').current())
    threads.close()
  end)
end)

describe('<CR> and the review’s own buffers', function()
  it('refuses a file the review already holds, even from the unified diff', function()
    open_review({ block() })
    local file_buf = pane_buf()
    ok(press(file_buf, 't'), 't must be bound in the file pane')
    eq(threads.view().pane_buf, pane_buf(), 'the pane is the unified diff now')
    local before = #vim.api.nvim_list_tabpages()
    local seen = with_notices(function()
      press(threads.view().pane_buf, '<CR>')
    end)
    eq(before, #vim.api.nvim_list_tabpages(), 'no ordinary tab carrying the review’s keys and lock')
    ok(said(seen, 'the review already holds pool%.lua'), vim.inspect(seen))
    ok(vim.api.nvim_buf_is_valid(file_buf))
    threads.close()
  end)
end)
