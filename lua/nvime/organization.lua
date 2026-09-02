local agent = require('nvime.agent')
local config = require('nvime.config')
local context = require('nvime.context')
local palette = require('nvime.palette')

local M = {}

local view = { win = nil, buf = nil }

function M.managed()
  return config.get().organization.control_plane_url ~= nil
end

--- Fetches the live policy before a managed change begins. Community mode has
--- no policy and takes the existing local difficulty path.
--- @param callback fun(err: table|nil, policy: table|nil)
function M.policy(callback)
  assert(type(callback) == 'function', 'organization.policy needs a callback')
  if not M.managed() then
    callback(nil, nil)
    return
  end
  agent.request('organization.policy', {}, function(err, policy)
    if err ~= nil then
      callback(err, nil)
      return
    end
    if type(policy) ~= 'table' or type(policy.policyId) ~= 'string' then
      callback({ code = 'invalid_policy', message = 'control plane returned an invalid policy' }, nil)
      return
    end
    if type(policy.threshold) ~= 'number' or policy.threshold < 1 or policy.threshold > 100 then
      callback({ code = 'invalid_policy', message = 'control plane returned an invalid threshold' }, nil)
      return
    end
    callback(nil, policy)
  end)
end

--- The sidecar records an exact threshold; difficulty is only its readable
--- label for existing surfaces and prompts.
function M.difficulty(policy)
  assert(type(policy) == 'table', 'organization.difficulty needs a policy')
  assert(type(policy.threshold) == 'number', 'organization policy needs a threshold')
  if policy.gateMode ~= 'manual' then
    return policy.gateMode
  end
  if policy.threshold >= 90 then
    return 'extreme'
  end
  if policy.threshold >= 70 then
    return 'medium'
  end
  return 'easy'
end

local function close()
  if view.win ~= nil and vim.api.nvim_win_is_valid(view.win) then
    pcall(vim.api.nvim_win_close, view.win, true)
  end
  if view.buf ~= nil and vim.api.nvim_buf_is_valid(view.buf) then
    pcall(vim.api.nvim_buf_delete, view.buf, { force = true })
  end
  view.win, view.buf = nil, nil
end

local function show_enrollment(record)
  assert(type(record) == 'table', 'enrollment record must be a table')
  assert(type(record.keyId) == 'string', 'enrollment record must have a key ID')
  close()
  palette.apply()
  local json = vim.json.encode(record)
  local lines = {
    'Enrollment record',
    '',
    json,
    '',
    'Send this public record to your nvime administrator. The private key never leaves this workstation.',
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'json'
  local width = math.min(math.max(vim.o.columns - 8, 40), 110)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = math.min(#lines, math.max(vim.o.lines - 4, 1)),
    row = 2,
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = 'rounded',
    title = ' nvime enrollment ',
    footer = ' y copy · q close ',
    footer_pos = 'right',
  })
  view.win, view.buf = win, buf
  vim.keymap.set('n', 'q', close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', '<Esc>', close, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set('n', 'y', function()
    vim.fn.setreg('"', json)
    pcall(vim.fn.setreg, '+', json)
    vim.notify('nvime: public enrollment record copied')
  end, { buffer = buf, nowait = true, silent = true })
end

function M.enrollment()
  if not M.managed() then
    vim.notify('nvime: organization control plane is not configured', vim.log.levels.WARN)
    return
  end
  local root = context.project_root()
  agent.request('organization.enrollment', { root = root }, function(err, record)
    if err ~= nil then
      vim.notify('nvime: enrollment failed: ' .. (err.message or '?'), vim.log.levels.ERROR)
      return
    end
    show_enrollment(record)
  end)
end

function M.attest(root, session_id)
  assert(type(root) == 'string' and root ~= '', 'organization.attest needs a project root')
  assert(type(session_id) == 'string' and session_id ~= '', 'organization.attest needs a session ID')
  if not M.managed() then
    return
  end
  vim.notify('nvime: signing the reviewed commit for GitHub assurance')
  agent.request('organization.attest', { root = root, sessionId = session_id }, function(err, result)
    if err ~= nil then
      vim.notify('nvime: certification failed: ' .. (err.message or '?'), vim.log.levels.ERROR)
      return
    end
    vim.notify('nvime: GitHub understanding check accepted for ' .. result.commitSha:sub(1, 8))
  end, { no_deadline = true })
end

function M.current()
  return view
end

return M
