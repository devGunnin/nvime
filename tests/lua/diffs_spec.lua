local t = require('harness')
local diffs = require('nvime.diffs')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Applies every hunk of `before` -> `after` the way `apply` does, so the
--- decoding of vim.diff's index convention is checked against a real result.
local function replay(before, after)
  local lines = diffs.to_lines(before)
  local _, eol = diffs.to_lines(after)
  local after_lines = diffs.to_lines(after)
  local hunks = diffs.hunks(before, after)
  for i = #hunks, 1, -1 do
    local edit = diffs.buffer_edit(hunks[i], after_lines)
    local rebuilt = {}
    vim.list_extend(rebuilt, lines, 1, edit.first)
    vim.list_extend(rebuilt, edit.lines)
    vim.list_extend(rebuilt, lines, edit.last + 1, #lines)
    lines = rebuilt
  end
  return diffs.to_text(lines, eol)
end

describe('diffs.to_lines / to_text', function()
  it('round-trips a file that ends with a newline', function()
    local lines, eol = diffs.to_lines('a\nb\n')
    eq({ 'a', 'b' }, lines)
    eq(true, eol)
    eq('a\nb\n', diffs.to_text(lines, eol))
  end)

  it('round-trips a file with no final newline', function()
    local lines, eol = diffs.to_lines('a\nb')
    eq({ 'a', 'b' }, lines)
    eq(false, eol)
    eq('a\nb', diffs.to_text(lines, eol))
  end)

  it('round-trips an empty file and a lone newline', function()
    eq('', diffs.to_text(diffs.to_lines('')))
    local lines, eol = diffs.to_lines('\n')
    eq({ '' }, lines)
    eq('\n', diffs.to_text(lines, eol))
  end)
end)

describe('diffs.buffer_edit', function()
  it('rebuilds the new text from the hunks alone — replacement', function()
    eq('one\n2\nthree\n', replay('one\ntwo\nthree\n', 'one\n2\nthree\n'))
  end)

  it('rebuilds the new text from the hunks alone — append', function()
    eq('one\ntwo\nthree\n', replay('one\ntwo\n', 'one\ntwo\nthree\n'))
  end)

  it('rebuilds the new text from the hunks alone — prepend', function()
    eq('zero\none\ntwo\n', replay('one\ntwo\n', 'zero\none\ntwo\n'))
  end)

  it('rebuilds the new text from the hunks alone — deletion', function()
    eq('one\nthree\n', replay('one\ntwo\nthree\n', 'one\nthree\n'))
  end)

  it('rebuilds the new text from the hunks alone — several hunks at once', function()
    local before = 'a\nb\nc\nd\ne\nf\ng\nh\ni\nj\n'
    local after = 'a\nB\nc\nd\ne\nf\ng\nh\nJ\nextra\n'
    eq(after, replay(before, after))
  end)
end)

describe('diffs.changed_rows', function()
  it('marks the new lines of an insertion as added', function()
    local hunks = diffs.hunks('a\nc\n', 'a\nb\nc\n')
    local rows, kind = diffs.changed_rows(hunks[1], 3)
    eq({ 1 }, rows)
    eq('add', kind)
  end)

  it('marks a replacement as a change', function()
    local hunks = diffs.hunks('a\nb\n', 'a\nB\n')
    local rows, kind = diffs.changed_rows(hunks[1], 2)
    eq({ 1 }, rows)
    eq('change', kind)
  end)

  it('marks the surviving neighbour of a deletion, clamped to the buffer', function()
    local hunks = diffs.hunks('a\nb\nc\n', 'a\nc\n')
    local rows, kind = diffs.changed_rows(hunks[1], 2)
    eq('delete', kind)
    eq(1, #rows)
    ok(rows[1] >= 0 and rows[1] < 2, 'the marked row is inside the buffer')
  end)
end)

describe('diffs.locate', function()
  local before = 'a\nb\nc\nd\ne\n'
  local after = 'a\nB\nc\nD\ne\n'

  it('is a no-op offset when the file is untouched since', function()
    eq(0, diffs.locate(after, after, 2, 1))
  end)

  it('shifts a hunk that unrelated edits above it moved', function()
    local hunks = diffs.hunks(before, after)
    local current = 'zero\n' .. after
    local offset = diffs.locate(after, current, hunks[2][3], hunks[2][4])
    eq(1, offset, 'a line added above moves the later hunk down by one')
  end)

  it('refuses when the hunk lines themselves were hand-edited', function()
    local hunks = diffs.hunks(before, after)
    local current = 'a\nB\nc\nD-by-hand\ne\n'
    local offset, reason = diffs.locate(after, current, hunks[2][3], hunks[2][4])
    eq(nil, offset)
    ok(reason:find('edited since') ~= nil, 'and says why')
  end)

  it('guards the anchor line of a pure deletion', function()
    -- Deleting 'b' anchors on 'a': editing 'a' means the insertion point is
    -- no longer the one the hunk described.
    local hunks = diffs.hunks('a\nb\nc\n', 'a\nc\n')
    local offset = diffs.locate('a\nc\n', 'A\nc\n', hunks[1][3], hunks[1][4])
    eq(nil, offset)
  end)

  it('still locates a deletion when only the line after it was edited', function()
    local hunks = diffs.hunks('a\nb\nc\n', 'a\nc\n')
    eq(0, diffs.locate('a\nc\n', 'a\nCHANGED\n', hunks[1][3], hunks[1][4]))
  end)
end)

describe('diffs.reverse_edit', function()
  it('is the exact inverse of buffer_edit for a single hunk', function()
    local before, after = 'one\ntwo\nthree\n', 'one\n2\nthree\n'
    local hunk = diffs.hunks(before, after)[1]
    local reverse = diffs.reverse_edit(hunk, diffs.to_lines(before), 0)
    local lines = diffs.to_lines(after)
    local rebuilt = {}
    vim.list_extend(rebuilt, lines, 1, reverse.first)
    vim.list_extend(rebuilt, reverse.lines)
    vim.list_extend(rebuilt, lines, reverse.last + 1, #lines)
    eq(before, diffs.to_text(rebuilt, true))
  end)

  it('undoes an insertion by deleting the lines it added', function()
    local before, after = 'a\nc\n', 'a\nb\nc\n'
    local hunk = diffs.hunks(before, after)[1]
    local reverse = diffs.reverse_edit(hunk, diffs.to_lines(before), 0)
    eq({}, reverse.lines)
    eq(1, reverse.first)
    eq(2, reverse.last)
  end)
end)

describe('diffs.unified', function()
  it('renders a header and the changed lines', function()
    local text = diffs.unified('queue.py', 'a\nb\n', 'a\nB\n')
    ok(text:find('--- a/queue.py', 1, true) ~= nil)
    ok(text:find('+++ b/queue.py', 1, true) ~= nil)
    ok(text:find('\n-b', 1, true) ~= nil, 'the removed line is shown')
    ok(text:find('\n+B', 1, true) ~= nil, 'and the added one')
  end)

  it('says so plainly when there is no textual change', function()
    ok(diffs.unified('a.txt', 'same\n', 'same\n'):find('no textual change', 1, true) ~= nil)
  end)
end)
