--- nvime: a Claude-native Neovim plugin. Phase 1 ships Chat.
local agent = require('nvime.agent')
local chat = require('nvime.chat')
local config = require('nvime.config')
local keymaps = require('nvime.keymaps')
local palette = require('nvime.palette')

local M = {}

--- Capabilities the dashboard lists. P2 adds `edit`, P3/P4 add `big`.
local CAPABILITIES = {
  { name = 'chat', status = 'ready', summary = 'read-only conversation with session resume' },
  { name = 'edit', status = 'planned (P2)', summary = 'point-and-change with live buffer application' },
  { name = 'big', status = 'planned (P3/P4)', summary = 'worktree builds behind the comprehension gate' },
}

--- @param user table|nil
function M.setup(user)
  local opts = config.setup(user)
  palette.attach()
  keymaps.apply(opts)
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('NvimeShutdown', { clear = true }),
    desc = 'nvime: stop the agent sidecar',
    callback = function()
      agent.stop()
    end,
  })
  return opts
end

M.chat = chat.open
M.cancel = chat.cancel
M.send_selection = chat.send_selection

--- `:Nvime` with no argument: what nvime can do and whether it is wired up.
function M.dashboard()
  local lines = { 'nvime — no vibe coding in my editor', '' }
  for _, capability in ipairs(CAPABILITIES) do
    lines[#lines + 1] = string.format('  %-6s %-16s %s', capability.name, capability.status, capability.summary)
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = '  sidecar  ' .. (agent.is_running() and 'running' or 'starts on first use')
  local built = vim.uv.fs_stat(agent.dist_path()) ~= nil
  lines[#lines + 1] = '  build    ' .. (built and 'present' or ('missing — ' .. agent.build_hint()))
  lines[#lines + 1] = ''
  lines[#lines + 1] = '  :Nvime chat      open the chat panel'
  lines[#lines + 1] = '  :Nvime cancel    stop the running turn'
  lines[#lines + 1] = '  :checkhealth nvime'
  vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
end

M.CAPABILITIES = CAPABILITIES

return M
