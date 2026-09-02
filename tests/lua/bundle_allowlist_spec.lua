--- Round-1 review regressions for `:Nvime bundle`. All red on f0e2e61, where
--- the session view was `vim.inspect`ed straight into the file: the big-change
--- control token, its socket path, and the user's own prompt (which is what
--- `title` is) all reached a file whose stated purpose is to be pasted into a
--- public issue.
---
--- The rule these encode: THE BUNDLE PRINTS WHAT IT NAMES, NEVER WHAT IT IS
--- HANDED. Every section is an allow-list over a shape the sidecar owns and
--- will grow new fields in.
local t = require('harness')
local bundle = require('nvime.bundle')
local log = require('nvime.log')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local SECRET = 'CONTROL-TOKEN-c0ffee-DO-NOT-PUBLISH'
local PROMPT = 'add oauth login using my personal ACME staging password hunter2'
local SOCKET = '/run/user/1000/nvime/ctl.sock'

--- Exactly the `SessionView` shape the sidecar sends — a `BigSession` spread
--- wholesale, control record and all.
local function session_view()
  return {
    version = 1,
    id = 'e3a1b2c4',
    repoRoot = '/home/me/proj',
    title = PROMPT,
    state = 'building',
    display = 'building',
    difficulty = 'medium',
    threshold = 70,
    createdAt = 1756800000000,
    updatedAt = 1756800600000,
    steerable = true,
    detached = true,
    runnerLive = true,
    heldElsewhere = false,
    worktreeExists = true,
    hasDiff = false,
    spec = { goal = PROMPT, approach = 'refactor the ' .. PROMPT },
    conversation = { { role = 'user', text = PROMPT } },
    transitions = { { state = 'building', at = 1756800000000 } },
    base = { commit = 'aa9fb774', branch = 'main' },
    worktree = { path = '/home/me/.local/share/nvime/big/wt', createdAt = 1, ready = true },
    merge = nil,
    runner = {
      pid = 4242,
      socket = SOCKET,
      log = '/home/me/.local/share/nvime/big/events.ndjson',
      what = 'build',
      startedAt = 1756800000000,
      token = SECRET,
    },
  }
end

local function parts()
  return {
    environment = { { label = 'nvime', value = '3.0.0 (abc1234)' } },
    config = { organization = { api_key = 'sk-ant-notreal-9999' } },
    doctor = { { level = 'ok', message = 'node v22.1.0' } },
    log = { level = 'info', path = '/tmp/nvime.log', size = 10, tail = { 'one' } },
    session = session_view(),
    runlog = {
      { seq = 1, at = 0, event = 'big.delta', params = { text = 'streaming ' .. SECRET } },
      { seq = 2, at = 1, event = 'big.tool', params = { tool = 'Edit', summary = 'Edit ' .. PROMPT } },
      { seq = 3, at = 2, event = 'big.phase', params = { phase = 'triage' } },
      { seq = 4, at = 3, event = 'big.steer', params = { text = PROMPT, origin = 'me', mine = true } },
    },
  }
end

local function rendered()
  return table.concat(bundle.render(parts()), '\n')
end

describe('bundle: the session section is an allow-list', function()
  it('never prints the big-change control token', function()
    ok(rendered():find(SECRET, 1, true) == nil, 'CRITICAL: the control token must never reach the bundle')
  end)

  it('never prints the control socket path', function()
    ok(rendered():find(SOCKET, 1, true) == nil, 'the socket and the token together are a live control channel')
  end)

  it("never prints the user's prompt, whatever field carries it", function()
    local text = rendered()
    ok(text:find(PROMPT, 1, true) == nil, 'HIGH: title/spec/conversation are all the reader’s own words')
    ok(text:find('hunter2', 1, true) == nil, text:sub(1, 400))
  end)

  it('prints exactly the fields a bug report needs, and no others', function()
    local text = rendered()
    -- The directory, not the clone path: the parent already says which session
    -- this is, and the full path carries a name derived from the repo.
    for _, needle in ipairs({ 'e3a1b2c4', 'building', 'aa9fb774', '/home/me/.local/share/nvime/big' }) do
      ok(text:find(needle, 1, true) ~= nil, 'the bundle must still report ' .. needle)
    end
    ok(text:find('pid 4242', 1, true) ~= nil, 'the runner is named by pid and liveness, never by record')
    ok(text:find('steerable', 1, true) ~= nil, text)
  end)

  it('survives a session view that grows a new secret-shaped field', function()
    local grown = parts()
    grown.session.futureAuthorization = SECRET
    grown.session.nested = { deeper = { apiKey = SECRET } }
    local text = table.concat(bundle.render(grown), '\n')
    ok(text:find(SECRET, 1, true) == nil, 'an allow-list cannot be outgrown by a field it does not name')
  end)
end)

describe('bundle: run-log params are an allow-list per event', function()
  it('records a delta as a size, never as its text', function()
    local text = rendered()
    ok(text:find('streaming ' .. SECRET, 1, true) == nil, 'a delta payload must never be printed')
    ok(text:find('big.delta', 1, true) ~= nil, 'the event itself is still listed')
  end)

  it('records a tool by name and its summary by length', function()
    local text = rendered()
    ok(text:find('Edit ' .. PROMPT, 1, true) == nil, 'a tool summary can quote what the reader wrote')
    ok(text:find('Edit', 1, true) ~= nil, 'the tool name is the diagnostic signal and is kept')
  end)

  it('records a phase by its phase string', function()
    ok(rendered():find('triage', 1, true) ~= nil, 'a phase change is the whole point of the run log')
  end)

  it('records an unknown event by its key names only', function()
    local text = rendered()
    ok(text:find('big.steer', 1, true) ~= nil, 'the event is listed')
    ok(text:find('origin', 1, true) ~= nil, 'its shape is described')
    ok(text:find('"me"', 1, true) == nil, 'but none of its values are printed')
  end)
end)

describe('bundle: redaction still applies on top', function()
  it('redacts a secret-named config value', function()
    local text = rendered()
    ok(text:find('sk-ant-notreal-9999', 1, true) == nil, 'REDACTION BOUNDARY')
    ok(text:find(log.REDACTED, 1, true) ~= nil, 'the field is shown as redacted rather than dropped')
  end)
end)

describe('bundle: the file on disk', function()
  local function scratch()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    return dir
  end

  local function read(path)
    local handle = io.open(path, 'r')
    if handle == nil then
      return nil
    end
    local body = handle:read('*a')
    handle:close()
    return body
  end

  it('carries no secret and no prompt, asserted against the bytes written', function()
    local path = bundle.write_to(scratch() .. '/bundle.md', parts())
    local body = read(path)
    ok(body ~= nil, 'the bundle file must exist')
    ok(body:find(SECRET, 1, true) == nil, 'CRITICAL: not even on disk')
    ok(body:find(PROMPT, 1, true) == nil, 'HIGH: not even on disk')
    ok(body:find(SOCKET, 1, true) == nil, 'not even on disk')
  end)

  -- F9: the bundle carries the doctor output, which names the git identity.
  it('is created 0600', function()
    local path = bundle.write_to(scratch() .. '/bundle.md', parts())
    eq(384, vim.uv.fs_stat(path).mode % 512, 'the bundle must be owner-only')
  end)

  -- F15: the name is stamped to one second, and two bundles in that second
  -- used to silently overwrite each other.
  it('never overwrites a bundle that is already there', function()
    local dir = scratch()
    local first = bundle.write_to(dir .. '/bundle.md', parts())
    local second = bundle.write_to(dir .. '/bundle.md', parts())
    ok(first ~= second, 'the second bundle takes its own name: ' .. tostring(second))
    ok(second:find('%-2%.md$') ~= nil, second)
    ok(read(first) ~= nil, 'and the first is still there')
  end)

  -- F19: `error()` inside the `big.runlog` callback surfaced as a raw traceback.
  it('reports an unwritable destination as a message, not a traceback', function()
    local seen = {}
    local real = vim.notify
    vim.notify = function(message, level)
      seen[#seen + 1] = { message = message, level = level }
    end
    local dir = scratch()
    local blocker = dir .. '/blocker'
    local handle = assert(io.open(blocker, 'w'))
    handle:write('a file, not a directory')
    handle:close()
    local written = bundle.write_to(blocker .. '/bundle.md', parts())
    vim.notify = real
    eq(nil, written, 'a failed write answers nil rather than raising')
    ok(#seen >= 1 and seen[1].message:find('bundle', 1, true) ~= nil, vim.inspect(seen))
  end)
end)

describe('bundle: gathering never blocks the editor on a hung binary', function()
  -- F5: `diagnostics.probe` is `vim.system():wait(10000)` on the main thread,
  -- and `gather_local` ran three of those plus a whole `diagnostics.run()` —
  -- including a second sidecar spawn — for up to ~70 s of frozen Neovim.
  it('bounds a version probe and prints (timed out)', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local shim = dir .. '/claude'
    local handle = assert(io.open(shim, 'w'))
    handle:write('#!/bin/sh\nsleep 60\n')
    handle:close()
    vim.uv.fs_chmod(shim, 493)

    local settled = false
    local started = vim.uv.now()
    bundle.probe_versions(shim, dir, function(facts)
      settled = true
      ok(facts.claude:find('timed out', 1, true) ~= nil, 'a hung probe is named, not waited on: ' .. facts.claude)
    end)
    ok(
      vim.wait(8000, function()
        return settled
      end, 20),
      'the probe must answer well inside the old 10 s wait'
    )
    ok(vim.uv.now() - started < 6000, 'it took ' .. (vim.uv.now() - started) .. 'ms')
  end)

  -- G2 HIGH: the round-1 test above drove `probe_versions` directly and never
  -- touched `gather()`, which is where the blocking half lived: `gather` ran
  -- `diagnostics.run` synchronously, and `SystemObj:wait` answers nil on a
  -- missed deadline — so the editor froze for 6 s and then the command threw,
  -- writing no bundle at all, in exactly the hung-binary case it exists for.
  it('writes a bundle without blocking, even when node never answers', function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, 'p')
    local shim = dir .. '/node'
    local handle = assert(io.open(shim, 'w'))
    handle:write('#!/bin/sh\nsleep 45\necho v22.0.0\n')
    handle:close()
    vim.uv.fs_chmod(shim, 493)

    local config = require('nvime.config')
    local written, done = nil, false
    local finished, err = pcall(function()
      config.setup({ agent = { node = shim, claude = shim } })
      local started = vim.uv.hrtime()
      require('nvime.bundle').write(function(path)
        written, done = path, true
      end)
      local blocked_ms = (vim.uv.hrtime() - started) / 1000000
      ok(blocked_ms < 100, 'the call itself must not block the editor: ' .. blocked_ms .. 'ms')
      ok(
        vim.wait(9000, function()
          return done
        end, 20),
        'the bundle must be written despite the hung binaries'
      )
    end)
    config.setup()
    if not finished then
      error(err, 0)
    end
    ok(written ~= nil, 'a bundle is written even when every probe times out')
    local file = assert(io.open(written, 'r'))
    local body = file:read('*a')
    file:close()
    os.remove(written)
    ok(body:find('(timed out)', 1, true) ~= nil, 'a probe that missed its deadline is named, not blank')
  end)

  it('does not spawn a second sidecar when the bundle asks for the checks', function()
    local diagnostics = require('nvime.diagnostics')
    local spawned = {}
    local real_system = vim.system
    vim.system = function(cmd, ...)
      spawned[#spawned + 1] = table.concat(cmd, ' ')
      return real_system(cmd, ...)
    end
    local finished, err = pcall(function()
      local entries = diagnostics.run(nil, { skip_sidecar = true })
      ok(type(entries) == 'table' and #entries > 0, 'the checks still run')
      local said = vim.iter(entries):any(function(entry)
        return entry.message:find('sidecar', 1, true) ~= nil
      end)
      ok(said, 'the live sidecar is reported instead of a fresh one being spawned')
    end)
    vim.system = real_system
    if not finished then
      error(err, 0)
    end
    local dist = require('nvime.agent').dist_path()
    for _, cmd in ipairs(spawned) do
      ok(cmd:find(dist, 1, true) == nil, 'the bundle path must not spawn a sidecar: ' .. cmd)
    end
  end)
end)
