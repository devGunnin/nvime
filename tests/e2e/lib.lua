--- Shared plumbing for the headless detached-build smoke: puts the plugin on
--- the runtimepath, drives one sidecar request at a time, and reports through a
--- file rather than print() (which coalesces short lines in `nvim -l`).
local root = vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))))
vim.opt.runtimepath:prepend(root)

local M = { root = root }

local out = assert(vim.env.NVIME_E2E_OUT, 'NVIME_E2E_OUT names the report file')

function M.say(line)
  local handle = assert(io.open(out, 'a'))
  handle:write(line .. '\n')
  handle:close()
end

function M.die(line)
  M.say('FAIL ' .. line)
  os.exit(1)
end

--- One request, waited out in the foreground. `timeout` bounds it, so a hung
--- sidecar fails the smoke instead of hanging the run.
function M.call(method, params, timeout)
  local agent = require('nvime.agent')
  local settled, err, result = false, nil, nil
  agent.request(method, params, function(request_err, request_result)
    settled, err, result = true, request_err, request_result
  end, { no_deadline = true })
  vim.wait(timeout, function()
    return settled
  end, 100)
  if not settled then
    M.die(method .. ' did not answer within ' .. timeout .. 'ms')
  end
  if err ~= nil then
    M.die(method .. ': ' .. tostring(err.message) .. ' / ' .. tostring(err.detail))
  end
  return result
end

--- The build log of the one session in this scratch store, or nil.
function M.log_path()
  local store = vim.fn.stdpath('data') .. '/nvime/big'
  local found = vim.fn.glob(store .. '/*/*/events.ndjson', false, true)
  return found[1]
end

function M.log_lines()
  local path = M.log_path()
  if path == nil then
    return 0
  end
  return #vim.fn.readfile(path)
end

return M
