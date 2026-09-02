--- Issue #10, end to end against the real agent: build a change, let the base
--- branch move under it, then drive the REVIEW TAB the way the reader does —
--- `M` refuses with base-moved, `R` rebases, `M` lands it. Every notice the
--- reader would see, and every state the indicator passes through, is reported.
local lib = dofile(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/lib.lua')

local repo = assert(vim.env.NVIME_E2E_REPO, 'NVIME_E2E_REPO names the scratch repo')
local model = vim.env.NVIME_E2E_MODEL
local threads = require('nvime.threads')

--- Everything the reader is told goes into the report, in order.
local real_notify = vim.notify
vim.notify = function(message, level)
  lib.say('NOTICE ' .. tostring(message))
  return real_notify(message, level)
end

--- Presses one review-tab key, exactly as the reader would.
local function press(lhs)
  local buf = threads.view().tree_buf
  if buf == nil then
    lib.die('the review tab is not open')
  end
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.lhs == lhs and map.callback ~= nil then
      map.callback()
      return
    end
  end
  lib.die('the review tab has no ' .. lhs .. ' mapping')
end

--- Waits out the request `lhs` started, reporting what the indicator showed
--- while it ran — the whole point of the fix is that this is not empty.
local function press_and_wait(lhs, timeout)
  press(lhs)
  local started = threads.activity()
  if started == nil then
    lib.die(lhs .. ' sent nothing the tab could show')
  end
  local label, detail, spun = started.label, nil, false
  local settled = vim.wait(timeout, function()
    local live = threads.activity()
    if live == nil then
      return true
    end
    spun = spun or live.shown
    detail = live.detail or detail
    return false
  end, 200)
  if not settled then
    lib.die(lhs .. ' did not settle within ' .. timeout .. 'ms')
  end
  lib.say(string.format('ACTIVITY %s label=%q spinner=%s detail=%q', lhs, label, tostring(spun), tostring(detail)))
end

--- Moves the base branch with a commit the build never saw.
local function move_base()
  local note = assert(vim.env.NVIME_E2E_MOVE, 'NVIME_E2E_MOVE names the file to add')
  vim.fn.writefile({ '# moved on while the build was running', '' }, repo .. '/' .. note)
  vim.fn.system({ 'git', '-C', repo, 'add', '-A' })
  vim.fn.system({ 'git', '-C', repo, 'commit', '-qm', 'someone else landed this' })
  return vim.trim(vim.fn.system({ 'git', '-C', repo, 'rev-parse', 'HEAD' }))
end

local created = lib.call('big.create', { root = repo, title = 'add a --version flag', difficulty = 'vibe' }, 60000)
local id = created.session.id
lib.say('SESSION ' .. id)

lib.call('big.intake', {
  root = repo,
  sessionId = id,
  message = table.concat({
    'Add a --version flag to greet.py that prints 1.0.0.',
    'The spec is ready as written — answer with it and do not ask further questions.',
  }, ' '),
  model = model,
}, 600000)

local approved = lib.call('big.approve', { root = repo, sessionId = id }, 120000)
lib.say('BASE ' .. tostring(approved.session.base.commit))

local built = lib.call('big.build', { root = repo, sessionId = id, model = model, triageModel = model }, 1800000)
lib.say('BUILT ' .. built.session.display .. ' threads=' .. tostring(built.session.counts.total))
if built.session.counts.open > 0 then
  lib.die('the vibe gate left ' .. built.session.counts.open .. ' thread(s) open')
end

local moved = move_base()
lib.say('MOVED ' .. moved)

--- The review tab, holding the latest session view it is handed.
local latest = built.session
threads.open(repo, built.session, function(session)
  latest = session
end)

press_and_wait('M', 600000)
if latest.display == 'merged' then
  lib.die('the merge ignored a base that had moved')
end
lib.say('REFUSED ' .. tostring(latest.display))

press_and_wait('R', 1800000)
if latest.base.commit ~= moved then
  lib.die('the rebase did not move the record onto ' .. moved)
end
if latest.counts.open > 0 then
  lib.die('the rebase left ' .. latest.counts.open .. ' thread(s) open')
end
lib.say('REBASED ' .. latest.display .. ' base=' .. tostring(latest.base.commit))

press_and_wait('M', 600000)
if latest.display ~= 'merged' then
  lib.die('M still would not land the change after the rebase: ' .. tostring(latest.display))
end
lib.say('MERGED ' .. tostring(latest.merge.commit) .. ' on ' .. tostring(latest.merge.baseBranch))
os.exit(0)
