local t = require('harness')
local explain = require('nvime.explain')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local function fresh()
  explain.close()
end

describe('explain.render', function()
  it('wraps a long line to the given width, keeping every character', function()
    local text = string.rep('x', 200)
    local wrapped = explain.render(text, 76)
    eq(200, #table.concat(wrapped), 'every character survives the wrap')
    ok(#wrapped > 1, 'a 200-char line must wrap over more than one row')
    for _, line in ipairs(wrapped) do
      ok(vim.fn.strchars(line) <= 76, 'no row exceeds the width')
    end
  end)

  it("keeps the explanation's own paragraph breaks", function()
    local wrapped = explain.render('first paragraph\n\nsecond paragraph', 76)
    eq({ 'first paragraph', '', 'second paragraph' }, wrapped)
  end)

  it('renders an empty string as one blank row rather than nothing', function()
    eq({ '' }, explain.render('', 76))
  end)
end)

describe('explain.pending / explain.show', function()
  it('opens a float with a placeholder, then replaces it with the answer', function()
    fresh()
    explain.pending('add a --version flag')
    local float = explain.current()
    ok(float ~= nil, 'pending opens a float')
    ok(
      vim.api.nvim_buf_get_lines(float.buf, 0, -1, false)[1]:find('asking claude', 1, true) ~= nil,
      'a placeholder is shown while the turn runs'
    )

    explain.show('add a --version flag', 'it adds a --version flag that prints and exits early.')
    local lines = vim.api.nvim_buf_get_lines(explain.current().buf, 0, -1, false)
    ok(table.concat(lines, '\n'):find('prints and exits early', 1, true) ~= nil)
    fresh()
  end)

  it('renders a failure message in place of an explanation', function()
    fresh()
    explain.show('mixed', '! the agent turn failed')
    local lines = vim.api.nvim_buf_get_lines(explain.current().buf, 0, -1, false)
    eq({ '! the agent turn failed' }, lines)
    fresh()
  end)

  it('closes the previous float rather than stacking a second one', function()
    fresh()
    explain.pending('one')
    local first = explain.current().win
    explain.pending('two')
    local second = explain.current().win
    ok(first ~= second, 'a fresh window replaces the old one')
    ok(not vim.api.nvim_win_is_valid(first), 'the old window is gone')
    fresh()
  end)

  it('goes away on q, without pretending the user answered anything', function()
    fresh()
    explain.show('mixed', 'an explanation')
    local buf = explain.current().buf
    vim.api.nvim_set_current_win(explain.current().win)
    vim.cmd('normal ' .. vim.api.nvim_replace_termcodes('q', true, true, true))
    eq(nil, explain.current())
    ok(not vim.api.nvim_buf_is_valid(buf), 'and its buffer is wiped')
  end)
end)
