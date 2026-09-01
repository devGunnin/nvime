local t = require('harness')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

package.loaded['nvime.statusline'] = nil
local statusline = require('nvime.statusline')

local real = {
  chat = package.loaded['nvime.chat'],
  edit = package.loaded['nvime.edit'],
  big = package.loaded['nvime.big'],
}

--- Stands in for chat/edit/big: only `is_running` and `state` are read.
local function fake(overrides)
  return vim.tbl_extend('force', {
    is_running = function()
      return false
    end,
    state = function()
      return {}
    end,
  }, overrides or {})
end

--- Installs fakes for the three surfaces `statusline.get` reads, restoring
--- the real modules once `fn` returns (or throws).
local function with_surfaces(overrides, fn)
  package.loaded['nvime.chat'] = fake(overrides.chat)
  package.loaded['nvime.edit'] = fake(overrides.edit)
  package.loaded['nvime.big'] = fake(overrides.big)
  local finished, err = pcall(fn)
  package.loaded['nvime.chat'] = real.chat
  package.loaded['nvime.edit'] = real.edit
  package.loaded['nvime.big'] = real.big
  if not finished then
    error(err, 0)
  end
end

describe('statusline.get', function()
  it('reports nothing when every surface is idle', function()
    with_surfaces({}, function()
      eq('', statusline.get())
    end)
  end)

  it('shows a running chat turn', function()
    with_surfaces({ chat = {
      is_running = function()
        return true
      end,
    } }, function()
      eq('nvime: chat●', statusline.get())
    end)
  end)

  it('shows the hunk tally of a running edit, singular and plural', function()
    with_surfaces({
      edit = {
        is_running = function()
          return true
        end,
        state = function()
          return { tally = { hunks = 1 } }
        end,
      },
    }, function()
      eq('nvime: edit 1 hunk', statusline.get())
    end)
    with_surfaces({
      edit = {
        is_running = function()
          return true
        end,
        state = function()
          return { tally = { hunks = 2 } }
        end,
      },
    }, function()
      eq('nvime: edit 2 hunks', statusline.get())
    end)
  end)

  it("shows the selected big change's gate progress", function()
    with_surfaces({
      big = {
        state = function()
          return { session = { display = 'reviewing', counts = { defended = 3, substantial = 5 } } }
        end,
      },
    }, function()
      eq('nvime: big 3/5 defended', statusline.get())
    end)
  end)

  it('says nothing once the change has merged — there is no gate left to track', function()
    with_surfaces({
      big = {
        state = function()
          return { session = { display = 'merged', counts = { defended = 5, substantial = 5 } } }
        end,
      },
    }, function()
      eq('', statusline.get())
    end)
  end)

  it('prefers a running chat turn over a running edit, and edit over a big session', function()
    with_surfaces({
      chat = {
        is_running = function()
          return true
        end,
      },
      edit = {
        is_running = function()
          return true
        end,
        state = function()
          return { tally = { hunks = 9 } }
        end,
      },
      big = {
        state = function()
          return { session = { display = 'reviewing', counts = { defended = 1, substantial = 2 } } }
        end,
      },
    }, function()
      eq('nvime: chat●', statusline.get())
    end)
  end)
end)

describe('statusline.toggle_winbar', function()
  it('flips the global winbar on and off, evaluating through statusline.get', function()
    vim.o.winbar = ''
    if statusline.winbar_enabled() then
      statusline.toggle_winbar()
    end
    with_surfaces({ chat = {
      is_running = function()
        return true
      end,
    } }, function()
      local on = statusline.toggle_winbar()
      eq(true, on)
      ok(vim.o.winbar ~= '', 'the winbar option is set')
      local rendered = vim.api.nvim_eval_statusline(vim.o.winbar, { winid = vim.api.nvim_get_current_win() })
      eq('nvime: chat●', rendered.str)

      local off = statusline.toggle_winbar()
      eq(false, off)
      eq('', vim.o.winbar)
    end)
  end)
end)
