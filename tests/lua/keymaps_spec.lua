local t = require('harness')
local config = require('nvime.config')
local keymaps = require('nvime.keymaps')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

describe('keymaps', function()
  it('defines every nvime mapping in one table', function()
    local entries = keymaps.all(config.setup({}))
    ok(#entries > 0, 'the keymap table must not be empty')
    for _, entry in ipairs(entries) do
      ok(type(entry.lhs) == 'string' and entry.lhs ~= '', 'every entry needs an lhs')
      ok(type(entry.mode) == 'string' and entry.mode ~= '', 'every entry needs a mode')
      ok(type(entry.desc) == 'string' and entry.desc ~= '', 'every entry needs a description')
    end
  end)

  it('is leaf-only: no mapping is a prefix of another in the same mode', function()
    eq({}, keymaps.conflicts(keymaps.all(config.setup({}))))
  end)

  it('stays leaf-only with a custom leader', function()
    local saved = vim.g.mapleader
    vim.g.mapleader = ','
    local conflicts = keymaps.conflicts(keymaps.all(config.setup({})))
    vim.g.mapleader = saved
    eq({}, conflicts)
  end)

  it('detects a prefix pair — the v1 ga/ga! stall class', function()
    local conflicts = keymaps.conflicts({
      { scope = 'global', mode = 'n', lhs = 'ga', desc = 'accept' },
      { scope = 'global', mode = 'n', lhs = 'ga!', desc = 'accept all' },
    })
    eq(1, #conflicts)
    eq('ga', conflicts[1].short.lhs)
    eq('ga!', conflicts[1].long.lhs)
  end)

  it('does not flag the same mapping in different modes', function()
    eq(
      {},
      keymaps.conflicts({
        { scope = 'a', mode = 'n', lhs = 'g', desc = 'x' },
        { scope = 'b', mode = 'i', lhs = 'ga', desc = 'y' },
      })
    )
  end)

  it('compares resolved keys, not the written form', function()
    local conflicts = keymaps.conflicts({
      { scope = 'a', mode = 'n', lhs = '<C-r>', desc = 'x' },
      { scope = 'b', mode = 'n', lhs = '<C-r>x', desc = 'y' },
    })
    eq(1, #conflicts)
  end)

  it('installs nothing until the user opts in', function()
    config.setup({})
    local before = #vim.api.nvim_get_keymap('n')
    keymaps.apply(config.get())
    eq(before, #vim.api.nvim_get_keymap('n'))
  end)

  it('installs the global mappings when enabled', function()
    local opts = config.setup({ keymaps = { enabled = true } })
    keymaps.apply(opts)
    local wanted = keymaps.normalize(opts.keymaps.chat)
    local found = false
    for _, map in ipairs(vim.api.nvim_get_keymap('n')) do
      if keymaps.normalize(map.lhs) == wanted then
        found = true
      end
    end
    ok(found, 'the chat mapping should be installed')
    vim.keymap.del('n', opts.keymaps.chat)
    vim.keymap.del('x', opts.keymaps.send_selection)
  end)
end)
