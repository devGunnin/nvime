--- The input-mode fundamentals, in one place: every surface driven by
--- normal-mode keys lands in normal mode however it was opened, every list is
--- nomodifiable, and a key a window advertises works in the modes that window
--- is used in.
local t = require('harness')
local compose = require('nvime.compose')
local config = require('nvime.config')
local modes = require('nvime.modes')
local palette = require('nvime.palette')
local panel = require('nvime.panel')
local picker = require('nvime.picker')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local function setup()
  config.setup({})
  palette.apply()
end

--- Runs `open` as if the reader were mid-insert — which is where every send
--- leaves them — and reports whether the surface left insert mode.
---
--- Stubbed rather than typed: headless nvim cannot HOLD insert mode across a
--- Lua call (the typeahead empties and insert ends), so `mode()` is made to
--- answer the way it does for a reader who just sent a prompt, and the
--- `stopinsert` the surface issues is recorded.
local function opened_from_insert(open)
  local real_mode, real_cmd = vim.fn.mode, vim.cmd
  local left = false
  vim.fn.mode = function()
    return 'i'
  end
  vim.cmd = function(command)
    if command == 'stopinsert' then
      left = true
    end
    return real_cmd(command)
  end
  local ran, err = pcall(open)
  vim.fn.mode, vim.cmd = real_mode, real_cmd
  if not ran then
    error(err, 0)
  end
  return left
end

local function keys_in(buf, mode)
  local out = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    out[map.lhs] = true
  end
  return out
end

describe('normal mode on focus', function()
  it('leaves insert when a surface that has no prompt takes focus', function()
    setup()
    panel.close('changeset')
    local view
    local left = opened_from_insert(function()
      view = panel.open({ name = 'changeset', prompt = false, width = 40 })
    end)
    ok(left, 'a read-only panel is driven by normal-mode keys')
    eq(false, vim.bo[view.buf].modifiable, 'and its list can never be typed into')
    panel.close('changeset')
  end)

  it('keeps insert mode in a prompt panel, which is there to be typed in', function()
    setup()
    panel.close('chat')
    local left = opened_from_insert(function()
      panel.open({ name = 'chat', width = 40, on_submit = function() end })
    end)
    eq(false, left, 'the prompt box opens ready to type')
    panel.close('chat')
  end)

  it('leaves insert when a picker takes focus', function()
    setup()
    local win
    local left = opened_from_insert(function()
      win = picker.open(
        { { label = 'one', value = 'a' }, { label = 'two', value = 'b' } },
        { title = ' sessions ', on_choice = function() end }
      )
    end)
    ok(left, 'a picker row is chosen with <CR>, not typed over')
    local buf = vim.api.nvim_win_get_buf(win)
    eq(false, vim.bo[buf].modifiable)
    ok(keys_in(buf, 'n')['<CR>'], 'and the key it advertises is bound')
    vim.api.nvim_win_close(win, true)
  end)

  it('leaves insert when the dashboard takes focus', function()
    setup()
    local left = opened_from_insert(require('nvime.dashboard').open)
    ok(left)
    local buf = vim.api.nvim_get_current_buf()
    eq(false, vim.bo[buf].modifiable, 'the front door is a list, not a buffer')
    vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)
  end)

  it('leaves insert when a confirm float takes focus', function()
    setup()
    local left = opened_from_insert(function()
      require('nvime.confirm').ask('throw it away?', function() end)
    end)
    ok(left, 'y/n are normal-mode keys')
    require('nvime.confirm').dismiss()
  end)

  it('leaves insert when an approval float takes focus', function()
    setup()
    local approval = require('nvime.approval')
    local left = opened_from_insert(function()
      approval.ask(
        { approvalId = 'r1:t1', tool = 'Bash', summary = 'running ls', reason = 'a shell command' },
        function() end
      )
    end)
    ok(left, 'y/n decide a permission prompt')
    eq(false, vim.bo[approval.current().buf].modifiable)
    approval.dismiss_all()
  end)

  it('sends a reader in insert straight back to normal', function()
    ok(opened_from_insert(modes.normal))
    eq('n', vim.fn.mode(), 'and a reader already in normal mode is left alone')
  end)
end)

describe('prompt keys work in both modes', function()
  it('binds a control chord in insert as well, and a literal key only in normal', function()
    setup()
    panel.close('chat')
    local view = panel.open({
      name = 'chat',
      width = 40,
      on_submit = function() end,
      keys = {
        { mode = 'n', lhs = '<C-r>', fn = function() end, where = 'both' },
        { mode = 'n', lhs = ']o', fn = function() end, where = 'both' },
      },
    })
    local insert = keys_in(view.prompt_buf, 'i')
    ok(insert['<C-R>'], '<C-r> must not open Vim’s register prompt in the box that advertises it')
    ok(insert['<C-S>'], 'and <C-s> still sends')
    eq(nil, insert[']o'], 'a literal key in insert would shadow the reader’s own typing')
    ok(keys_in(view.prompt_buf, 'n')[']o'], 'it stays a normal-mode key')
    panel.close('chat')
  end)

  it('decides that by the shape of the key, not by a list', function()
    eq({ 'n', 'i' }, panel.prompt_modes('<C-c>'))
    eq({ 'n', 'i' }, panel.prompt_modes('<C-t>'))
    eq({ 'n' }, panel.prompt_modes('s'))
    eq({ 'n' }, panel.prompt_modes(']o'))
    eq({ 'n' }, panel.prompt_modes('<CR>'))
  end)

  it('says in the hint that <CR> sends from normal and <C-s> from insert', function()
    setup()
    panel.close('chat')
    local view = panel.open({ name = 'chat', width = 40, on_submit = function() end })
    ok(view.prompt_hint:find('i_<C-s>', 1, true) ~= nil, 'the insert-mode send is advertised, not implied')
    panel.close('chat')
  end)
end)

describe('the compose float cancels on one <Esc>', function()
  it('is bound in insert too — the float opens there', function()
    compose.dismiss()
    compose.open({ title = ' steer ', hint = 'one nudge', on_submit = function() end })
    local float = compose.current()
    ok(float ~= nil)
    ok(keys_in(float.buf, 'i')['<Esc>'], 'one press, from the mode the float opens in')
    ok(keys_in(float.buf, 'n')['<Esc>'])
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'x', false)
    eq(nil, compose.current(), 'and one press is enough')
  end)

  it('says so in the footer, with the insert-mode send named', function()
    compose.dismiss()
    local win = compose.open({ title = ' steer ', hint = 'one nudge', on_submit = function() end })
    local footer = vim.api.nvim_win_get_config(win).footer
    local text = type(footer) == 'table' and footer[1][1] or tostring(footer)
    ok(text:find('<Esc> cancel', 1, true) ~= nil, footer and text)
    ok(text:find('i_<C-s>', 1, true) ~= nil, 'the send that works where the float opens')
    compose.dismiss()
  end)
end)
