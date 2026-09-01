--- nvime: a Claude-native Neovim plugin. Chat, Edit and Big Change ship.
local agent = require('nvime.agent')
local big = require('nvime.big')
local changeset = require('nvime.changeset')
local chat = require('nvime.chat')
local config = require('nvime.config')
local edit = require('nvime.edit')
local keymaps = require('nvime.keymaps')
local models = require('nvime.models')
local palette = require('nvime.palette')
local statusline = require('nvime.statusline')

local M = {}

--- @type string
M.VERSION = require('nvime.version')

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

--- A compact string for the user's own statusline config: "chat●" while a
--- chat turn streams, "edit N hunks" while an edit run is applying them, or
--- "big X/Y defended" for the selected big change's gate — empty when there
--- is nothing to report.
M.statusline = statusline.get

--- `:Nvime statusline`: toggles the tiny built-in winbar equivalent, for
--- anyone who has not wired `statusline()` into their own config.
M.toggle_statusline = statusline.toggle_winbar

--- `:Nvime doctor`: the full preflight as one glanceable pass/warn/fail list —
--- node, the claude CLI, a best-effort login-file check, the sidecar build,
--- and this repo's git identity (a big change's local merge needs one).
M.doctor = require('nvime.doctor').open

--- `:Nvime model`: pick a lane (chat/edit/big_build/big_intake/big_triage/
--- big_grade/explain), then type/choose its model and reasoning effort — a
--- session-scoped override on top of `models.*` from `setup()`.
M.model = models.open

return M
