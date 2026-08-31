--- nvime: a Claude-native Neovim plugin. Chat, Edit and Big Change ship.
local agent = require('nvime.agent')
local big = require('nvime.big')
local changeset = require('nvime.changeset')
local chat = require('nvime.chat')
local config = require('nvime.config')
local edit = require('nvime.edit')
local keymaps = require('nvime.keymaps')
local palette = require('nvime.palette')

local M = {}

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
M.big = big.open

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
  if big.is_running() then
    big.cancel()
    stopped = true
  end
  if not stopped then
    vim.notify('nvime: nothing is running', vim.log.levels.INFO)
  end
end

--- `:Nvime` with no argument: the front door — what nvime can do, whether it is
--- wired up, and every big change in this project with its review progress.
M.dashboard = require('nvime.dashboard').open

return M
