--- nvime: a Claude-native Neovim plugin. Chat and Edit ship; Big Change is next.
local agent = require('nvime.agent')
local changeset = require('nvime.changeset')
local chat = require('nvime.chat')
local config = require('nvime.config')
local edit = require('nvime.edit')
local keymaps = require('nvime.keymaps')
local palette = require('nvime.palette')

local M = {}

--- Capabilities the dashboard lists. P3/P4 add `big`.
local CAPABILITIES = {
  { name = 'chat', status = 'ready', summary = 'read-only conversation with session resume' },
  { name = 'edit', status = 'ready', summary = 'point-and-change, applied live in the buffer' },
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
M.send_selection = chat.send_selection
M.edit = edit.instruct
M.edit_selection = edit.instruct_selection
M.changeset = changeset.open

--- `:Nvime cancel`: stops whichever run is live rather than complaining twice.
function M.cancel()
  local stopped = false
  if chat.is_running() then
    chat.cancel()
    stopped = true
  end
  if edit.is_running() then
    edit.cancel()
    stopped = true
  end
  if not stopped then
    vim.notify('nvime: nothing is running', vim.log.levels.INFO)
  end
end

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
  lines[#lines + 1] = '  :Nvime edit      instruct claude about this file'
  lines[#lines + 1] = '  :Nvime diff      review the changeset'
  lines[#lines + 1] = '  :Nvime cancel    stop the running turn'
  lines[#lines + 1] = '  :checkhealth nvime'
  vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
end

M.CAPABILITIES = CAPABILITIES

return M
