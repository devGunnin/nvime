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
  it('renders a passing check on one line, with no fix to show', function()
    local lines = doctor.render_entry({ level = 'ok', message = 'node v22.22.2' })
    eq(1, #lines)
    ok(lines[1]:find('OK', 1, true) ~= nil, lines[1])
    ok(lines[1]:find('node v22%.22%.2') ~= nil, lines[1])
  end)

  it('renders a failure with its fix on the line under it', function()
    local lines = doctor.render_entry({ level = 'error', message = 'no git identity', advice = 'git config ...' })
    eq(2, #lines)
    ok(lines[1]:find('FAIL', 1, true) ~= nil, lines[1])
    ok(lines[1]:find('no git identity', 1, true) ~= nil, lines[1])
    ok(lines[2]:find('fix: git config ...', 1, true) ~= nil, lines[2])
  end)

  it('carries no fix line for a warning with none to show', function()
    eq(1, #doctor.render_entry({ level = 'warn', message = 'a nudge with no advice' }))
  end)

  it('distinguishes info from ok, warn and error', function()
    local lines = doctor.render_entry({ level = 'info', message = 'a sidecar is already running' })
    ok(lines[1]:find('OK') == nil, lines[1])
    ok(lines[1]:find('FAIL') == nil, lines[1])
    ok(lines[1]:find('WARN') == nil, lines[1])
  end)
end)

describe('doctor.render', function()
  it('says all clear when nothing failed or warned', function()
    local lines = doctor.render({ { level = 'ok', message = 'a' } })
    eq(' all clear', lines[#lines])
  end)

  it('counts warnings when nothing failed', function()
    local lines = doctor.render({ { level = 'warn', message = 'a' } })
    eq(' all clear except 1 warning', lines[#lines])
  end)

  it('leads with the failure count once something failed', function()
    local lines = doctor.render({
      { level = 'error', message = 'a' },
      { level = 'warn', message = 'b' },
    })
    eq(' 1 failing, 1 warning — fix the failures above first', lines[#lines])
  end)

  it('titles the page and renders every entry in order', function()
    local lines = doctor.render({
      { level = 'ok', message = 'first' },
      { level = 'error', message = 'second', advice = 'do this' },
    })
    eq(' nvime doctor', lines[1])
    local text = table.concat(lines, '\n')
    ok(text:find('first') < text:find('second'), text)
    ok(text:find('do this', 1, true) ~= nil, text)
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
