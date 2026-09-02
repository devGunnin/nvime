--- Issue #19: the prompt box is left in insert after every send, so the keys
--- it advertises have to work THERE — and only the ones nvime named, so Vim's
--- own insert keys keep working. Driven by actually typing the keys, against a
--- real agent turn rather than a stub.
---
---   i_<C-s>  sends what is in the box
---   i_<C-c>  stops the run that send started
---   i_<C-r>  opens the history picker while the box is EMPTY, and is Vim's
---            register paste the moment it is not
---   i_<C-n>  is Vim's completion, never nvime's "new change"
local lib = dofile(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/lib.lua')

local repo = assert(vim.env.NVIME_E2E_REPO, 'NVIME_E2E_REPO names the scratch repo')

-- The panel path takes its model from the config, not from the request the
-- other drivers build by hand, so the scenario's model is set here.
local model = vim.env.NVIME_E2E_MODEL
require('nvime').setup({ models = { big_intake = { model = model } } })
vim.cmd.cd(repo)
vim.cmd.edit(repo .. '/greet.py')

local big = require('nvime.big')
local panel = require('nvime.panel')
big.open()
local box = panel.get('big')
if box == nil or box.prompt_buf == nil then
  lib.die('the big change panel opened without a prompt box')
end

--- Types `keys` into the prompt box the way a reader would, from insert mode.
local function type_into_prompt(keys)
  vim.api.nvim_set_current_win(box.prompt_win)
  -- Every call names the mode it starts from, so it must not inherit one.
  vim.cmd('stopinsert')
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'x', false)
end

local function prompt_text()
  return vim.trim(table.concat(vim.api.nvim_buf_get_lines(box.prompt_buf, 0, -1, false), '\n'))
end

--- The insert-mode mappings the prompt buffer carries, by lhs.
local function insert_maps()
  local by_lhs = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(box.prompt_buf, 'i')) do
    by_lhs[vim.keycode(map.lhs)] = map
  end
  return by_lhs
end

local maps = insert_maps()
for _, lhs in ipairs({ '<C-s>', '<C-c>', '<C-r>' }) do
  if maps[vim.keycode(lhs)] == nil then
    lib.die('the prompt box has no insert-mode ' .. lhs)
  end
end
-- The half of #19 that is about NOT binding: these stay Neovim's in insert.
for _, lhs in ipairs({ '<C-n>', '<C-t>' }) do
  if maps[vim.keycode(lhs)] ~= nil then
    lib.die(lhs .. ' was bound in insert mode and took a native editing key')
  end
end
lib.say('NATIVE <C-n> and <C-t> are still Vim’s in the prompt')

-- 1. i_<C-s> sends.
type_into_prompt('iAdd a --version flag to greet.py that prints 1.0.0.<C-s>')
if prompt_text() ~= '' then
  lib.die('i_<C-s> left the prompt box holding ' .. string.format('%q', prompt_text()))
end
vim.wait(30000, function()
  return big.state().request_id ~= nil
end, 100)
if big.state().request_id == nil then
  lib.die('i_<C-s> sent nothing')
end
lib.say('SUBMITTED request=' .. tostring(big.state().request_id))

-- 2. i_<C-c> stops it — and the proof is the sidecar's own answer. `M.cancel`
-- says "it had already finished" when there was nothing live to stop, so a
-- cancel that hit a real, running turn is one that never says it.
local notices = {}
local real_notify = vim.notify
vim.notify = function(message, level)
  notices[#notices + 1] = tostring(message)
  return real_notify(message, level)
end

-- Let the turn get properly under way first: cancelling the same millisecond
-- it was sent would prove the wire, not the run.
vim.wait(10000, function()
  return false
end, 500)
type_into_prompt('i<C-c>')
local stopped = vim.wait(180000, function()
  return big.state().request_id == nil
end, 200)
if not stopped then
  lib.die('i_<C-c> did not stop the run')
end
for _, message in ipairs(notices) do
  if message:find('already finished', 1, true) ~= nil then
    lib.die('i_<C-c> found no running turn to stop')
  end
  if message:find('nvime: error', 1, true) ~= nil then
    lib.die('the cancel failed: ' .. message)
  end
end
lib.say('CANCELLED after a live turn, ' .. #notices .. ' notice(s)')
vim.notify = real_notify

-- 3. i_<C-r> on an empty box opens the history picker.
local function floats()
  local found = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= '' then
      found[#found + 1] = win
    end
  end
  return found
end
if #floats() > 0 then
  lib.die('a float was already open before <C-r>')
end
type_into_prompt('i<C-r>')
local opened = vim.wait(60000, function()
  return #floats() > 0
end, 100)
if not opened then
  lib.die('i_<C-r> opened no history picker')
end
local picker_win = floats()[1]
local rows = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(picker_win), 0, -1, false)
if not table.concat(rows, '\n'):find('start a new change', 1, true) then
  lib.die('the float <C-r> opened is not the big-change picker: ' .. table.concat(rows, ' / '))
end
lib.say('HISTORY ' .. #rows .. ' row(s)')
vim.api.nvim_win_close(picker_win, true)

-- 4. i_<C-r> with a half-written prompt in the box is Vim's register paste.
vim.fn.setreg('"', 'pasted-by-vim')
vim.api.nvim_buf_set_lines(box.prompt_buf, 0, -1, false, { 'half a thought ' })
type_into_prompt('A<C-r>"')
vim.wait(2000, function()
  return #floats() > 0
end, 100)
if #floats() > 0 then
  lib.die('<C-r> opened the picker over a prompt that had text in it')
end
if not prompt_text():find('pasted-by-vim', 1, true) then
  lib.die('i_<C-r> did not paste the register: ' .. string.format('%q', prompt_text()))
end
lib.say('REGISTER ' .. string.format('%q', prompt_text()))
os.exit(0)
