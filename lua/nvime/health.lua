--- `:checkhealth nvime`. Renders `diagnostics.run()` through `vim.health.*`;
--- `:Nvime doctor` (`doctor.lua`) renders the same entries as its own
--- pass/warn/fail list. The checks themselves live in `diagnostics.lua` so
--- the two surfaces cannot silently drift apart.
local diagnostics = require('nvime.diagnostics')

local M = {}

local REPORTERS = {
  ok = function(entry)
    vim.health.ok(entry.message)
  end,
  warn = function(entry)
    vim.health.warn(entry.message, entry.advice)
  end,
  error = function(entry)
    vim.health.error(entry.message, entry.advice)
  end,
  info = function(entry)
    vim.health.info(entry.message)
  end,
}

function M.check()
  vim.health.start('nvime')
  for _, entry in ipairs(diagnostics.run()) do
    local report = REPORTERS[entry.level]
    assert(report ~= nil, 'unknown diagnostic level: ' .. tostring(entry.level))
    report(entry)
  end
end

return M
