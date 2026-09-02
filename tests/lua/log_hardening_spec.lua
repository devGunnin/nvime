--- Round-1 review regressions for the debug log. Every case here was red on
--- f0e2e61: the log did filesystem work from the RPC receive path, formatted
--- payloads it then threw away at level `off`, ignored a failed rotation,
--- shared one file between Neovim instances, and left both files world-readable.
local t = require('harness')
local log = require('nvime.log')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local function scratch_dir()
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

local function write(path, body)
  local handle = assert(io.open(path, 'w'))
  handle:write(body)
  handle:close()
end

local function lines(path)
  return vim.split(read(path) or '', '\n', { plain = true, trimempty = true })
end

--- Runs `fn` with `vim.notify` captured, and returns what it said.
local function with_notices(fn)
  local seen = {}
  local real = vim.notify
  vim.notify = function(message, level)
    seen[#seen + 1] = { message = message, level = level }
  end
  local finished, err = pcall(fn)
  vim.notify = real
  if not finished then
    error(err, 0)
  end
  return seen
end

--- Runs `fn` inside a libuv timer callback — the same fast event context the
--- sidecar's frames arrive in — and returns pcall's verdict from in there.
local function in_fast_context(fn)
  local done, ok_run, err = false, nil, nil
  local timer = vim.uv.new_timer()
  timer:start(0, 0, function()
    ok_run, err = pcall(fn)
    done = true
  end)
  vim.wait(2000, function()
    return done
  end, 5)
  timer:stop()
  timer:close()
  return ok_run, err
end

describe('the log never does filesystem work in the RPC receive path', function()
  -- F3: `log.event` is called from `rpc.Client:_dispatch`, which runs in a fast
  -- event context. `vim.fn.mkdir` there raises E5560 and kills frame dispatch
  -- for every remaining line in the chunk — and for every chunk after it.
  it('takes an event from a fast context right after :Nvime log clear', function()
    local path = scratch_dir() .. '/nvime.log'
    log.set_level('info', path)
    log.request('chat.send', 1, {})
    log.clear()
    local settled, err = in_fast_context(function()
      log.event('big.tool', { tool = 'Bash' })
    end)
    ok(settled, 'an inbound event must never raise out of dispatch: ' .. tostring(err))
    log.close()
    eq(1, #lines(path), 'and the event is actually recorded, not silently dropped')
  end)

  it('drops the line and says so once when the handle is gone', function()
    local path = scratch_dir() .. '/nvime.log'
    log.set_level('info', path)
    log.close()
    local seen = with_notices(function()
      local settled = in_fast_context(function()
        log.event('big.tool', { tool = 'Bash' })
        log.event('big.tool', { tool = 'Read' })
      end)
      ok(settled, 'a missing handle is a dropped line, never an error')
      vim.wait(200, function()
        return false
      end, 10)
    end)
    eq(1, #seen, 'said once, not once per frame: ' .. vim.inspect(seen))
  end)
end)

describe('level off is free, not merely quiet', function()
  -- F4: Lua evaluates arguments before the call, so `emit('info', ... render())`
  -- ran a full recursive redact and a JSON encode per streamed token at `off`.
  it('formats nothing at all across a thousand delta events', function()
    log.set_level('off', scratch_dir() .. '/nvime.log')
    local encodes, redacts = 0, 0
    local real_encode, real_redact = vim.json.encode, log.redact
    vim.json.encode = function(...)
      encodes = encodes + 1
      return real_encode(...)
    end
    log.redact = function(...)
      redacts = redacts + 1
      return real_redact(...)
    end
    local finished, err = pcall(function()
      for index = 1, 1000 do
        log.event('big.delta', { text = 'token ' .. index })
      end
      log.request('chat.send', 1, { prompt = 'hello' })
      log.reply('chat.send', 1, 12, nil)
      log.state_change('big', 'display', { to = 'reviewing' })
    end)
    vim.json.encode, log.redact = real_encode, real_redact
    if not finished then
      error(err, 0)
    end
    eq(0, encodes, 'an off log must not encode anything')
    eq(0, redacts, 'nor copy a payload to redact it')
  end)

  it('still formats once the level asks for it', function()
    local path = scratch_dir() .. '/nvime.log'
    log.set_level('debug', path)
    local encodes = 0
    local real_encode = vim.json.encode
    vim.json.encode = function(...)
      encodes = encodes + 1
      return real_encode(...)
    end
    local finished = pcall(log.event, 'big.delta', { text = 'one' })
    vim.json.encode = real_encode
    ok(finished)
    eq(1, encodes, 'the guard must not have turned the log off by accident')
    log.close()
  end)
end)

describe('rotation reports its own failures', function()
  -- F6: neither `os.remove` nor `os.rename` was checked, so a rename that could
  -- not happen zeroed the byte count anyway and the file grew past the cap
  -- forever, silently, re-rotating on every line.
  it('latches and says so once when the rename cannot happen', function()
    local dir = scratch_dir()
    local path = dir .. '/nvime.log'
    -- A non-empty directory at the rotation target: neither `os.remove` nor
    -- `os.rename` can displace it, whoever is running the suite.
    vim.fn.mkdir(path .. '.1', 'p')
    write(path .. '.1/occupied', 'x')
    local real_cap = log.MAX_BYTES
    local seen
    local finished, err = pcall(function()
      log.MAX_BYTES = 2048
      log.set_level('info', path)
      seen = with_notices(function()
        for index = 1, 200 do
          log.state_change('big', 'bulk', { n = index })
        end
        -- The notice is scheduled, because `emit` can run in a fast event
        -- context; pump the loop so it lands while notify is still captured.
        vim.wait(200, function()
          return false
        end, 10)
      end)
    end)
    log.MAX_BYTES = real_cap
    log.close()
    if not finished then
      error(err, 0)
    end
    eq(1, #seen, 'one notice, not one per line: ' .. vim.inspect(seen))
    ok(seen[1].message:find('rotate', 1, true) ~= nil, seen[1].message)
    ok(vim.uv.fs_stat(path).size < 8192, 'writing stops instead of growing without bound')
  end)
end)

describe('one log file per process', function()
  -- F7: two Neovim instances sharing `nvime.log` rotated over each other's
  -- history, silently. Each process now owns `nvime-<pid>.log`.
  it('names the default file after this process', function()
    ok(log.default_path():find('nvime%-' .. vim.uv.os_getpid() .. '%.log$') ~= nil, log.default_path())
  end)

  it('merges every process file, and the rotated one, by timestamp', function()
    local dir = scratch_dir()
    local path = dir .. '/nvime-' .. vim.uv.os_getpid() .. '.log'
    write(dir .. '/nvime-4242.log', '2026-01-01T00:00:02Z other second\n2026-01-01T00:00:04Z other fourth\n')
    write(path .. '.1', '2026-01-01T00:00:00Z mine rotated\n')
    log.set_level('info', path)
    -- Written by hand rather than through emit: the point is the merge order,
    -- not this second's clock.
    log.close()
    local handle = assert(io.open(path, 'a'))
    handle:write('2026-01-01T00:00:01Z mine first\n2026-01-01T00:00:03Z mine third\n')
    handle:close()
    local merged = log.tail(10)
    eq({
      '2026-01-01T00:00:00Z mine rotated',
      '2026-01-01T00:00:01Z mine first',
      '2026-01-01T00:00:02Z other second',
      '2026-01-01T00:00:03Z mine third',
      '2026-01-01T00:00:04Z other fourth',
    }, merged)
  end)

  it('clears only this process file', function()
    local dir = scratch_dir()
    local path = dir .. '/nvime-' .. vim.uv.os_getpid() .. '.log'
    write(dir .. '/nvime-4242.log', '2026-01-01T00:00:02Z another editor\n')
    log.set_level('info', path)
    log.state_change('big', 'display', { to = 'merged' })
    log.clear()
    log.close()
    eq('', read(path), 'this process file is emptied')
    ok(read(dir .. '/nvime-4242.log'):find('another editor', 1, true) ~= nil, "another editor's log is untouched")
  end)

  it('prunes a week-old file from a dead pid, and nothing else', function()
    local dir = scratch_dir()
    local path = dir .. '/nvime-' .. vim.uv.os_getpid() .. '.log'
    local stale, recent = dir .. '/nvime-999999.log', dir .. '/nvime-999998.log'
    write(stale, 'old\n')
    write(recent, 'new\n')
    write(path, 'mine\n')
    local week_ago = os.time() - 8 * 24 * 60 * 60
    vim.uv.fs_utime(stale, week_ago, week_ago)
    vim.uv.fs_utime(path, week_ago, week_ago)
    log.set_level('info', path)
    log.close()
    eq(nil, vim.uv.fs_stat(stale), "a week-old dead pid's log is pruned")
    ok(vim.uv.fs_stat(recent) ~= nil, 'a recent one is kept')
    ok(vim.uv.fs_stat(path) ~= nil, 'and this process never prunes itself')
  end)
end)

describe('the log is not world-readable', function()
  -- F9: `io.open` takes the umask, so the log carrying project paths, session
  -- ids and git identity landed at 0644 on a shared host.
  it('creates the file 0600', function()
    local path = scratch_dir() .. '/nvime.log'
    log.set_level('info', path)
    log.state_change('big', 'display', { to = 'merged' })
    log.close()
    eq(384, vim.uv.fs_stat(path).mode % 512, 'the log must be owner-only')
  end)
end)

describe('the log view and a failed open', function()
  -- F10: `:Nvime log clear` left an open split showing the deleted lines.
  it('re-renders an open split when the log is cleared', function()
    local path = scratch_dir() .. '/nvime.log'
    log.set_level('info', path)
    for index = 1, 5 do
      log.state_change('big', 'bulk', { n = index })
    end
    log.open()
    eq(5, vim.api.nvim_buf_line_count(log.current().buf), 'the split shows what the log holds')
    log.clear()
    local shown = vim.api.nvim_buf_get_lines(log.current().buf, 0, -1, false)
    eq(1, #shown, 'a cleared log must not still show the deleted lines')
    ok(shown[1]:find('empty', 1, true) ~= nil, shown[1])
    log.close_view()
    log.close()
  end)

  -- F12: a failed open flipped the level to `off` behind the user's back and
  -- told nobody — not the sidecar, and not the doctor row, which then read as
  -- a user setting rather than a failure.
  it('reports a file it could not open as broken, not as off', function()
    local dir = scratch_dir()
    write(dir .. '/blocker', 'not a directory')
    local path = dir .. '/blocker/nvime.log'
    local seen = with_notices(function()
      log.set_level('info', path)
    end)
    eq('off', log.level(), 'a log that cannot be written is not on')
    eq(path, log.status().broken, 'and it remembers which file failed')
    ok(#seen >= 1, 'the failure is said out loud: ' .. vim.inspect(seen))
    local entry = require('nvime.diagnostics').log_entry()
    ok(entry.message:find('could not be opened', 1, true) ~= nil, entry.message)
    ok(entry.message:find(path, 1, true) ~= nil, entry.message)
    log.set_level('off', scratch_dir() .. '/nvime.log')
  end)
end)

describe('a probe that timed out says so', function()
  -- D2 LOW: `report_node` kept its probe error, `report_git_identity` did not
  -- — so a slow or hung `git` was reported as "git has no identity
  -- configured", which is a different problem with a different fix.
  --- A `git` that never answers, in a directory that is a repository.
  local function hung_git()
    local dir = scratch_dir()
    local shim = dir .. '/git'
    local handle = assert(io.open(shim, 'w'))
    handle:write('#!/bin/sh\nsleep 30\n')
    handle:close()
    vim.uv.fs_chmod(shim, 493)
    return shim
  end

  --- The git row from a set of diagnostic entries.
  local function git_row(entries)
    for _, entry in ipairs(entries) do
      if entry.message:find('git ', 1, true) == 1 then
        return entry.message
      end
    end
    return nil
  end

  -- Round 4: the blocking path was fixed, the ASYNC one was not — and the
  -- async one is what `:Nvime bundle` runs. `probe_async` signals a deadline
  -- as `cb(nil, nil)`, so the error the git branch looked for was never there.
  it('reports a hung git as a timeout on the path the bundle actually runs', function()
    local settled, said = false, nil
    require('nvime.diagnostics').run_async(vim.uv.cwd(), 300, function(entries)
      said = git_row(entries)
      settled = true
    end, { git = hung_git() })
    ok(
      vim.wait(5000, function()
        return settled
      end, 20),
      'run_async must answer inside its own deadline'
    )
    ok(said ~= nil, 'the git identity check must report something')
    ok(said:find('timed out', 1, true) ~= nil, said)
    ok(said:find('no identity configured', 1, true) == nil, 'a timeout is not a missing identity: ' .. said)
  end)

  it('reports a hung git as a timeout on the blocking path too', function()
    local entries = require('nvime.diagnostics').run(vim.uv.cwd(), {
      skip_sidecar = true,
      probe_timeout_ms = 300,
      git = hung_git(),
    })
    local said = git_row(entries)
    ok(said ~= nil, 'the git identity check must report something: ' .. vim.inspect(entries))
    ok(said:find('timed out', 1, true) ~= nil, said)
    ok(said:find('no identity configured', 1, true) == nil, 'a timeout is not a missing identity: ' .. said)
  end)
end)

describe('clipping is UTF-8 safe', function()
  -- F13: the Lua cut was a raw byte slice, so a multi-byte character straddling
  -- the budget went into the log — and into the bundle's markdown — in pieces.
  it('backs the cut off to a character boundary', function()
    local budget = log.MAX_PAYLOAD_CHARS
    -- The euro sign is three bytes; starting one at budget - 1 straddles the cut.
    local text = string.rep('a', budget - 1) .. string.rep('€', 4)
    local clipped = log.clip(text)
    local body = clipped:gsub('…%(clipped%)$', '')
    eq(string.rep('a', budget - 1), body, 'the partial character must not survive the cut')
    ok(vim.fn.strchars(clipped) > 0, 'and the result is decodable text')
  end)

  it('leaves text that fits alone', function()
    eq('short', log.clip('short'))
  end)
end)
