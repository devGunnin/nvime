if vim.g.loaded_nvime == 1 then
  return
end
vim.g.loaded_nvime = 1

if vim.fn.has('nvim-0.10') == 0 then
  vim.notify('nvime needs Neovim 0.10 or newer', vim.log.levels.ERROR)
  return
end

--- Subcommands of the single `:Nvime` entry point. Each takes whatever words
--- followed its own name — `:Nvime log clear`, `:Nvime debug on`.
local subcommands = {
  chat = function()
    require('nvime').chat()
  end,
  edit = function()
    require('nvime').edit()
  end,
  big = function()
    require('nvime').big()
  end,
  diff = function()
    require('nvime').changeset()
  end,
  cancel = function()
    require('nvime').cancel()
  end,
  health = function()
    vim.cmd('checkhealth nvime')
  end,
  doctor = function()
    require('nvime').doctor()
  end,
  model = function()
    require('nvime').model()
  end,
  enroll = function()
    require('nvime').enrollment()
  end,
  statusline = function()
    local on = require('nvime').toggle_statusline()
    vim.notify('nvime: winbar status ' .. (on and 'on' or 'off'))
  end,
  log = function(...)
    require('nvime').log(...)
  end,
  bundle = function()
    require('nvime').bundle()
  end,
  debug = function(...)
    require('nvime').debug(...)
  end,
}

vim.api.nvim_create_user_command('Nvime', function(args)
  local name = args.fargs[1]
  if name == nil then
    require('nvime').dashboard()
    return
  end
  local handler = subcommands[name]
  if handler == nil then
    vim.notify(
      string.format("nvime: unknown subcommand '%s' (try: %s)", name, table.concat(vim.tbl_keys(subcommands), ', ')),
      vim.log.levels.ERROR
    )
    return
  end
  handler(unpack(args.fargs, 2))
end, {
  nargs = '*',
  desc = 'nvime',
  complete = function(lead, line)
    -- Only the first word is a subcommand; past it the arguments belong to
    -- the subcommand itself and nvime has nothing to offer.
    if line:match('^%s*Nvime%s+%S+%s') ~= nil then
      return {}
    end
    return vim.tbl_filter(function(name)
      return vim.startswith(name, lead)
    end, vim.tbl_keys(subcommands))
  end,
})
