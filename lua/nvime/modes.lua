--- Input-mode fundamentals. nvime's surfaces are driven by normal-mode
--- mappings, and nvim carries insert mode across a window or tab switch — a
--- panel opened from a prompt box that was left in insert (which every send
--- does) lands in insert, where `a`/`M`/`q` type themselves into the surface
--- instead of acting.
local M = {}

--- Leaves every mode in which a printable key writes text instead of acting.
--- Call whenever a surface driven by normal-mode keys takes focus.
---
--- `ni*` is normal mode reached from insert with `i_CTRL-O`: it returns to
--- insert on its own unless insert is ended. Select mode is not insert at all
--- — `stopinsert` does nothing there — but a printable key REPLACES the
--- selection, so it is left the only way it can be: a queued `<Esc>`.
---
--- Neither branch is synchronous — `stopinsert` takes effect as the command
--- finishes, and the fed `<Esc>` lands behind whatever is already in the
--- typeahead — so select mode in particular is best-effort. No caller may
--- read `mode()` straight after and expect `n`.
function M.normal()
  local mode = vim.fn.mode(true)
  if mode:match('^[iR]') or mode:match('^ni') then
    vim.cmd('stopinsert')
    return
  end
  if mode:match('^[sS\19]') then
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'n', false)
  end
end

return M
