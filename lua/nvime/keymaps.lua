--- Every keymap nvime defines, in one table.
---
--- The table exists so the leaf-only rule is checkable rather than aspirational:
--- no mapping may be a prefix of another in the same mode, because the shorter
--- one then stalls for `timeoutlen` on every press. v1's `ga`/`ga!` pair is the
--- exact failure this bans.
local M = {}

--- The approval float's keys. `approval.lua` binds exactly this table and
--- `M.all` lists exactly this table, so the two cannot drift and leave the
--- leaf-only check blind to a live mapping.
M.APPROVAL = {
  { lhs = 'y', allow = true, desc = 'nvime: allow once' },
  { lhs = 'Y', allow = true, desc = 'nvime: allow once' },
  { lhs = 'n', allow = false, desc = 'nvime: deny' },
  { lhs = 'N', allow = false, desc = 'nvime: deny' },
  { lhs = '<Esc>', allow = false, desc = 'nvime: deny' },
}

--- The confirmation float's keys, bound by `confirm.lua`. Same shape and same
--- registry rule as `APPROVAL`, but its own table: the two floats ask
--- different questions and their descriptions must not drift into each other.
M.CONFIRM = {
  { lhs = 'y', allow = true, desc = 'nvime: yes, go ahead' },
  { lhs = 'Y', allow = true, desc = 'nvime: yes, go ahead' },
  { lhs = 'n', allow = false, desc = 'nvime: no' },
  { lhs = 'N', allow = false, desc = 'nvime: no' },
  { lhs = '<Esc>', allow = false, desc = 'nvime: no' },
}

--- The normal-mode puts the paste-blocked answer box refuses. Listed here
--- because they are ordinary editing keys: the leaf-only check has to see them,
--- and `compose.lua` binds exactly this table so the two cannot drift.
M.COMPOSE_PUT = { 'p', 'P', 'gp', 'gP', ']p', '[p', ']P', '[P' }

--- @param opts table the resolved config
--- @return table[] entries with scope, mode, lhs, desc
function M.all(opts)
  local keymaps = opts.keymaps
  local entries = {
    { scope = 'global', mode = 'n', lhs = keymaps.chat, desc = 'nvime: open chat' },
    { scope = 'global', mode = 'x', lhs = keymaps.send_selection, desc = 'nvime: send the selection' },
    { scope = 'global', mode = 'n', lhs = keymaps.edit, desc = 'nvime: edit this file' },
    { scope = 'global', mode = 'x', lhs = keymaps.edit, desc = 'nvime: edit the selection' },
    { scope = 'global', mode = 'n', lhs = keymaps.changeset, desc = 'nvime: review the changeset' },
    { scope = 'global', mode = 'n', lhs = keymaps.big, desc = 'nvime: open a big change' },
    { scope = 'panel-chat', mode = 'n', lhs = '<C-r>', desc = 'nvime: pick a session' },
    { scope = 'panel-chat', mode = 'n', lhs = '<C-n>', desc = 'nvime: start a new conversation' },
    { scope = 'panel-chat', mode = 'n', lhs = '<C-c>', desc = 'nvime: stop the running turn' },
    { scope = 'panel-chat', mode = 'n', lhs = ']o', desc = 'nvime: jump to the pending choice' },
    { scope = 'panel-chat', mode = 'n', lhs = 'q', desc = 'nvime: close the chat panel' },
    { scope = 'panel-edit', mode = 'n', lhs = '<C-c>', desc = 'nvime: stop the edit run' },
    { scope = 'panel-edit', mode = 'n', lhs = 'q', desc = 'nvime: close the edit panel' },
    { scope = 'panel-changeset', mode = 'n', lhs = '<CR>', desc = 'nvime: open the file at this hunk' },
    { scope = 'panel-changeset', mode = 'n', lhs = 'r', desc = 'nvime: revert this hunk' },
    { scope = 'panel-changeset', mode = 'n', lhs = 'd', desc = 'nvime: toggle the unified diff' },
    { scope = 'panel-changeset', mode = 'n', lhs = 'q', desc = 'nvime: close the changeset' },
    { scope = 'panel-big', mode = 'n', lhs = '<C-r>', desc = 'nvime: pick a big change' },
    { scope = 'panel-big', mode = 'n', lhs = '<C-n>', desc = 'nvime: start a new big change' },
    { scope = 'panel-big', mode = 'n', lhs = '<C-t>', desc = 'nvime: open the review threads' },
    { scope = 'panel-big', mode = 'n', lhs = '<C-c>', desc = 'nvime: stop the big change' },
    { scope = 'panel-big', mode = 'n', lhs = ']o', desc = 'nvime: jump to the pending choice' },
    { scope = 'panel-big', mode = 'n', lhs = 'q', desc = 'nvime: close the big change panel' },
    { scope = 'threads', mode = 'n', lhs = ']t', desc = 'nvime: next thread' },
    { scope = 'threads', mode = 'n', lhs = '[t', desc = 'nvime: previous thread' },
    { scope = 'threads', mode = 'n', lhs = ']c', desc = 'nvime: next hunk in this thread' },
    { scope = 'threads', mode = 'n', lhs = '[c', desc = 'nvime: previous hunk in this thread' },
    { scope = 'threads', mode = 'n', lhs = 't', desc = 'nvime: toggle the unified diff' },
    { scope = 'threads', mode = 'n', lhs = 'a', desc = 'nvime: answer this thread' },
    { scope = 'threads', mode = 'n', lhs = 'e', desc = 'nvime: explain this thread' },
    { scope = 'threads', mode = 'n', lhs = 'r', desc = 'nvime: request changes' },
    { scope = 'threads', mode = 'n', lhs = 'X', desc = 'nvime: re-open or clear a trivial thread' },
    { scope = 'threads', mode = 'n', lhs = 'R', desc = 'nvime: rebase onto the moved base' },
    { scope = 'threads', mode = 'n', lhs = 'M', desc = 'nvime: merge' },
    { scope = 'threads', mode = 'n', lhs = '<CR>', desc = 'nvime: open this file in the worktree' },
    { scope = 'threads', mode = 'n', lhs = 'q', desc = 'nvime: close the review' },
    { scope = 'panel-prompt', mode = 'n', lhs = '<CR>', desc = 'nvime: send the prompt' },
    { scope = 'panel-prompt', mode = 'n', lhs = '<C-r>', desc = 'nvime: pick a session' },
    { scope = 'panel-prompt', mode = 'n', lhs = '<C-n>', desc = 'nvime: start a new session' },
    { scope = 'panel-prompt', mode = 'n', lhs = '<C-c>', desc = 'nvime: stop the running turn' },
    { scope = 'panel-prompt', mode = 'i', lhs = '<C-s>', desc = 'nvime: send the prompt' },
    { scope = 'picker', mode = 'n', lhs = '<CR>', desc = 'nvime: choose' },
    { scope = 'picker', mode = 'n', lhs = 'q', desc = 'nvime: dismiss' },
    { scope = 'picker', mode = 'n', lhs = '<Esc>', desc = 'nvime: dismiss' },
  }
  for _, key in ipairs(M.APPROVAL) do
    entries[#entries + 1] = { scope = 'approval', mode = 'n', lhs = key.lhs, desc = key.desc }
  end
  for _, key in ipairs(M.CONFIRM) do
    entries[#entries + 1] = { scope = 'confirm', mode = 'n', lhs = key.lhs, desc = key.desc }
  end
  for _, key in ipairs(require('nvime.dashboard').KEYS) do
    entries[#entries + 1] = { scope = 'dashboard', mode = 'n', lhs = key.lhs, desc = key.desc }
  end
  for _, lhs in ipairs(M.COMPOSE_PUT) do
    entries[#entries + 1] = { scope = 'compose', mode = 'n', lhs = lhs, desc = 'nvime: refuse a paste' }
  end
  entries[#entries + 1] = { scope = 'compose', mode = 'i', lhs = '<C-r>', desc = 'nvime: refuse a paste' }
  return entries
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
  local edit = require('nvime.edit')
  vim.keymap.set('n', opts.keymaps.chat, chat.open, { silent = true, desc = 'nvime: open chat' })
  vim.keymap.set('n', opts.keymaps.edit, edit.instruct, { silent = true, desc = 'nvime: edit this file' })
  vim.keymap.set('n', opts.keymaps.changeset, function()
    require('nvime.changeset').open()
  end, { silent = true, desc = 'nvime: review the changeset' })
  vim.keymap.set('n', opts.keymaps.big, function()
    require('nvime.big').open()
  end, { silent = true, desc = 'nvime: open a big change' })
  -- The selection has to be read before leaving visual mode, so each of these
  -- captures it first and drops back to normal mode afterwards.
  local function from_selection(fn)
    return function()
      fn()
      vim.api.nvim_feedkeys(M.normalize('<Esc>'), 'n', false)
    end
  end
  vim.keymap.set(
    'x',
    opts.keymaps.send_selection,
    from_selection(chat.send_selection),
    { silent = true, desc = 'nvime: send the selection' }
  )
  vim.keymap.set(
    'x',
    opts.keymaps.edit,
    from_selection(edit.instruct_selection),
    { silent = true, desc = 'nvime: edit the selection' }
  )
  return entries
end

return M
