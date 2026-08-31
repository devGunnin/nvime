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

  it('undoes a paste that arrives by any other route', function()
    -- `vim.paste` is what bracketed paste from the terminal calls, and it goes
    -- nowhere near the mappings above. The guard watches the BUFFER instead.
    open_answer()
    local buf = compose.current().buf
    vim.api.nvim_set_current_buf(buf)
    local said = with_notices(function()
      vim.paste({ 'def next_delay(self, attempt):', '    base = min(self.cap, 2 ** attempt)' }, -1)
      settle()
    end)
    eq({ '' }, text_of(buf), 'the pasted text does not survive')
    ok(#said > 0 and said[1]:match('type it') ~= nil, vim.inspect(said))
    compose.dismiss()
  end)

  it('undoes a `:put` from a register, which no mapping can intercept', function()
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
