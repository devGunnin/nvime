--- The compact status nvime can render: for the user's own statusline config
--- (`require('nvime').statusline()`) and for the built-in winbar toggle.
---
--- Reads only what each surface already keeps live from its own RPC events —
--- never a fresh request, never a timer. The winbar toggle leans on Neovim's
--- own redraw cycle to re-evaluate it, so nothing here polls either.
local M = {}

--- One line: which surface is doing something, and how far along it is.
--- Empty when nothing is worth reporting.
--- @return string
function M.get()
  local icons = require('nvime.icons').get()
  if require('nvime.chat').is_running() then
    return 'nvime: chat ' .. icons.busy
  end
  local edit = require('nvime.edit')
  if edit.is_running() then
    local hunks = ((edit.state() or {}).tally or {}).hunks or 0
    return string.format('nvime: edit %d hunk%s', hunks, hunks == 1 and '' or 's')
  end
  local session = (require('nvime.big').state() or {}).session
  if session == nil or session.counts == nil or session.display == 'merged' then
    return ''
  end
  -- A build has nothing defended yet; saying "0/2 defended" would read as a
  -- review that is going badly rather than one that has not started.
  if session.display == 'building' or session.display == 'triaging' or session.display == 'drafting' then
    return 'nvime: big ' .. session.display
  end
  local counts = session.counts
  return string.format('nvime: big %d/%d defended', counts.defended or 0, counts.substantial or 0)
end

--- Neovim re-evaluates a `%{%...%}` winbar item on its own redraws — this is
--- what makes the toggle event-driven with no extra timer.
local WINBAR_EXPR = "%{%v:lua.require('nvime.statusline').get()%}"

local enabled = false

--- `:Nvime statusline`: flips the built-in winbar on or off, global to every
--- window that has no winbar of its own (the review threads and panels set
--- their own, and are unaffected).
--- @return boolean the new state
function M.toggle_winbar()
  enabled = not enabled
  vim.o.winbar = enabled and WINBAR_EXPR or ''
  return enabled
end

--- Test hook.
--- @return boolean
function M.winbar_enabled()
  return enabled
end

return M
