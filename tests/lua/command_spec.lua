local t = require('harness')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- The repo root, from this spec's own path — the same trick `tests/run.lua`
--- uses, so the plugin file is found however the suite was invoked.
local root = vim.fs.normalize(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))))

--- Installs a recorder in place of the `nvime` module and sources the plugin
--- file, so `:Nvime <sub>` routing is exercised without the real surfaces.
local function install()
  local calls = {}
  local function record(name)
    return function(...)
      calls[#calls + 1] = { name = name, args = { ... } }
    end
  end
  package.loaded['nvime'] = {
    chat = record('chat'),
    edit = record('edit'),
    big = record('big'),
    changeset = record('changeset'),
    cancel = record('cancel'),
    doctor = record('doctor'),
    model = record('model'),
    enrollment = record('enrollment'),
    dashboard = record('dashboard'),
    toggle_statusline = function()
      return true
    end,
    log = record('log'),
    bundle = record('bundle'),
    debug = record('debug'),
  }
  vim.g.loaded_nvime = nil
  pcall(vim.api.nvim_del_user_command, 'Nvime')
  vim.cmd.source(root .. '/plugin/nvime.lua')
  return calls
end

local function warnings(fn)
  local seen = {}
  local real = vim.notify
  vim.notify = function(message, level)
    seen[#seen + 1] = { message = message, level = level }
  end
  local ok_run, err = pcall(fn)
  vim.notify = real
  if not ok_run then
    error(err, 0)
  end
  return seen
end

describe(':Nvime diagnostics subcommands', function()
  it('routes log, bundle and debug to their handlers', function()
    local calls = install()
    vim.cmd('Nvime log')
    vim.cmd('Nvime bundle')
    vim.cmd('Nvime debug on')
    eq(3, #calls, vim.inspect(calls))
    eq('log', calls[1].name)
    eq('bundle', calls[2].name)
    eq('debug', calls[3].name)
  end)

  it('passes the remaining words through, so `log clear` reaches the handler', function()
    local calls = install()
    vim.cmd('Nvime log clear')
    eq('log', calls[1].name)
    eq({ 'clear' }, calls[1].args)
    vim.cmd('Nvime debug toggle')
    eq({ 'toggle' }, calls[2].args)
  end)

  it('offers the new subcommands in completion', function()
    install()
    local names = vim.fn.getcompletion('Nvime ', 'cmdline')
    for _, name in ipairs({ 'log', 'bundle', 'debug' }) do
      ok(vim.tbl_contains(names, name), name .. ' must be completable: ' .. vim.inspect(names))
    end
  end)

  it('still refuses an unknown subcommand', function()
    local calls = install()
    local seen = warnings(function()
      vim.cmd('Nvime nonsense')
    end)
    eq(0, #calls, 'nothing may run for a name the command does not know')
    ok(seen[1] ~= nil and seen[1].message:find('nonsense', 1, true) ~= nil, vim.inspect(seen))
  end)
end)

describe(':Nvime completion and arity after the nargs change', function()
  -- F16: the guard was `line:match('^%s*Nvime%s+%S+%s')`, which a command
  -- modifier defeats — `:silent Nvime log <Tab>` offered the subcommand list
  -- as an argument completion.
  it('does not offer subcommands as an argument, under a modifier too', function()
    install()
    for _, line in ipairs({ 'Nvime log ', 'silent Nvime log ', 'vert Nvime debug ' }) do
      local names = vim.fn.getcompletion(line, 'cmdline')
      ok(not vim.tbl_contains(names, 'statusline'), line .. ' offered a subcommand: ' .. vim.inspect(names))
    end
  end)

  it('completes the words debug and log actually take', function()
    install()
    local levels = vim.fn.getcompletion('Nvime debug ', 'cmdline')
    for _, word in ipairs({ 'on', 'off', 'toggle', 'info', 'debug' }) do
      ok(vim.tbl_contains(levels, word), word .. ' must be completable: ' .. vim.inspect(levels))
    end
    ok(vim.tbl_contains(vim.fn.getcompletion('Nvime log ', 'cmdline'), 'clear'), 'log takes clear')
  end)

  -- F16: `nargs='?'` used to reject a trailing word outright; `'*'` silently
  -- swallowed it, so `:Nvime chat extra` looked like it did something.
  it('refuses a trailing word for a subcommand that takes none', function()
    local calls = install()
    local seen = warnings(function()
      vim.cmd('Nvime chat extra')
    end)
    eq(0, #calls, 'nothing may run for a command with an argument it cannot take')
    ok(seen[1] ~= nil and seen[1].message:find('takes no argument', 1, true) ~= nil, vim.inspect(seen))
  end)
end)
