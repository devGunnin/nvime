local t = require('harness')
local apply = require('nvime.apply')
local config = require('nvime.config')
local palette = require('nvime.palette')
local panel = require('nvime.panel')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local fake = { requests = {}, changes = {} }

function fake.request(method, params, cb)
  fake.requests[#fake.requests + 1] = { method = method, params = params }
  if method == 'edit.list_changes' then
    cb(nil, { changes = fake.changes })
  end
end

local real_agent = require('nvime.agent')
package.loaded['nvime.agent'] = {
  request = fake.request,
  on_event = function()
    return function() end
  end,
  is_running = function()
    return true
  end,
}
package.loaded['nvime.edit'] = nil
package.loaded['nvime.changeset'] = nil
local edit = require('nvime.edit')
local changeset = require('nvime.changeset')

local dirs = {}

local BEFORE = 'one\ntwo\nthree\nfour\nfive\n'
local AFTER = 'one\nTWO\nthree\nfour\nFIVE\n'

local function sandbox(text)
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir .. '/.git', 'p')
  dirs[#dirs + 1] = dir
  local path = dir .. '/queue.py'
  local handle = assert(io.open(path, 'wb'))
  handle:write(text)
  handle:close()
  return dir, path
end

local function disk(path)
  local handle = assert(io.open(path, 'rb'))
  local text = handle:read('a')
  handle:close()
  return text
end

local function write(path, text)
  local handle = assert(io.open(path, 'wb'))
  handle:write(text)
  handle:close()
end

local function cleanup()
  panel.close('changeset')
  for _, dir in ipairs(dirs) do
    vim.fn.delete(dir, 'rf')
  end
  dirs = {}
end

--- Opens the changeset over one recorded change, the file already at `after`.
local function open_over(before, after)
  panel.close('changeset')
  local dir, path = sandbox(after)
  fake.requests = {}
  fake.changes = {
    {
      runId = 'r1',
      index = 0,
      path = path,
      tool = 'Edit',
      before = { kind = 'text', text = before },
      after = { kind = 'text', text = after },
    },
  }
  config.setup({ edit = { nofade = true } })
  palette.apply()
  apply.reset()
  edit.state().root = dir
  vim.cmd('enew')
  changeset.open()
  return dir, path
end

local function lines()
  return vim.api.nvim_buf_get_lines(panel.get('changeset').buf, 0, -1, false)
end

--- The row of the nth hunk in the rendered list.
local function hunk_row(n)
  local seen = 0
  for row, target in pairs(changeset.view().rows) do
    if target.hunk ~= nil then
      seen = seen + 1
      if target.hunk == n then
        return row
      end
    end
  end
  ok(false, 'no row for hunk ' .. n .. ' (saw ' .. seen .. ')')
end

describe('changeset.open', function()
  it('lists each changed file with its hunks', function()
    open_over(BEFORE, AFTER)
    local rendered = table.concat(lines(), '\n')
    ok(rendered:find('queue.py', 1, true) ~= nil, 'the file is named relative to the project')
    ok(rendered:find('~ line 2', 1, true) ~= nil, 'the first hunk')
    ok(rendered:find('~ line 5', 1, true) ~= nil, 'and the second')
    eq('edit.list_changes', fake.requests[#fake.requests].method)
    cleanup()
  end)

  it('says plainly when nothing has changed', function()
    panel.close('changeset')
    local dir = sandbox('x\n')
    fake.changes = {}
    config.setup({})
    edit.state().root = dir
    changeset.open()
    ok(table.concat(lines(), '\n'):find('nothing changed', 1, true) ~= nil)
    cleanup()
  end)
end)

describe('changeset.revert', function()
  it('round-trips one hunk on disk and leaves the other alone', function()
    local _, path = open_over(BEFORE, AFTER)
    local ok_revert, reason = changeset.revert(changeset.view().rows[hunk_row(1)])
    ok(ok_revert, reason)
    eq('one\ntwo\nthree\nfour\nFIVE\n', disk(path), 'only the first hunk went back')

    ok(changeset.revert(changeset.view().rows[hunk_row(2)]))
    eq(BEFORE, disk(path), 'and reverting the rest restores the original exactly')
    cleanup()
  end)

  it('reverts through the buffer when the file is open, with no reload', function()
    local _, path = open_over(BEFORE, AFTER)
    vim.cmd('wincmd p')
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()

    ok(changeset.revert(changeset.view().rows[hunk_row(1)]))
    eq('two', vim.api.nvim_buf_get_lines(buf, 1, 2, false)[1], 'the buffer shows the revert')
    eq(false, vim.bo[buf].modified, 'and it is not left dirty')
    eq(disk(path), apply.buffer_text(buf), 'buffer and disk agree')
    cleanup()
  end)

  it('refuses a hunk the user has hand-edited since, rather than corrupting it', function()
    local _, path = open_over(BEFORE, AFTER)
    write(path, 'one\nMINE\nthree\nfour\nFIVE\n')
    local ok_revert, reason = changeset.revert(changeset.view().rows[hunk_row(1)])
    eq(false, ok_revert)
    ok(reason:find('edited since') ~= nil, 'and says why: ' .. tostring(reason))
    eq('one\nMINE\nthree\nfour\nFIVE\n', disk(path), 'the hand edit is untouched')
    cleanup()
  end)

  it('still reverts a hunk when unrelated lines above it moved', function()
    local _, path = open_over(BEFORE, AFTER)
    write(path, 'zero\n' .. AFTER)
    ok(changeset.revert(changeset.view().rows[hunk_row(2)]))
    eq('zero\none\nTWO\nthree\nfour\nfive\n', disk(path))
    cleanup()
  end)

  it('says a hunk is already reverted instead of blaming the user for drift', function()
    open_over(BEFORE, AFTER)
    ok(changeset.revert(changeset.view().rows[hunk_row(1)]))
    local ok_again, reason = changeset.revert(changeset.view().rows[hunk_row(1)])
    eq(false, ok_again)
    ok(reason:find('already reverted', 1, true) ~= nil, 'got: ' .. tostring(reason))
    ok(table.concat(lines(), '\n'):find('· reverted', 1, true) == nil, 'and the list only marks it once redrawn')
    changeset.open()
    ok(table.concat(lines(), '\n'):find('· reverted', 1, true) ~= nil, 'the redraw marks it')
    cleanup()
  end)

  it('refuses to revert a file that did not exist before the run', function()
    panel.close('changeset')
    local dir, path = sandbox('fresh\n')
    fake.changes = {
      {
        runId = 'r1',
        index = 0,
        path = path,
        tool = 'Write',
        before = { kind = 'absent' },
        after = { kind = 'text', text = 'fresh\n' },
      },
    }
    config.setup({})
    edit.state().root = dir
    changeset.open()
    local ok_revert, reason = changeset.revert({ change = 1, hunk = 1 })
    eq(false, ok_revert)
    ok(reason:find('did not exist', 1, true) ~= nil)
    cleanup()
  end)

  it('blames the buffer, not disk, when unsaved edits block the revert', function()
    local _, path = open_over(BEFORE, AFTER)
    vim.cmd('wincmd p')
    vim.cmd('edit ' .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    -- A line outside the hunk, so the refusal is about the dirty buffer alone.
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'ONE' })

    local ok_revert, reason = changeset.revert(changeset.view().rows[hunk_row(1)])
    eq(false, ok_revert)
    ok(reason:find('unsaved edits', 1, true) ~= nil, 'got: ' .. tostring(reason))
    ok(reason:find('on disk', 1, true) == nil, 'nothing wrote disk — do not send the user looking there')
    eq(AFTER, disk(path), 'and the refusal really did leave the file alone')
    vim.cmd('silent! bwipeout! ' .. buf)
    cleanup()
  end)

  it('asks for a hunk rather than guessing when the cursor is on a file row', function()
    open_over(BEFORE, AFTER)
    local ok_revert, reason = changeset.revert({ change = 1 })
    eq(false, ok_revert)
    ok(reason:find('cursor on a hunk', 1, true) ~= nil)
    cleanup()
  end)
end)

describe('changeset: the unified view', function()
  --- The rendered row whose text is `text`, and what the view maps it to.
  local function row_for(text)
    for row, line in ipairs(lines()) do
      if line == text then
        return row, changeset.view().rows[row]
      end
    end
    ok(false, 'no rendered row reads ' .. text)
  end

  local function open_unified()
    local dir, path = open_over(BEFORE, AFTER)
    changeset.view().unified = true
    changeset.open()
    return dir, path
  end

  it('toggles to a plain unified diff and back', function()
    open_unified()
    local rendered = table.concat(lines(), '\n')
    ok(rendered:find('--- a/queue.py', 1, true) ~= nil, 'a real unified header')
    ok(rendered:find('\n-two', 1, true) ~= nil, 'the removed line')
    ok(rendered:find('\n+TWO', 1, true) ~= nil, 'and the added one')
    changeset.view().unified = false
    cleanup()
  end)

  it('reverts the hunk the cursor is on, which the status line has always advertised', function()
    local _, path = open_unified()
    local _, target = row_for('+TWO')
    ok(target ~= nil and target.hunk ~= nil, 'a changed line must map to its hunk')
    local ok_revert, reason = changeset.revert(target)
    ok(ok_revert, tostring(reason))
    eq('one\ntwo\nthree\nfour\nFIVE\n', disk(path), 'only that hunk went back')
    changeset.view().unified = false
    cleanup()
  end)

  it('maps a removed line to its hunk as well as an added one', function()
    open_unified()
    local _, removed = row_for('-five')
    local _, added = row_for('+FIVE')
    ok(removed ~= nil and removed.hunk ~= nil, 'a removed line maps to a hunk too')
    ok(added ~= nil and added.hunk ~= nil)
    eq(added.hunk, removed.hunk, 'both sides of one hunk are the same hunk')
    changeset.view().unified = false
    cleanup()
  end)

  it('still refuses on a context line rather than guessing a hunk', function()
    open_unified()
    local _, context = row_for(' three')
    ok(context ~= nil)
    eq(nil, context.hunk)
    local ok_revert, reason = changeset.revert(context)
    eq(false, ok_revert)
    ok(reason:find('cursor on a hunk', 1, true) ~= nil)
    changeset.view().unified = false
    cleanup()
  end)
end)

package.loaded['nvime.agent'] = real_agent
