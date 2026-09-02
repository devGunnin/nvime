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

  it('never forces normal mode on a prompt panel, which is there to be typed in', function()
    setup()
    panel.close('chat')
    local left = opened_from_insert(function()
      panel.open({ name = 'chat', width = 40, on_submit = function() end })
    end)
    eq(false, left, 'no stopinsert is issued for a prompt box')
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

  --- What `modes.normal()` does in one reported mode: the ex-commands it runs
  --- and the keys it feeds, with `mode()` answering `reported`.
  local function acts_in(reported)
    local real_mode, real_cmd, real_feed = vim.fn.mode, vim.cmd, vim.api.nvim_feedkeys
    local did = {}
    vim.fn.mode = function()
      return reported
    end
    vim.cmd = function(command)
      did[#did + 1] = command
      return nil
    end
    vim.api.nvim_feedkeys = function(keys)
      did[#did + 1] = 'feed:' .. vim.fn.keytrans(keys)
    end
    local ran, err = pcall(modes.normal)
    vim.fn.mode, vim.cmd, vim.api.nvim_feedkeys = real_mode, real_cmd, real_feed
    if not ran then
      error(err, 0)
    end
    return table.concat(did, ' ')
  end

  it('leaves the insert-adjacent modes a surface must never inherit', function()
    eq('stopinsert', acts_in('i'), 'insert')
    eq('stopinsert', acts_in('R'), 'replace')
    eq('stopinsert', acts_in('niI'), 'normal-from-insert (i_CTRL-O) returns to insert without this')
    ok(acts_in('s'):find('feed:<Esc>', 1, true) ~= nil, 'select mode: a printable key replaces the selection')
    ok(acts_in('S'):find('feed:<Esc>', 1, true) ~= nil, 'select by line')
    eq('', acts_in('n'), 'normal mode is left alone')
    eq('', acts_in('v'), 'visual mode ends on its own when the window changes')
  end)
end)

describe('the keys a prompt box answers in insert', function()
  --- The chat prompt, wired exactly as `chat.open` wires it (completion and
  --- all), without needing the chat module's sidecar stub.
  local function chat_prompt(root)
    setup()
    panel.close('chat')
    return panel.open({
      name = 'chat',
      width = 40,
      root = root,
      on_submit = function() end,
      keys = {
        { mode = 'n', lhs = '<C-n>', fn = function() end, where = 'both' },
        { mode = 'n', lhs = '<C-r>', fn = function() end, where = 'both', insert = 'when-empty' },
        { mode = 'n', lhs = '<C-c>', fn = function() end, where = 'both', insert = true },
        { mode = 'n', lhs = ']o', fn = function() end, where = 'both' },
      },
    })
  end

  it('never binds the completion keys in insert on a box that has completion', function()
    local view = chat_prompt(vim.fn.getcwd())
    eq(
      "v:lua.require('nvime.completion').completefunc",
      vim.bo[view.prompt_buf].completefunc,
      'the box under test is the one with @-path completion'
    )
    local insert = keys_in(view.prompt_buf, 'i')
    eq(nil, insert['<C-N>'], 'i_CTRL-N walks the completion popup — nvime must not take it')
    eq(nil, insert['<C-T>'], 'i_CTRL-T indents the line')
    eq(nil, insert[']o'], 'a literal key in insert would shadow the reader’s own typing')
    ok(insert['<C-C>'], 'stop is reachable from the mode a send leaves you in')
    ok(insert['<C-R>'])
    ok(insert['<C-S>'])
    for _, lhs in ipairs({ '<C-N>', ']o' }) do
      ok(keys_in(view.prompt_buf, 'n')[lhs], lhs .. ' stays a normal-mode key')
    end
    panel.close('chat')
  end)

  it('is opt-in per key, never inferred from the key’s shape', function()
    setup()
    panel.close('chat')
    local view = panel.open({
      name = 'chat',
      width = 40,
      on_submit = function() end,
      keys = { { mode = 'n', lhs = '<C-b>', fn = function() end, where = 'both' } },
    })
    eq(nil, keys_in(view.prompt_buf, 'i')['<C-B>'], 'a control chord alone does not earn an insert binding')
    ok(keys_in(view.prompt_buf, 'n')['<C-B>'])
    panel.close('chat')
  end)

  --- The <expr> callback of one insert mapping, with `pumvisible()` answering
  --- `open`. What it RETURNS is what nvim types: the native key, or nothing.
  local function insert_expr(buf, lhs, open)
    local real = vim.fn.pumvisible
    vim.fn.pumvisible = function()
      return open and 1 or 0
    end
    local produced = nil
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'i')) do
      if map.lhs == lhs then
        ok(map.expr == 1, lhs .. ' must be an <expr> map so the native key can win')
        produced = map.callback()
      end
    end
    vim.fn.pumvisible = real
    return produced
  end

  it('hands the key back to Vim while the completion popup is up', function()
    local view = chat_prompt(vim.fn.getcwd())
    eq('<C-c>', insert_expr(view.prompt_buf, '<C-C>', true), 'the popup owns the key first')
    eq('', insert_expr(view.prompt_buf, '<C-C>', false), 'otherwise nvime acts')
    panel.close('chat')
  end)

  it('opens the session picker on <C-r> only when the box is empty', function()
    local view = chat_prompt(vim.fn.getcwd())
    eq('', insert_expr(view.prompt_buf, '<C-R>', false), 'an empty box has nothing to paste into')
    vim.api.nvim_buf_set_lines(view.prompt_buf, 0, -1, false, { 'the retry helper in ' })
    eq('<C-r>', insert_expr(view.prompt_buf, '<C-R>', false), 'i_CTRL-R stays the register paste mid-prompt')
    panel.close('chat')
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
  --- The <expr> callback of the float's insert-mode <Esc>, with `pumvisible()`
  --- answering `open`.
  local function esc_expr(buf, open)
    local real = vim.fn.pumvisible
    vim.fn.pumvisible = function()
      return open and 1 or 0
    end
    local produced = nil
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'i')) do
      if map.lhs == '<Esc>' then
        produced = map.callback()
      end
    end
    vim.fn.pumvisible = real
    return produced
  end

  it('dismisses the completion popup instead of the box when one is up', function()
    compose.dismiss()
    compose.open({ title = ' defend ', no_paste = true, on_submit = function() end })
    local float = compose.current()
    eq('<C-e>', esc_expr(float.buf, true), 'the popup is what <Esc> closes while it is open')
    ok(compose.current() ~= nil, 'and the answer is still on screen')
    eq('', esc_expr(float.buf, false), 'with no popup, <Esc> is the cancel the footer promises')
    compose.dismiss()
  end)

  it('hands a discarded draft back through the unnamed register', function()
    compose.dismiss()
    vim.fn.setreg('"', 'something else entirely')
    compose.open({ title = ' defend ', no_paste = true, on_submit = function() end })
    local float = compose.current()
    local buf = float.buf
    local answer = 'the retry helper already backs off, so the new branch would double it'
    -- Typed, not written: this box refuses a paste, and a set_lines of a whole
    -- sentence IS a paste to the guard.
    vim.api.nvim_set_current_win(float.win)
    vim.api.nvim_feedkeys('i' .. answer, 'x', false)
    eq({ answer }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'the answer is in the box')
    local said = {}
    local real_notify = vim.notify
    vim.notify = function(message)
      said[#said + 1] = message
    end
    local ran, err = pcall(function()
      -- The cancel itself, through the mapping the reader presses: the <expr>
      -- map schedules it, so the wait is what runs it.
      eq('', esc_expr(buf, false))
      vim.wait(200, function()
        return compose.current() == nil
      end)
    end)
    vim.notify = real_notify
    if not ran then
      error(err, 0)
    end
    eq(nil, compose.current(), 'one <Esc> from insert closes it')
    eq(answer, vim.fn.getreg('"'), 'a paste-blocked answer must be recoverable after a cancel')
    ok(table.concat(said, ' '):find('"p pastes it back', 1, true) ~= nil, table.concat(said, ' '))
  end)

  it('survives a second cancel scheduled before the first one ran', function()
    -- The insert mapping is <expr>: it returns and schedules, so a fast double
    -- <Esc> queues two cancels against a buffer the first one wipes. Both are
    -- run here, in order, exactly as the loop would run them.
    compose.dismiss()
    compose.open({ title = ' defend ', no_paste = true, on_submit = function() end })
    local buf = compose.current().buf
    local real_schedule, real_notify = vim.schedule, vim.notify
    local queued = {}
    vim.schedule = function(fn)
      queued[#queued + 1] = fn
    end
    vim.notify = function() end
    eq('', esc_expr(buf, false))
    eq('', esc_expr(buf, false), 'the float is still open when the second press lands')
    vim.schedule, vim.notify = real_schedule, real_notify
    eq(2, #queued, 'two presses, two queued cancels')
    for index, fn in ipairs(queued) do
      local ran, err = pcall(fn)
      ok(ran, 'cancel ' .. index .. ' raised: ' .. tostring(err))
    end
    eq(nil, compose.current())
  end)

  it('stashes a multi-line draft linewise, so "p puts the lines back', function()
    compose.dismiss()
    compose.open({ title = ' defend ', on_submit = function() end })
    local float = compose.current()
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, { 'line one', 'line two' })
    local said = {}
    local real_notify = vim.notify
    vim.notify = function(message)
      said[#said + 1] = message
    end
    vim.api.nvim_set_current_win(float.win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('q', true, false, true), 'x', false)
    vim.notify = real_notify
    eq({ 'line one', 'line two' }, vim.fn.getreg('"', 1, true))
    eq('V', vim.fn.getregtype('"'), 'charwise would splice two lines into the cursor’s line')
    ok(table.concat(said, ' '):find('below the cursor', 1, true) ~= nil, table.concat(said, ' '))
  end)

  it('stashes a one-line draft charwise', function()
    compose.dismiss()
    compose.open({ title = ' defend ', on_submit = function() end })
    local float = compose.current()
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, { 'one line only' })
    local real_notify = vim.notify
    vim.notify = function() end
    vim.api.nvim_set_current_win(float.win)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('q', true, false, true), 'x', false)
    vim.notify = real_notify
    eq('one line only', vim.fn.getreg('"'))
    eq('v', vim.fn.getregtype('"'))
  end)

  it('stashes the draft on the normal-mode cancels too', function()
    for _, key in ipairs({ 'q', '<C-c>' }) do
      compose.dismiss()
      vim.fn.setreg('"', '')
      compose.open({ title = ' defend ', no_paste = true, on_submit = function() end })
      local float = compose.current()
      vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, { 'a defence worth keeping' })
      vim.api.nvim_set_current_win(float.win)
      local real_notify = vim.notify
      vim.notify = function() end
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'x', false)
      vim.notify = real_notify
      eq(nil, compose.current(), key .. ' cancels')
      eq('a defence worth keeping', vim.fn.getreg('"'), key .. ' keeps the draft')
    end
  end)
end)

describe('the compose float’s advertised keys', function()
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

--- The three panels that open a prompt box, wired by their own modules — not
--- by a key table this test writes. `edit` is the one the fix round forgot.
local real_agent = require('nvime.agent')
package.loaded['nvime.agent'] = {
  request = function(_, _, _, opts)
    if opts ~= nil and opts.on_sent ~= nil then
      opts.on_sent(1)
    end
  end,
  on_event = function()
    return function() end
  end,
  is_running = function()
    return true
  end,
}
for _, name in ipairs({ 'nvime.chat', 'nvime.big', 'nvime.edit' }) do
  package.loaded[name] = nil
end

describe('every prompt panel keeps the promises its hint makes', function()
  --- The control chords a hint advertises, split by the mode it claims them
  --- for: `n_<C-x>`/`i_<C-x>` name one mode, a bare chord claims both. Only
  --- chords — they are the keys whose meaning depends on the mode; a
  --- `<leader>` pointer in a hint names a global normal-mode mapping.
  local function advertised(hint)
    local claims = {}
    for prefix, key in hint:gmatch('([ni]?_?)(<[Cc]%-[^>]+>)') do
      claims[key] = prefix == 'n_' and 'n' or (prefix == 'i_' and 'i' or 'both')
    end
    return claims
  end

  it('splits a hint into the modes it claims', function()
    eq(
      { ['<C-s>'] = 'i', ['<C-c>'] = 'both', ['<C-n>'] = 'n' },
      advertised('prompt · <CR> send (i_<C-s>) · <C-c> stop · n_<C-n> new · <leader>nd changes')
    )
  end)

  for _, panel_under_test in ipairs({
    { name = 'chat', open = 'nvime.chat' },
    { name = 'big', open = 'nvime.big' },
    { name = 'edit', open = 'nvime.edit' },
  }) do
    it('binds what the ' .. panel_under_test.name .. ' hint advertises for insert mode', function()
      setup()
      panel.close(panel_under_test.name)
      local dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir .. '/.git', 'p')
      vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/tool.py'))
      require(panel_under_test.open).open()
      local view = panel.get(panel_under_test.name)
      ok(view ~= nil and view.prompt_buf ~= nil, 'the panel opened with a prompt box')
      local insert = keys_in(view.prompt_buf, 'i')
      for key, mode in pairs(advertised(view.prompt_hint)) do
        if mode ~= 'n' then
          ok(insert[key:upper()], key .. ' is advertised for insert on the ' .. panel_under_test.name .. ' prompt')
        end
      end
      ok(insert['<C-C>'], 'stop must be reachable from the mode every send leaves you in')
      panel.close(panel_under_test.name)
      vim.fn.delete(dir, 'rf')
    end)
  end
end)

-- Every later spec gets the real module back.
package.loaded['nvime.agent'] = real_agent
for _, name in ipairs({ 'nvime.chat', 'nvime.big', 'nvime.edit' }) do
  package.loaded[name] = nil
end
