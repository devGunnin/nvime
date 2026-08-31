local t = require('harness')
local picker = require('nvime.picker')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local function items(count)
  local out = {}
  for i = 1, count do
    out[i] = { label = string.format('session %02d — an unremarkable title', i), value = 'id-' .. i }
  end
  return out
end

--- Runs `fn` on a terminal of the given size, then puts the real one back.
local function on_terminal(lines, columns, fn)
  local real_lines, real_columns = vim.o.lines, vim.o.columns
  vim.o.lines, vim.o.columns = lines, columns
  local okay, err = pcall(fn)
  vim.o.lines, vim.o.columns = real_lines, real_columns
  if not okay then
    error(err, 0)
  end
end

describe('picker.open', function()
  it('opens a float and reports nothing to choose from an empty list', function()
    eq(nil, picker.open({}, { on_choice = function() end }))
  end)

  it('demands a choice callback rather than dropping the pick', function()
    t.throws(function()
      picker.open(items(2), {})
    end, 'on_choice')
  end)

  it('fits a terminal shorter than the list instead of throwing', function()
    -- `row = (lines - height) / 2` used to go negative here, and nvim_open_win
    -- throws out of the RPC callback that opened the picker.
    on_terminal(6, 40, function()
      local win = picker.open(items(12), { title = ' sessions ', on_choice = function() end })
      ok(win ~= nil and vim.api.nvim_win_is_valid(win), 'the float opened')
      local config = vim.api.nvim_win_get_config(win)
      ok(config.row >= 0, 'row ' .. tostring(config.row))
      ok(config.col >= 0, 'col ' .. tostring(config.col))
      ok(config.height <= 6, 'the float fits on screen')
      vim.api.nvim_win_close(win, true)
    end)
  end)

  it('hands back the chosen value, not the row it was on', function()
    local chosen = nil
    local win = picker.open(items(3), {
      on_choice = function(value)
        chosen = value
      end,
    })
    ok(win ~= nil)
    vim.api.nvim_win_set_cursor(win, { 2, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, true, true), 'x', false)
    eq('id-2', chosen)
  end)
end)
