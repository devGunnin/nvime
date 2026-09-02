--- A machine that has never run nvime: `setup()` on empty XDG homes, `:Nvime`
--- opens, the sidecar starts on first use, and one small change builds.
local lib = dofile(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/lib.lua')

local repo = assert(vim.env.NVIME_E2E_REPO, 'NVIME_E2E_REPO names the scratch repo')
local model = vim.env.NVIME_E2E_MODEL

require('nvime').setup({})

-- `vim.empty_dict()`, not `{}`: an empty Lua table encodes as `[]`, and the
-- sidecar refuses params that are not an object.
local ping = lib.call('ping', vim.empty_dict(), 120000)
if ping.claudePath == nil then
  lib.die('the sidecar found no claude CLI on PATH')
end
lib.say('PING claude=' .. tostring(ping.claudeVersion))

require('nvime').dashboard()
local shown = nil
for _, win in ipairs(vim.api.nvim_list_wins()) do
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.bo[buf].filetype == 'nvimedashboard' then
    shown = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
  end
end
if shown == nil then
  lib.die(':Nvime opened no dashboard')
end
if shown:find('nvime', 1, true) == nil then
  lib.die('the dashboard came up empty')
end
lib.say('DASHBOARD ' .. #shown .. ' bytes')

local created = lib.call('big.create', { root = repo, title = 'print a version banner', difficulty = 'vibe' }, 60000)
local id = created.session.id
lib.say('SESSION ' .. id)

lib.call('big.intake', {
  root = repo,
  sessionId = id,
  message = table.concat({
    'Add a VERSION = "1.0.0" constant to greet.py and print it before the greeting.',
    'The spec is ready as written — answer with it and do not ask further questions.',
  }, ' '),
  model = model,
}, 600000)
lib.call('big.approve', { root = repo, sessionId = id }, 120000)

local built = lib.call('big.build', { root = repo, sessionId = id, model = model, triageModel = model }, 1800000)
lib.say('BUILT ' .. built.session.display .. ' threads=' .. tostring(built.session.counts.total))
if built.session.counts.open > 0 then
  lib.die('the vibe gate left ' .. built.session.counts.open .. ' thread(s) open')
end

local captured = lib.call('big.diff', { root = repo, sessionId = id }, 60000)
local diff = captured.diff ~= nil and captured.diff.text or nil
if diff == nil or diff == '' then
  lib.die('the first build on a fresh install produced no reviewable diff')
end
lib.say('DIFF ' .. #diff .. ' bytes')
lib.say('BIGSTORE ' .. vim.fn.stdpath('data') .. '/nvime/big')
os.exit(0)
