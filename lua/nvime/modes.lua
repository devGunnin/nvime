--- Input-mode fundamentals. nvime's surfaces are driven by normal-mode
--- mappings, and nvim carries insert mode across a window or tab switch — a
--- panel opened from a prompt box that was left in insert (which every send
--- does) lands in insert, where `a`/`M`/`q` type themselves into the surface
--- instead of acting.
local M = {}

--- Leaves insert (or replace) mode. Call whenever a surface driven by
--- normal-mode keys takes focus.
function M.normal()
  if vim.fn.mode():match('^[iR]') then
    vim.cmd('stopinsert')
  end
end

--- Both modes an advertised prompt key must answer in: a prompt opens in
--- insert deliberately, so a key bound only in normal is unreachable exactly
--- when the user needs it.
M.PROMPT = { 'n', 'i' }

return M
