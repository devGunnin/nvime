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
      eq(('nvime: chat ' .. require('nvime.icons').get().busy), statusline.get())
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
      eq(('nvime: chat ' .. require('nvime.icons').get().busy), statusline.get())
    end)
  end)
end)

describe('statusline.get: the model dial suffix', function()
  local models = require('nvime.models')

  it('appends nothing while every lane is at the CLI default', function()
    models.reset_all()
    with_surfaces({}, function()
      eq('', statusline.get())
    end)
  end)

  it('appends the active dial when nothing else is worth reporting', function()
    models.set('chat', 'claude-opus-5', 'high')
    with_surfaces({}, function()
      eq('nvime: chat:claude-opus-5/high', statusline.get())
    end)
    models.reset('chat')
  end)

  it('appends the active dial after the running-surface status', function()
    models.set('big_build', 'claude-sonnet-5', 'medium')
    with_surfaces({ chat = {
      is_running = function()
        return true
      end,
    } }, function()
      eq('nvime: chat ' .. require('nvime.icons').get().busy .. '  big_build:claude-sonnet-5/medium', statusline.get())
    end)
    models.reset('big_build')
  end)

  it('leaves a literal % alone — the documented plain %{expr} form does not re-scan', function()
    models.set('chat', '100%-local', nil)
    with_surfaces({}, function()
      eq('nvime: chat:100%-local/-', statusline.get())
    end)
    models.reset('chat')
  end)
end)

describe('statusline.get_for_winbar', function()
  local models = require('nvime.models')

  it('doubles a literal % in a typed model name before it reaches a winbar %{%...%} item', function()
    models.set('chat', '100%-local', nil)
    with_surfaces({}, function()
      eq('nvime: chat:100%%-local/-', statusline.get_for_winbar())
    end)
    models.reset('chat')
  end)

  it('matches get() exactly when there is nothing to escape', function()
    with_surfaces({ chat = {
      is_running = function()
        return true
      end,
    } }, function()
      eq(statusline.get(), statusline.get_for_winbar())
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
      eq(('nvime: chat ' .. require('nvime.icons').get().busy), rendered.str)

      local off = statusline.toggle_winbar()
      eq(false, off)
      eq('', vim.o.winbar)
    end)
  end)

  it('renders a single % through the real winbar, though get() itself carries a doubled one', function()
    local models = require('nvime.models')
    models.set('chat', '100%-local', nil)
    vim.o.winbar = ''
    if statusline.winbar_enabled() then
      statusline.toggle_winbar()
    end
    with_surfaces({}, function()
      statusline.toggle_winbar()
      local rendered = vim.api.nvim_eval_statusline(vim.o.winbar, { winid = vim.api.nvim_get_current_win() })
      eq('nvime: chat:100%-local/-', rendered.str, 'the winbar re-scans the doubled %% back down to one %')
      statusline.toggle_winbar()
    end)
    models.reset('chat')
  end)
end)
