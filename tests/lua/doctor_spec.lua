local t = require('harness')
local diagnostics = require('nvime.diagnostics')
local doctor = require('nvime.doctor')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Swaps `diagnostics.run` for the duration of `fn`, restoring it after —
--- `doctor.lua` holds the same module table, so this reaches its calls too.
local function with_entries(entries, fn)
  local real = diagnostics.run
  diagnostics.run = function()
    return entries
  end
  local finished, err = pcall(fn)
  diagnostics.run = real
  if not finished then
    error(err, 0)
  end
end

describe('doctor.render_entry', function()
  local icons = require('nvime.icons')

  it('renders a passing check on one line, with no fix to show', function()
    local lines, hl = doctor.render_entry({ level = 'ok', message = 'node v22.22.2' })
    eq(1, #lines)
    ok(lines[1]:find(icons.get().ok, 1, true) ~= nil, lines[1])
    ok(lines[1]:find('node v22%.22%.2') ~= nil, lines[1])
    eq('NvimeOk', hl)
  end)

  it('renders a failure with its fix on the line under it', function()
    local lines, hl = doctor.render_entry({ level = 'error', message = 'no git identity', advice = 'git config ...' })
    eq(2, #lines)
    ok(lines[1]:find(icons.get().fail, 1, true) ~= nil, lines[1])
    ok(lines[1]:find('no git identity', 1, true) ~= nil, lines[1])
    ok(lines[2]:find('fix: git config ...', 1, true) ~= nil, lines[2])
    eq('NvimeError', hl)
  end)

  it('carries no fix line for a warning with none to show', function()
    eq(1, #doctor.render_entry({ level = 'warn', message = 'a nudge with no advice' }))
  end)

  it('gives each level its own symbol and colour', function()
    local seen = {}
    for _, level in ipairs({ 'ok', 'warn', 'error', 'info' }) do
      local lines, hl = doctor.render_entry({ level = level, message = 'a check' })
      ok(seen[lines[1]:sub(1, 4)] == nil, 'two levels share a symbol: ' .. level)
      seen[lines[1]:sub(1, 4)] = true
      ok(hl ~= nil, level)
    end
  end)

  it('wraps a long message under the gutter instead of past the border', function()
    local lines = doctor.render_entry({ level = 'ok', message = string.rep('token ', 40) }, 40)
    ok(#lines > 1, 'a long message must wrap')
    for _, line in ipairs(lines) do
      ok(vim.fn.strdisplaywidth(line) <= 40, line)
    end
  end)

  it('writes a path under the home directory with a tilde', function()
    local home = vim.uv.os_homedir()
    local lines = doctor.render_entry({ level = 'ok', message = 'sidecar built: ' .. home .. '/x/dist.js' })
    ok(table.concat(lines, ' '):find('~/x/dist.js', 1, true) ~= nil, lines[1])
  end)
end)

describe('doctor.render', function()
  --- The summary sits above the page's trailing blank line.
  local function summary(lines)
    return lines[#lines - 1]
  end

  it('says all clear when nothing failed or warned', function()
    eq(' all clear', summary(doctor.render({ { level = 'ok', message = 'a' } })))
  end)

  it('counts warnings when nothing failed', function()
    eq(' all clear except 1 warning', summary(doctor.render({ { level = 'warn', message = 'a' } })))
  end)

  it('leads with the failure count once something failed', function()
    local lines = doctor.render({
      { level = 'error', message = 'a' },
      { level = 'warn', message = 'b' },
    })
    eq(' 1 failing, 1 warning — fix the failures above first', summary(lines))
  end)

  it('renders every entry in order, with a mark per line', function()
    local lines, marks = doctor.render({
      { level = 'ok', message = 'first' },
      { level = 'error', message = 'second', advice = 'do this' },
    })
    local text = table.concat(lines, '\n')
    ok(text:find('first') < text:find('second'), text)
    ok(text:find('do this', 1, true) ~= nil, text)
    ok(#marks >= 3, 'each entry marks its symbol, and the summary is marked too')
    for _, mark in ipairs(marks) do
      ok(mark.row >= 0 and mark.row < #lines, vim.inspect(mark))
    end
  end)

  it('never emits a mark past the byte length of its own line', function()
    -- Version-independent: nvim_buf_set_extmark rejects this shape on 0.11
    -- even with strict=false, while 0.12 silently clamps it — catch it here
    -- regardless of which nvim is running the suite.
    local lines, marks = doctor.render({
      { level = 'ok', message = 'first' },
      { level = 'error', message = 'second', advice = 'do this' },
    })
    for _, mark in ipairs(marks) do
      local line = lines[mark.row + 1]
      ok(line ~= nil, 'mark row ' .. mark.row .. ' has no line')
      ok(mark.col <= mark.end_col, 'end_col before col: ' .. vim.inspect(mark))
      ok(mark.end_col <= #line, 'end_col past the line: ' .. vim.inspect(mark) .. ' line=' .. vim.inspect(line))
    end
  end)
end)

describe('doctor.open', function()
  it('opens a float rendering the current diagnostics', function()
    with_entries({ { level = 'ok', message = 'node v22.22.2' } }, function()
      doctor.open()
      local float = doctor.current()
      ok(float.win ~= nil and vim.api.nvim_win_is_valid(float.win))
      local text = table.concat(vim.api.nvim_buf_get_lines(float.buf, 0, -1, false), '\n')
      ok(text:find('node v22%.22%.2') ~= nil, text)
      doctor.close()
    end)
  end)

  it('closes the previous float rather than stacking a second one', function()
    with_entries({}, function()
      doctor.open()
      local first = doctor.current().win
      doctor.open()
      local second = doctor.current().win
      ok(first ~= second, 'a fresh window replaces the old one')
      ok(not vim.api.nvim_win_is_valid(first), 'the old window is gone')
      doctor.close()
    end)
  end)

  it('goes away on q', function()
    with_entries({}, function()
      doctor.open()
      vim.api.nvim_set_current_win(doctor.current().win)
      vim.cmd('normal ' .. vim.api.nvim_replace_termcodes('q', true, true, true))
      eq(nil, doctor.current().win)
    end)
  end)
end)
