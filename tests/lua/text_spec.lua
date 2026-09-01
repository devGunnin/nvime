local t = require('harness')
local shape = require('nvime.text')

local describe, it, eq, ok, throws = t.describe, t.it, t.eq, t.ok, t.throws

describe('text.ellipsise', function()
  it('leaves anything that already fits alone', function()
    eq('short', shape.ellipsise('short', 10))
    eq('exactly10!', shape.ellipsise('exactly10!', 10))
  end)

  it('never returns more cells than it was given', function()
    for _, width in ipairs({ 2, 5, 12, 40 }) do
      local cut = shape.ellipsise(string.rep('ab', 60), width)
      ok(vim.fn.strdisplaywidth(cut) <= width, width .. ' -> ' .. cut)
    end
  end)

  it('counts cells, not bytes, so a wide title is not cut past its border', function()
    local cut = shape.ellipsise(string.rep('日', 20), 9)
    ok(vim.fn.strdisplaywidth(cut) <= 9, cut)
    ok(vim.fn.strdisplaywidth(cut) >= 7, 'and it uses the room it has: ' .. cut)
  end)

  it('refuses a width that could not hold anything', function()
    throws(function()
      shape.ellipsise('x', 0)
    end)
  end)
end)

describe('text.wrap', function()
  it('breaks prose at spaces, inside the width', function()
    local lines = shape.wrap('the quick brown fox jumps over the lazy dog', 12)
    for _, line in ipairs(lines) do
      ok(vim.fn.strdisplaywidth(line) <= 12, line)
      ok(not line:match('^%s'), 'no line starts on a space: ' .. line)
    end
    eq('the quick brown fox jumps over the lazy dog', table.concat(lines, ' '))
  end)

  it('hard-breaks a single token too long to fit rather than overflowing', function()
    local lines = shape.wrap(string.rep('x', 25), 10)
    eq(3, #lines)
    eq(string.rep('x', 25), table.concat(lines, ''))
  end)

  it('keeps the newlines it was given', function()
    eq({ 'a', 'b' }, shape.wrap('a\nb', 20))
  end)
end)

describe('text.wrap_exact', function()
  it('preserves every byte, spaces included', function()
    local payload = 'cd /tmp  &&   run --flag "a  b"'
    eq(payload, table.concat(shape.wrap_exact(payload, 7), ''))
  end)

  it('cuts by characters, so a multi-byte payload is never split in half', function()
    local lines = shape.wrap_exact(string.rep('é', 10), 4)
    eq(3, #lines)
    eq(string.rep('é', 10), table.concat(lines, ''))
  end)
end)

describe('text.tilde', function()
  it('shortens the home directory wherever it appears in a message', function()
    local home = vim.uv.os_homedir()
    ok(home ~= nil and home ~= '', 'this test needs a home directory')
    eq('built: ~/a/b', shape.tilde('built: ' .. home .. '/a/b'))
  end)

  it('leaves a path outside home untouched', function()
    eq('/usr/bin/node', shape.tilde('/usr/bin/node'))
  end)
end)
