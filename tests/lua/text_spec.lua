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

  --- The chunker used to hard-break by characters
  --- (`strcharpart(current, 0, width)`), so a `width`-character chunk of a
  --- wide script could be up to twice `width` cells.
  it('hard-breaks a wide-character token by cells, not characters', function()
    local lines = shape.wrap(string.rep('删', 30), 10)
    for i, line in ipairs(lines) do
      ok(vim.fn.strdisplaywidth(line) <= 10, i .. ': ' .. vim.fn.strdisplaywidth(line) .. ' cells: ' .. line)
    end
    eq(string.rep('删', 30), table.concat(lines, ''))
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

  --- The chunker used to cut by characters (`strcharpart(line, at, width)`),
  --- so a `width`-character chunk of CJK text could be twice `width` cells —
  --- exactly the defect that let a wide payload push past the approval
  --- float's border.
  it('cuts by display cells, so a CJK payload never overflows the width it was given', function()
    local payload = string.rep('删', 30)
    local lines = shape.wrap_exact(payload, 10)
    for i, line in ipairs(lines) do
      ok(vim.fn.strdisplaywidth(line) <= 10, i .. ': ' .. vim.fn.strdisplaywidth(line) .. ' cells: ' .. line)
    end
    eq(payload, table.concat(lines, ''), 'every character still comes back, just re-cut')
  end)

  --- A raw tab can cost up to 8 cells; treating it as one is how a
  --- tab-laden command overflowed a float sized by character count.
  it('expands a tab so it cannot cost more than its display width', function()
    local lines = shape.wrap_exact('a\tb\tc\td\te\tf\tg\th\ti\tj', 10)
    for i, line in ipairs(lines) do
      ok(vim.fn.strdisplaywidth(line) <= 10, i .. ': ' .. vim.fn.strdisplaywidth(line) .. ' cells: ' .. line)
    end
  end)
end)

describe('text.wrap_exact performance', function()
  --- A tab-indented heredoc as one long line — no embedded newline, so
  --- `wrap_exact` cannot split the work into small per-line pieces and the
  --- full 8KiB hits `cell_chunks`/`expand_tabs` in one call, ~10% tabs.
  --- Matches the shape the merge-gate review measured at 251ms against the
  --- quadratic `strcharpart`-per-char wrap (and 8138ms at 64KiB) — the
  --- sidecar's own `MAX_DETAIL_BYTES` cap (agent/src/stream.ts) is what an
  --- approval payload is bounded to.
  local function heredoc_fixture(bytes)
    local parts, size, i = {}, 0, 0
    while size < bytes do
      local chunk = (i % 10 == 0) and '\t\t\t' or ('var_' .. i .. '=value ')
      parts[#parts + 1] = chunk
      size = size + #chunk
      i = i + 1
    end
    return table.concat(parts):sub(1, bytes)
  end

  it('wraps an 8KiB tab-indented payload well under the approval float stall bound', function()
    local payload = heredoc_fixture(8192)
    ok(#payload == 8192, 'fixture must actually hit the sidecar cap')
    local start = vim.uv.hrtime()
    local lines = shape.wrap_exact(payload, 88)
    local elapsed_ms = (vim.uv.hrtime() - start) / 1e6
    -- Generous and CI-safe: the fix measures under 20ms locally, the old
    -- quadratic scan measured 251ms on this exact shape.
    ok(elapsed_ms < 200, string.format('wrap_exact took %.1fms, want < 200ms', elapsed_ms))
    ok(#lines > 0, 'must still produce output')
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
