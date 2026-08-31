if vim.g.loaded_nvime == 1 then
  return
end
vim.g.loaded_nvime = 1

if vim.fn.has('nvim-0.10') == 0 then
  vim.notify('nvime needs Neovim 0.10 or newer', vim.log.levels.ERROR)
  return
end

--- Subcommands of the single `:Nvime` entry point. P2/P3 add `edit` and `big`.
local subcommands = {
  chat = function()
    require('nvime').chat()
  end,
  cancel = function()
    require('nvime').cancel()
  end,
  health = function()
    vim.cmd('checkhealth nvime')
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
  handler()
end, {
  nargs = '?',
  desc = 'nvime',
  complete = function(lead)
    return vim.tbl_filter(function(name)
      return vim.startswith(name, lead)
    end, vim.tbl_keys(subcommands))
  end,
})
