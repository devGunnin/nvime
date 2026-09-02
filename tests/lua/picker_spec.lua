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

describe('picker.open: deleting a row', function()
  local function feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, true, true), 'x', false)
  end

  it('confirms with a y/n float, never a blocking modal, before deleting', function()
    local deleted = {}
    local win = picker.open(items(2), {
      on_choice = function() end,
      on_delete = function(value, done)
        deleted[#deleted + 1] = value
        done(true)
      end,
    })
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    feed('d')
    ok(#vim.api.nvim_list_wins() >= 2, 'the confirm prompt is a real float, not a blocking vim.fn.confirm')
    eq({}, deleted, 'nothing is deleted until the float is answered')

    feed('y')
    eq({ 'id-1' }, deleted)
    ok(vim.api.nvim_win_is_valid(win), 'the picker stays open after one deletion')
    local remaining = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
    eq(1, #remaining, 'the deleted row is gone')
    vim.api.nvim_win_close(win, true)
  end)

  it('leaves the row alone on n, q, or <Esc>', function()
    local deleted = {}
    for _, dismiss_key in ipairs({ 'n', 'q', '<Esc>' }) do
      local win = picker.open(items(1), {
        on_choice = function() end,
        on_delete = function(value, done)
          deleted[#deleted + 1] = value
          done(true)
        end,
      })
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      feed('d')
      feed(dismiss_key)
      eq({}, deleted, dismiss_key .. ' must not delete')
      ok(vim.api.nvim_win_is_valid(win), dismiss_key .. ' must not close the picker itself')
      vim.api.nvim_win_close(win, true)
    end
  end)

  it('closes the picker instead of leaving an empty list once the last row goes', function()
    local win = picker.open(items(1), {
      on_choice = function() end,
      on_delete = function(_, done)
        done(true)
      end,
    })
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    feed('d')
    feed('y')
    ok(not vim.api.nvim_win_is_valid(win), 'no rows left to show')
  end)

  it('opts an item out of deletion with deletable = false', function()
    local deleted = {}
    local win = picker.open({ { label = 'new conversation', value = 'new', deletable = false } }, {
      on_choice = function() end,
      on_delete = function(value, done)
        deleted[#deleted + 1] = value
        done(true)
      end,
    })
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    feed('d')
    eq({}, deleted, 'a non-deletable row ignores d entirely — no confirm float either')
    ok(vim.api.nvim_win_is_valid(win))
    vim.api.nvim_win_close(win, true)
  end)

  it('keeps the row when the deletion itself fails', function()
    local win = picker.open(items(1), {
      on_choice = function() end,
      on_delete = function(_, done)
        done(false)
      end,
    })
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    feed('d')
    feed('y')
    ok(vim.api.nvim_win_is_valid(win))
    eq(1, #vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), 'the row survives a failed delete')
    vim.api.nvim_win_close(win, true)
  end)

  it('does nothing on d when the picker was not given on_delete', function()
    local win = picker.open(items(1), { on_choice = function() end })
    vim.api.nvim_win_set_cursor(win, { 1, 0 })
    feed('d')
    ok(vim.api.nvim_win_is_valid(win), 'd is inert without on_delete, not an error')
    vim.api.nvim_win_close(win, true)
  end)
end)

describe('picker highlighting', function()
  it('dims the metadata column and marks the session already resumed', function()
    local win = picker.open({
      { label = '15m ago     first prompt', lead = 12, value = 'a' },
      { label = '2h ago      second prompt', lead = 12, current = true, value = 'b' },
    }, { on_choice = function() end })
    local buf = vim.api.nvim_win_get_buf(win)
    local ns = vim.api.nvim_create_namespace('nvime.picker')
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    local groups = {}
    for _, mark in ipairs(marks) do
      groups[mark[4].hl_group] = (groups[mark[4].hl_group] or 0) + 1
    end
    eq(2, groups.NvimeDim, 'both ages are dimmed')
    eq(1, groups.NvimeSelected, 'only the resumed session is marked')
    vim.api.nvim_win_close(win, true)
  end)
end)
