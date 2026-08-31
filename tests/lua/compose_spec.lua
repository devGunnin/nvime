local t = require('harness')
local compose = require('nvime.compose')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Runs `fn` with vim.notify captured, and returns what it said.
local function with_notices(fn)
  local seen = {}
  local real = vim.notify
  vim.notify = function(message)
    seen[#seen + 1] = message
  end
  local finished, err = pcall(fn)
  vim.notify = real
  if not finished then
    error(err, 0)
  end
  return seen
end

--- Lets the scheduled paste guard run: it reverts on the next tick, so the
--- pasted text is briefly really in the buffer.
local function settle()
  vim.wait(50, function()
    return false
  end)
end

--- Invokes a buffer-local mapping. Compared on resolved termcodes: nvim
--- reports `<C-r>` back as `<C-R>`, and the spelling is not the point.
local function press(buf, mode, lhs)
  local wanted = vim.api.nvim_replace_termcodes(lhs, true, true, true)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
    if vim.api.nvim_replace_termcodes(map.lhs, true, true, true) == wanted and map.callback ~= nil then
      map.callback()
      return true
    end
  end
  return false
end

local function open_answer(on_submit)
  compose.dismiss()
  local win = compose.open({
    title = ' defend ',
    no_paste = true,
    on_submit = on_submit or function() end,
  })
  vim.cmd('stopinsert')
  return win
end

--- Like `open_answer`, but for tests that need real `InsertCharPre` events:
--- `compose.open`'s own `startinsert` has not taken effect by the time a
--- following `nvim_feedkeys` call runs synchronously after it — the mode
--- switch eats the first character fed — so this stops insert first and
--- leaves entering it to `type_text`, which does so deterministically.
local function open_answer_insert(on_submit)
  compose.dismiss()
  local win = compose.open({
    title = ' defend ',
    no_paste = true,
    on_submit = on_submit or function() end,
  })
  vim.cmd('stopinsert')
  return win
end

--- Types `text` as real keystrokes: enters insert mode, feeds it, leaves
--- insert mode, all in one synchronous batch — so `InsertCharPre` fires for
--- every character exactly as it would for a reader typing them.
local function type_text(text)
  local esc = vim.api.nvim_replace_termcodes('<Esc>', true, true, true)
  vim.api.nvim_feedkeys('i' .. text .. esc, 'x', false)
end

local function text_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe('paste detection', function()
  it('calls one big insertion a paste and ordinary typing typing', function()
    eq(false, compose.is_paste({ 'ab' }, { 'abc' }), 'a keystroke')
    eq(false, compose.is_paste({ 'ab' }, { 'ab', '' }), 'pressing enter adds one line')
    eq(false, compose.is_paste({ 'abcdef' }, { 'abc' }), 'deleting is never a paste')
    ok(compose.is_paste({ '' }, { string.rep('x', 40) }), 'forty characters at once is not typing')
    ok(compose.is_paste({ '' }, { 'a', 'b', 'c' }), 'three lines at once is not typing')
  end)

  it('counts characters, not bytes, so a CJK or IME typist can answer at all', function()
    -- Nine Japanese characters are 27 bytes. Measured in bytes the box refuses
    -- to be typed in at all, and an IME commits a whole phrase as one change.
    eq(false, compose.is_paste({ '' }, { 'こんにちは世界です' }), 'nine characters is typing')
    eq(false, compose.is_paste({ '' }, { '这个改动修复了一个竞态条件' }), 'an IME phrase commit is typing')
    eq(false, compose.is_paste({ '' }, { 'électricité générale' }), 'accented latin is not a paste either')
    ok(compose.is_paste({ '' }, { string.rep('あ', 40) }), 'forty characters is still a paste')
  end)
end)

describe('the answer box', function()
  it('blocks the normal-mode puts, by name and with the reason', function()
    local win = open_answer()
    local buf = compose.current().buf
    vim.fn.setreg('"', 'the whole diff, pasted back')
    local said = with_notices(function()
      ok(press(buf, 'n', 'p'), 'p must be bound in a paste-blocked box')
      ok(press(buf, 'n', 'P'))
      ok(press(buf, 'n', 'gp'))
      ok(press(buf, 'n', ']p'))
    end)
    eq(4, #said)
    ok(said[1]:match('type it') ~= nil, said[1])
    eq({ '' }, text_of(buf), 'and nothing landed in the buffer')
    ok(win ~= nil)
    compose.dismiss()
  end)

  it('blocks a register put made in insert mode', function()
    open_answer()
    local buf = compose.current().buf
    local said = with_notices(function()
      ok(press(buf, 'i', '<C-r>'), '<C-r> is the one-keystroke paste route')
    end)
    ok(said[1]:match('type it') ~= nil, said[1])
    compose.dismiss()
  end)

  it('refuses a bracketed paste before it ever reaches the buffer', function()
    -- `vim.paste` is what bracketed paste from the terminal calls, and it goes
    -- nowhere near the mappings above. Refused there, the text is never on
    -- screen at all — the buffer watcher would only undo it a tick later.
    open_answer()
    local buf = compose.current().buf
    vim.api.nvim_set_current_buf(buf)
    local said = with_notices(function()
      eq(
        false,
        vim.paste({ 'def next_delay(self, attempt):', '    base = 2 ** attempt' }, -1),
        'the paste is cancelled'
      )
      eq({ '' }, text_of(buf), 'and nothing was inserted to undo')
    end)
    ok(#said > 0 and said[1]:match('type it') ~= nil, vim.inspect(said))
    compose.dismiss()

    -- Scoped and restored: every other buffer pastes exactly as it always did.
    local plain = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(plain)
    vim.paste({ 'pasted freely' }, -1)
    eq({ 'pasted freely' }, vim.api.nvim_buf_get_lines(plain, 0, -1, false))
    vim.api.nvim_buf_delete(plain, { force = true })
  end)

  it('undoes a `:put` from a register, which neither a mapping nor vim.paste sees', function()
    open_answer()
    local buf = compose.current().buf
    vim.api.nvim_set_current_buf(buf)
    vim.fn.setreg('a', 'the entire hunk, straight out of the register')
    with_notices(function()
      vim.cmd('put a')
      settle()
    end)
    eq({ '' }, text_of(buf))
    compose.dismiss()
  end)

  it('lets a person type, one character at a time', function()
    open_answer()
    local buf = compose.current().buf
    local typed = ''
    with_notices(function()
      for chunk in ('full jitter spreads retries across the whole window'):gmatch('.') do
        typed = typed .. chunk
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { typed })
        settle()
      end
    end)
    eq({ typed }, text_of(buf), 'a typed answer is never mistaken for a paste')
    compose.dismiss()
  end)

  it('accepts a coalesced batch of real keystrokes over the paste-burst size, and undo recovers it cleanly', function()
    -- The scheduler can let many genuine `InsertCharPre` events queue up
    -- before the watcher's callback runs; size alone must not be able to
    -- tell that apart from a paste. Fed as one `nvim_feedkeys` call, exactly
    -- like a fast typist or a coalescing terminal link — the reviewer's own
    -- probe, driven the same way, through the real input queue.
    open_answer_insert()
    local buf = compose.current().buf
    local text = string.rep('x', 48)
    local said = with_notices(function()
      type_text(text)
      settle()
    end)
    eq({ text }, text_of(buf), 'forty-eight real keystrokes, coalesced into one batch, are not a paste')
    eq(0, #said, vim.inspect(said))

    -- Accepted outright, so `u` is ordinary undo of real content — never the
    -- watcher catching it a second time and destroying it for good, which is
    -- what happened before: the text was on screen for exactly one tick, the
    -- watcher reverted it before it was ever remembered, and undo had nothing
    -- of the reader's own to restore.
    local onUndo = with_notices(function()
      vim.cmd('normal! u')
      settle()
    end)
    eq(0, #onUndo, 'undo does not re-trigger the paste watcher on text it already accepted')
    compose.dismiss()
  end)

  it('lets undo and redo put back text that was already typed', function()
    -- Undo of a whole insert, then redo of it, arrives as one big change. It
    -- must not be refused: the buffer has held exactly this content before.
    open_answer()
    local buf = compose.current().buf
    local sentence = 'a sentence I typed out in full, slowly'
    with_notices(function()
      local typed = ''
      for chunk in sentence:gmatch('.') do
        typed = typed .. chunk
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { typed })
        settle()
      end
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '' })
      settle()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { sentence })
      settle()
    end)
    eq({ sentence }, text_of(buf), 'redo is not a paste')
    compose.dismiss()
  end)

  it('sends what was typed, and nothing when it is empty', function()
    local sent = {}
    open_answer(function(text)
      sent[#sent + 1] = text
    end)
    local buf = compose.current().buf
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'it exits before the arg parse' })
    press(buf, 'n', '<CR>')
    eq({ 'it exits before the arg parse' }, sent)
    eq(nil, compose.current(), 'the box closes on send')

    open_answer(function(text)
      sent[#sent + 1] = text
    end)
    press(compose.current().buf, 'n', '<CR>')
    eq(1, #sent, 'an empty answer is a dismissal, not a submission')
  end)

  it('leaves an ordinary comment box able to paste', function()
    compose.dismiss()
    compose.open({ title = ' comment ', on_submit = function() end })
    local buf = compose.current().buf
    vim.api.nvim_set_current_buf(buf)
    eq(false, press(buf, 'n', 'p'), 'a review comment is not the thing being defended')
    vim.paste({ 'pasted', 'freely' }, -1)
    settle()
    eq({ 'pasted', 'freely' }, text_of(buf))
    compose.dismiss()
  end)
end)
