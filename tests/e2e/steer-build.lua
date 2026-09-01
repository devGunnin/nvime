--- Editor B: a Neovim that never saw the build start. Attach to it, steer it
--- mid-flight, and follow it to its end.
local lib = dofile(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/lib.lua')

local repo = assert(vim.env.NVIME_E2E_REPO, 'NVIME_E2E_REPO names the scratch repo')
local id = assert(vim.env.NVIME_E2E_SESSION, 'NVIME_E2E_SESSION names the session')

local opened = lib.call('big.open', { root = repo, sessionId = id }, 60000)
if not opened.session.runnerLive then
  lib.die('the build was not running any more: ' .. tostring(opened.session.display))
end
lib.say('ATTACHED runner=' .. tostring(opened.session.runner.pid))

lib.call('big.steer', {
  root = repo,
  sessionId = id,
  text = 'Also add a --help flag to greet.py that prints usage, and cover it in the tests.',
}, 60000)
lib.say('STEERED')

-- Follows to the terminal event: the build, its capture and its triage all
-- happen in the runner, and this only watches.
lib.call('big.attach', { root = repo, sessionId = id, after = 0 }, 1800000)

local final = lib.call('big.open', { root = repo, sessionId = id }, 60000)
lib.say('FINAL ' .. final.session.display .. ' threads=' .. tostring(final.session.counts.total))

local captured = lib.call('big.diff', { root = repo, sessionId = id }, 60000)
local diff = captured.diff ~= nil and captured.diff.text or nil
if diff == nil or diff == '' then
  lib.die('the build produced no reviewable diff')
end
lib.say('DIFFBYTES ' .. #diff)
if diff:find('--version', 1, true) ~= nil then
  lib.say('HAS_VERSION')
end
if diff:find('--help', 1, true) ~= nil then
  lib.say('HAS_STEERED_HELP')
end
os.exit(0)
