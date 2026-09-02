local t = require('harness')
local bundle = require('nvime.bundle')
local log = require('nvime.log')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Everything `bundle.render` needs, with a token-shaped secret planted in the
--- config so the redaction boundary is exercised by every case here.
local function parts()
  return {
    environment = {
      { label = 'nvime', value = '3.0.0 (abc1234)' },
      { label = 'neovim', value = 'v0.11.0' },
      { label = 'os', value = 'Linux x86_64' },
      { label = 'node', value = 'v22.1.0' },
      { label = 'claude', value = '2.0.1' },
    },
    config = {
      panel = { width = 80 },
      organization = { control_plane_url = 'https://example.test', api_key = 'sk-ant-notreal-9999' },
    },
    doctor = {
      { level = 'ok', message = 'node v22.1.0' },
      { level = 'error', message = 'the sidecar is not built', advice = 'npm run build' },
    },
    log = { level = 'info', path = '/somewhere/nvime.log', size = 2048, tail = { 'one', 'two' } },
    session = {
      id = 'abc',
      state = 'reviewing',
      display = 'reviewing',
      steerable = false,
      base = { commit = 'aaa', branch = 'main' },
      merge = { commit = 'bbb', branch = 'nvime/big/x', baseBranch = 'main', at = 1 },
      worktree = { path = '/tmp/wt', createdAt = 1, ready = true },
    },
    runlog = {
      { seq = 1, at = 0, event = 'big.delta', params = { text = string.rep('z', 500) } },
      { seq = 2, at = 1, event = 'big.done', params = { ok = true } },
    },
  }
end

local function rendered(overrides)
  local body = parts()
  for key, value in pairs(overrides or {}) do
    body[key] = value ~= vim.NIL and value or nil
  end
  return table.concat(bundle.render(body), '\n')
end

describe('nvime.bundle rendering', function()
  it('carries the environment a bug report needs', function()
    local text = rendered()
    for _, needle in ipairs({ '3.0.0 (abc1234)', 'v0.11.0', 'Linux x86_64', 'v22.1.0', '2.0.1' }) do
      ok(text:find(needle, 1, true) ~= nil, 'the bundle must report ' .. needle)
    end
  end)

  it('carries the doctor findings, failures and their fixes alike', function()
    local text = rendered()
    ok(text:find('the sidecar is not built', 1, true) ~= nil, 'the failure is in the bundle')
    ok(text:find('npm run build', 1, true) ~= nil, 'so is the fix that names it')
  end)

  it('carries the log level, path, size and tail', function()
    local text = rendered()
    ok(text:find('/somewhere/nvime.log', 1, true) ~= nil)
    ok(text:find('info', 1, true) ~= nil)
    ok(text:find('two', 1, true) ~= nil, 'the tail lines are included verbatim')
  end)

  it('carries the big-change session view when there is one', function()
    local text = rendered()
    for _, needle in ipairs({ 'reviewing', 'aaa', 'bbb', 'steerable', '/tmp/wt' }) do
      ok(text:find(needle, 1, true) ~= nil, 'the session view must report ' .. needle)
    end
  end)

  it('says so plainly when no big change is selected', function()
    local text = rendered({ session = vim.NIL, runlog = vim.NIL })
    ok(text:find('no big change', 1, true) ~= nil, 'an absent session is stated, not silently dropped')
  end)

  it('clips a run-log event payload instead of pasting it in', function()
    local text = rendered()
    ok(text:find('zzzzzzzzzzzzzzzzzzzz', 1, true) == nil, 'a long event payload must be clipped')
    ok(text:find('big.done', 1, true) ~= nil, 'the events themselves are still listed')
  end)

  it('never lets a token-shaped config value reach the bundle', function()
    local text = rendered()
    ok(text:find('sk-ant-notreal-9999', 1, true) == nil, 'REDACTION BOUNDARY: the secret must not be in the bundle')
    ok(text:find(log.REDACTED, 1, true) ~= nil, 'the field is shown as redacted rather than dropped')
    ok(text:find('https://example.test', 1, true) ~= nil, 'a non-secret setting is still reported')
  end)
end)

describe('nvime.bundle file', function()
  it('names the file with a timestamp under the cache directory', function()
    local path = bundle.path(1756800000)
    ok(path:find('nvime%-bundle%-.*%.md$') ~= nil, 'unexpected bundle name: ' .. path)
    ok(path:find(vim.fn.stdpath('cache'), 1, true) == 1, 'the bundle lives under stdpath(cache)')
  end)

  it('writes the rendered bundle and hands the path back through the registers', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local path = dir .. '/nvime-bundle-test.md'
    bundle.write_to(path, parts())
    local handle = io.open(path, 'r')
    ok(handle ~= nil, 'the bundle file must exist')
    local body = handle:read('*a')
    handle:close()
    ok(body:find('sk-ant-notreal-9999', 1, true) == nil, 'REDACTION BOUNDARY: not even on disk')
    -- `+` needs a clipboard provider a headless run has no reason to have, so
    -- only the always-available unnamed register is asserted here.
    bundle.deliver(path)
    eq(path, vim.fn.getreg('"'), 'the unnamed register carries the path')
  end)
end)
