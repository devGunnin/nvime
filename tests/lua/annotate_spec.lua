local t = require('harness')
local annotate = require('nvime.annotate')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

describe('locating a hunk in the post-change file', function()
  it('reads the new-side start off the header', function()
    eq(3, annotate.new_start('@@ -1,5 +3,6 @@'))
    eq(1, annotate.new_start('@@ -1 +1 @@'))
    eq(12, annotate.new_start('@@ -9,0 +12,2 @@ function M.next_delay(attempt)'))
  end)

  it('refuses anything that is not a hunk header', function()
    eq(nil, annotate.new_start('+++ b/pool.lua'))
    eq(nil, annotate.new_start('@@ pool.png @@'))
    eq(nil, annotate.new_start(nil))
    eq(nil, annotate.hunk_marks('--- a/pool.lua', {}))
  end)
end)

describe('what a hunk marks on the file', function()
  it('bands a pure addition and starts on the first added row', function()
    local marks = annotate.hunk_marks('@@ -1,2 +1,3 @@', { ' one', '', '+three' })
    eq({ { row = 2, hl = 'NvimeEditAdd' } }, marks.bands)
    eq({}, marks.removals)
    eq(2, marks.row)
  end)

  it('bands a replaced run as a change, and hangs what it replaced above it', function()
    local marks = annotate.hunk_marks('@@ -1,4 +1,5 @@', {
      ' keep',
      '-  return 2 ^ attempt',
      '+  local base = 2 ^ attempt',
      '+  return base',
      ' end',
    })
    eq({ { row = 1, hl = 'NvimeEditChange' }, { row = 2, hl = 'NvimeEditChange' } }, marks.bands)
    eq({ { row = 1, lines = { '  return 2 ^ attempt' } } }, marks.removals)
    eq(1, marks.row)
  end)

  it('anchors a pure deletion on the line that closed over it', function()
    local marks = annotate.hunk_marks('@@ -1,3 +1,2 @@', { ' one', '-two', ' three' })
    eq({}, marks.bands)
    eq({ { row = 1, lines = { 'two' } } }, marks.removals)
    eq(1, marks.row)
  end)

  --- The row a deletion at the end of the file would anchor to does not exist.
  --- `reviewbuf` is what clamps it; what matters here is that the row is
  --- reported past the end rather than silently pulled back onto a real line.
  it('reports a deletion past the last line at the row past the end', function()
    local marks = annotate.hunk_marks('@@ -1,2 +1 @@', { ' keep', '-gone' })
    eq({ { row = 1, lines = { 'gone' } } }, marks.removals)
  end)

  it('an add after a context line is an add again, not a change', function()
    local marks = annotate.hunk_marks('@@ -1,3 +1,4 @@', { '-old', '+new', ' between', '+extra' })
    eq({ { row = 0, hl = 'NvimeEditChange' }, { row = 2, hl = 'NvimeEditAdd' } }, marks.bands)
  end)

  it('counts neither side for the no-newline marker', function()
    local marks = annotate.hunk_marks('@@ -1,2 +1,2 @@', { ' one', '-two', '\\ No newline at end of file', '+two!' })
    eq({ { row = 1, hl = 'NvimeEditChange' } }, marks.bands)
    eq({ { row = 1, lines = { 'two' } } }, marks.removals)
  end)

  --- What `git diff` emits for a tracked file truncated to zero bytes: the
  --- new side starts at 0, so the row before it is -1 — which raises out of
  --- the draw instead of degrading it.
  it('anchors a file emptied by the change at row 0, never below it', function()
    local marks = annotate.hunk_marks('@@ -1,2 +0,0 @@', { '-first', '-second' })
    eq(0, marks.row)
    eq({}, marks.bands)
    eq({ { row = 0, lines = { 'first', 'second' } } }, marks.removals)
  end)
end)

describe('the line a hunk can be checked against', function()
  it('offers a + line, whose row and text the patch both fix', function()
    local marks = annotate.hunk_marks('@@ -1,3 +1,4 @@', { ' one', '-old', '+new', ' three' })
    eq({ row = 1, text = 'new' }, marks.check)
  end)

  it('falls back to a context line when the hunk adds nothing', function()
    local marks = annotate.hunk_marks('@@ -1,4 +1,3 @@', { '', ' two', '-three', ' four' })
    eq({ row = 1, text = 'two' }, marks.check, 'the blank first line proves nothing and is skipped')
  end)

  it('offers nothing for a hunk with neither', function()
    eq(nil, annotate.hunk_marks('@@ -1,2 +0,0 @@', { '-first', '-second' }).check)
  end)

  --- Drift between two whitespace-only rows is invisible, and blank-ish rows
  --- are common enough in a real diff that accepting one is accepting nothing.
  it('skips a whitespace-only context line the same as an empty one', function()
    local marks = annotate.hunk_marks('@@ -1,4 +1,3 @@', { '    ', ' two', '-three', ' four' })
    eq({ row = 1, text = 'two' }, marks.check)
    eq(nil, annotate.hunk_marks('@@ -1,3 +1,2 @@', { '   ', '-gone', '  ' }).check)
  end)

  it('drops the line ending a CRLF file keeps out of the buffer', function()
    eq('local M = {}', annotate.strip_cr('local M = {}\r'))
    eq('a\rb', annotate.strip_cr('a\rb'), 'only a trailing one')
  end)
end)

describe('a rendered line as virtual-line chunks', function()
  it('gives each mark its own span and the rest the fill', function()
    eq(
      { { 'you · ', 'NvimeUser' }, { 'my answer', 'NvimeBody' } },
      annotate.chunks('you · my answer', {
        { col = 0, end_col = 7, hl = 'NvimeUser' },
        { col = 7, end_col = 16, hl = 'NvimeBody' },
      })
    )
  end)

  it('sorts marks it was handed out of order', function()
    local chunks = annotate.chunks('ab', { { col = 1, end_col = 2, hl = 'B' }, { col = 0, end_col = 1, hl = 'A' } })
    eq({ { 'a', 'A' }, { 'b', 'B' } }, chunks)
  end)

  it('takes a whole-line band as the fill, since a virtual line has no row background', function()
    eq({ { 'plain', 'NvimeAgentBody' } }, annotate.chunks('plain', { { hl = 'NvimeAgentBody' } }))
  end)

  --- Emitting an overlapped span twice would print the same bytes twice and
  --- push the rest of the line right.
  it('never emits a byte twice when two marks overlap', function()
    local chunks = annotate.chunks('abcd', { { col = 0, end_col = 3, hl = 'A' }, { col = 1, end_col = 4, hl = 'B' } })
    local text = ''
    for _, chunk in ipairs(chunks) do
      text = text .. chunk[1]
    end
    eq('abcd', text)
  end)

  it('renders an empty line as an empty chunk list', function()
    eq({}, annotate.chunks('', nil))
  end)

  it('splits a block by mark row', function()
    local lines = annotate.virt_lines({ 'head', 'body' }, { { row = 0, col = 0, end_col = 4, hl = 'NvimeHeading' } })
    eq(2, #lines)
    eq({ { 'head', 'NvimeHeading' } }, lines[1])
    eq({ { 'body', nil } }, lines[2])
    ok(lines[2][1][2] == nil, 'an unmarked span carries no highlight')
  end)
end)
