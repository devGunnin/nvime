--- Every keymap nvime defines, in one table.
---
--- The table exists so the leaf-only rule is checkable rather than aspirational:
--- no mapping may be a prefix of another in the same mode, because the shorter
--- one then stalls for `timeoutlen` on every press. v1's `ga`/`ga!` pair is the
--- exact failure this bans.
local M = {}

--- @param opts table the resolved config
--- @return table[] entries with scope, mode, lhs, desc
function M.all(opts)
  local keymaps = opts.keymaps
  return {
    { scope = 'global', mode = 'n', lhs = keymaps.chat, desc = 'nvime: open chat' },
    { scope = 'global', mode = 'x', lhs = keymaps.send_selection, desc = 'nvime: send the selection' },
    { scope = 'panel-chat', mode = 'n', lhs = '<C-r>', desc = 'nvime: pick a session' },
    { scope = 'panel-chat', mode = 'n', lhs = '<C-c>', desc = 'nvime: stop the running turn' },
    { scope = 'panel-chat', mode = 'n', lhs = 'q', desc = 'nvime: close the chat panel' },
    { scope = 'panel-prompt', mode = 'n', lhs = '<CR>', desc = 'nvime: send the prompt' },
    { scope = 'panel-prompt', mode = 'n', lhs = '<C-r>', desc = 'nvime: pick a session' },
    { scope = 'panel-prompt', mode = 'n', lhs = '<C-c>', desc = 'nvime: stop the running turn' },
    { scope = 'panel-prompt', mode = 'i', lhs = '<C-s>', desc = 'nvime: send the prompt' },
    { scope = 'picker', mode = 'n', lhs = '<CR>', desc = 'nvime: choose' },
    { scope = 'picker', mode = 'n', lhs = 'q', desc = 'nvime: dismiss' },
    { scope = 'picker', mode = 'n', lhs = '<Esc>', desc = 'nvime: dismiss' },
  }
end

--- Resolves `<leader>` and friends to the keys Neovim actually matches on.
function M.normalize(lhs)
  return vim.api.nvim_replace_termcodes(lhs, true, true, true)
end

--- Pairs where one mapping is a strict prefix of another in the same mode.
--- Checked across scopes: a buffer-local map and a global one share a buffer.
--- @param entries table[] from `all`
--- @return table[] conflicts, each { short = entry, long = entry }
function M.conflicts(entries)
  local resolved = vim.tbl_map(function(entry)
    return { entry = entry, keys = M.normalize(entry.lhs) }
  end, entries)
  local found = {}
  for _, a in ipairs(resolved) do
    for _, b in ipairs(resolved) do
      if a.entry.mode == b.entry.mode and a.keys ~= b.keys and vim.startswith(b.keys, a.keys) then
        found[#found + 1] = { short = a.entry, long = b.entry }
      end
    end
  end
  return found
end

--- Installs the global mappings. Buffer-local ones belong to their surface.
--- @param opts table the resolved config
function M.apply(opts)
  local entries = M.all(opts)
  for _, clash in ipairs(M.conflicts(entries)) do
    vim.notify(
      string.format(
        "nvime: '%s' is a prefix of '%s' (%s), so the shorter one will stall — change one of them",
        clash.short.lhs,
        clash.long.lhs,
        clash.short.mode
      ),
      vim.log.levels.WARN
    )
  end
  if not opts.keymaps.enabled then
    return entries
  end
  local chat = require('nvime.chat')
  vim.keymap.set('n', opts.keymaps.chat, chat.open, { silent = true, desc = 'nvime: open chat' })
  vim.keymap.set('x', opts.keymaps.send_selection, function()
    chat.send_selection()
    vim.api.nvim_feedkeys(M.normalize('<Esc>'), 'n', false)
  end, { silent = true, desc = 'nvime: send the selection' })
  return entries
end

return M
