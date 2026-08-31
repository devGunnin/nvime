--- Minimal test harness for the headless Lua suite (`nvim -l tests/run.lua`).
--- Deliberately dependency-free: plenary is not a runtime dependency of nvime,
--- so the tests must not make it one.
local M = { failures = {}, passed = 0, current = nil }

function M.describe(name, fn)
  local previous = M.current
  M.current = previous and (previous .. ' › ' .. name) or name
  fn()
  M.current = previous
end

function M.it(name, fn)
  local label = (M.current and (M.current .. ' › ') or '') .. name
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    M.passed = M.passed + 1
    io.write('  ok   ' .. label .. '\n')
  else
    M.failures[#M.failures + 1] = { label = label, err = err }
    io.write('  FAIL ' .. label .. '\n')
  end
end

local function show(value)
  return type(value) == 'table' and vim.inspect(value) or tostring(value)
end

function M.eq(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    error(string.format('%s\nexpected: %s\nactual:   %s', message or 'values differ', show(expected), show(actual)), 2)
  end
end

function M.ok(value, message)
  if not value then
    error(message or 'expected a truthy value', 2)
  end
end

function M.throws(fn, pattern, message)
  local ok, err = pcall(fn)
  if ok then
    error(message or 'expected an error, got none', 2)
  end
  if pattern ~= nil and not tostring(err):match(pattern) then
    error(string.format('error did not match %q: %s', pattern, tostring(err)), 2)
  end
end

return M
