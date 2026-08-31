--- Headless Lua test runner: `nvim --clean -l tests/run.lua`.
local root = vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.runtimepath:prepend(root)
package.path = root .. '/tests/?.lua;' .. package.path

local harness = require('harness')

local specs = vim.fn.glob(root .. '/tests/lua/*_spec.lua', false, true)
table.sort(specs)
if #specs == 0 then
  io.write('no specs found under tests/lua\n')
  os.exit(1)
end

for _, spec in ipairs(specs) do
  io.write(vim.fs.basename(spec) .. '\n')
  local chunk, load_err = loadfile(spec)
  if chunk == nil then
    harness.failures[#harness.failures + 1] = { label = spec, err = load_err }
    io.write('  FAIL could not load: ' .. tostring(load_err) .. '\n')
  else
    local ok, run_err = xpcall(chunk, debug.traceback)
    if not ok then
      harness.failures[#harness.failures + 1] = { label = spec, err = run_err }
      io.write('  FAIL spec aborted: ' .. tostring(run_err) .. '\n')
    end
  end
end

io.write(string.format('\n%d passed, %d failed\n', harness.passed, #harness.failures))
for _, failure in ipairs(harness.failures) do
  io.write('\n--- ' .. failure.label .. '\n' .. tostring(failure.err) .. '\n')
end
os.exit(#harness.failures == 0 and 0 or 1)
