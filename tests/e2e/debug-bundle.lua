--- The diagnostics a bug report can carry, proven on a real build: the debug
--- log records the run, `:Nvime log` renders it, `:Nvime bundle` writes it out
--- — and neither ever prints the prompt back.
---
--- The sentinel is planted where the leak would be worst: it IS the change's
--- title, so it reaches the branch name, the spec and every state line derived
--- from them. The log is deny-by-default, so it must come out as a size.
local lib = dofile(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/lib.lua')

local repo = assert(vim.env.NVIME_E2E_REPO, 'NVIME_E2E_REPO names the scratch repo')
local sentinel = assert(vim.env.NVIME_E2E_SENTINEL, 'NVIME_E2E_SENTINEL names the string that must not leak')
local model = vim.env.NVIME_E2E_MODEL

require('nvime').setup({})
require('nvime').debug('on')
local log = require('nvime.log')
if log.level() == 'off' then
  lib.die('the debug log would not turn on: ' .. tostring(log.status().broken_reason))
end
lib.say('LOGDIR ' .. vim.fs.dirname(log.path()))
lib.say('LOGPATH ' .. log.path())

local created = lib.call('big.create', { root = repo, title = sentinel .. ' version flag', difficulty = 'vibe' }, 60000)
local id = created.session.id
lib.say('SESSION ' .. id)

lib.call('big.intake', {
  root = repo,
  sessionId = id,
  message = table.concat({
    'Add a --version flag to greet.py that prints 1.0.0.',
    'Internal ticket ' .. sentinel .. ' — never write that reference into any file, comment or commit message.',
    'The spec is ready as written — answer with it and do not ask further questions.',
  }, ' '),
  model = model,
}, 600000)
lib.call('big.approve', { root = repo, sessionId = id }, 120000)

local built = lib.call('big.build', { root = repo, sessionId = id, model = model, triageModel = model }, 1800000)
lib.say('BUILT ' .. built.session.display)
-- The head sha only exists once the change is merged, and this scenario does
-- not merge; the base sha is what the bundle can be held to here.
lib.say('BASE ' .. tostring(built.session.base.commit))

-- The bundle attaches the SELECTED big change, and selection lives in the
-- big-change surface. This driver drove the sidecar directly, so the same
-- state is set through the module's own test hook.
local big_state = require('nvime.big').state()
big_state.root, big_state.session = repo, built.session

require('nvime').log()
local view = require('nvime.log').current()
if view == nil or not vim.api.nvim_buf_is_valid(view.buf) then
  lib.die(':Nvime log opened no view')
end
local shown = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
if #shown < 5 then
  lib.die(':Nvime log showed ' .. #shown .. ' line(s) after a whole build')
end
lib.say('LOGVIEW ' .. #shown)

local written = nil
require('nvime.bundle').write(function(path)
  written = path or false
end)
vim.wait(60000, function()
  return written ~= nil
end, 100)
if written == nil then
  lib.die(':Nvime bundle never finished')
end
if written == false then
  lib.die(':Nvime bundle wrote no file')
end
if vim.uv.fs_stat(written) == nil then
  lib.die('the bundle path does not exist: ' .. written)
end
lib.say('BUNDLE ' .. written)
os.exit(0)
