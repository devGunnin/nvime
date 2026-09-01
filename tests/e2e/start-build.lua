--- Editor A: spec a change, approve it, start the build, and LEAVE. The runner
--- is detached, so this process exiting must not stop the build.
local lib = dofile(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/lib.lua')

local repo = assert(vim.env.NVIME_E2E_REPO, 'NVIME_E2E_REPO names the scratch repo')
local model = vim.env.NVIME_E2E_MODEL

local created = lib.call('big.create', { root = repo, title = 'add a --version flag', difficulty = 'vibe' }, 60000)
local id = created.session.id
lib.say('SESSION ' .. id)

lib.call('big.intake', {
  root = repo,
  sessionId = id,
  message = table.concat({
    'Add a --version flag to greet.py that prints 1.0.0, and add tests for it in test_greet.py.',
    'Run the tests with python3 -m unittest before you finish.',
    'The spec is ready as written — answer with it and do not ask further questions.',
  }, ' '),
  model = model,
}, 600000)

local approved = lib.call('big.approve', { root = repo, sessionId = id }, 120000)
if approved.session.spec == nil then
  lib.die('intake produced no spec to approve')
end
lib.say('APPROVED ' .. tostring(approved.session.base.commit))

-- Fired and NOT waited on: the point is to walk away from it.
require('nvime.agent').request('big.build', {
  root = repo,
  sessionId = id,
  model = model,
  triageModel = model,
}, function() end, { no_deadline = true })

-- Leave only once the runner is really up and writing, so "the build survived"
-- is a claim about a running build rather than about one that never started.
vim.wait(120000, function()
  return lib.log_lines() >= 3
end, 200)
if lib.log_lines() < 3 then
  lib.die('the detached runner never started writing its log')
end
lib.say('RUNNING ' .. lib.log_path() .. ' ' .. lib.log_lines())
os.exit(0)
