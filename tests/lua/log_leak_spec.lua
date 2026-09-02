--- Round-2 merge-gate regressions: what the log lets through, and what the
--- bundle then attaches.
---
--- The bundle has THREE paths a secret can take, not two. Its session section
--- is an allow-list and its config goes through the redactor — both proved in
--- round 1 — but its `debug log — last 200 lines` section is a verbatim copy
--- of the log file. So for that third path the redaction has to hold AT THE
--- LOG LINE, and every case here asserts on the file bytes AND on what
--- `bundle.render` makes of them.
local t = require('harness')
local bundle = require('nvime.bundle')
local log = require('nvime.log')

local describe, it, ok = t.describe, t.it, t.ok

--- The marker stands in for the reader's own words. A big change's title is
--- the first 80 characters of what they typed, and its branch is a slug of
--- that title — so `hunter2` here is a password in a prompt.
local MARKER = 'hunter2'
local TITLE = 'fix the hunter2 staging password leak in auth.rs'
local BRANCH = 'nvime/big/fix-the-hunter2-staging-password-leak-in'
local SOCKET = '/run/user/1000/nvime/hunter2-SOCKET.sock'

local function scratch()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir .. '/nvime-' .. vim.uv.os_getpid() .. '.log'
end

local function read(path)
  local handle = io.open(path, 'r')
  if handle == nil then
    return ''
  end
  local body = handle:read('*a')
  handle:close()
  return body
end

--- The same lines the bundle would attach, rendered the way it renders them.
local function bundled()
  local status = log.status()
  status.tail = log.tail(200)
  return table.concat(
    bundle.render({
      environment = {},
      config = {},
      doctor = {},
      log = status,
      session = nil,
      runlog = nil,
    }),
    '\n'
  )
end

--- Runs `emit` against a fresh log and answers the file's bytes and the
--- bundle's rendering of them.
local function capture(emit)
  local path = scratch()
  log.set_level('info', path)
  emit()
  local rendered = bundled()
  log.close()
  return read(path), rendered
end

describe("the log tail is the bundle's third path", function()
  -- G1 HIGH: `big.ts` emitted `note: "landing on nvime/big/<slug>"`, and the
  -- slug is the user's own prompt. `note` is neither secret-named nor
  -- content-named, so it went into the log verbatim — and the log tail goes
  -- into the bundle. This is the cold review's F2 re-entering by another door.
  it('keeps a title-derived branch out of the log and out of the bundle', function()
    local bytes, rendered = capture(function()
      log.event('big.state', { id = 1, session = 'sess', state = 'reviewing', branch = BRANCH })
    end)
    ok(bytes:find(MARKER, 1, true) == nil, 'HIGH: the branch is the prompt — file bytes: ' .. bytes)
    ok(rendered:find(MARKER, 1, true) == nil, 'HIGH: and the bundle attaches the log verbatim')
    ok(bytes:find('big.state', 1, true) ~= nil, 'the event itself is still recorded')
  end)

  it('keeps the title and a bare slug out too, wherever they are carried', function()
    local bytes, rendered = capture(function()
      log.event('big.created', { title = TITLE, slug = 'fix-the-hunter2-staging-password-leak-in' })
      log.state_change('big', 'landing', { branch = BRANCH })
    end)
    ok(bytes:find(MARKER, 1, true) == nil, 'file bytes: ' .. bytes)
    ok(rendered:find(MARKER, 1, true) == nil, 'bundle')
  end)

  -- G7 MEDIUM: `big.view` carries the whole SessionView. `token` was redacted,
  -- `socket` was not — and `bundle.lua` states the invariant that the two
  -- together are a live control channel into the build.
  it('keeps the runner control socket out of the log and out of the bundle', function()
    local bytes, rendered = capture(function()
      log.event('big.view', {
        id = 1,
        session = {
          id = 'sess',
          display = 'building',
          runner = { pid = 4242, socket = SOCKET, token = 'CONTROL-TOKEN', what = 'build' },
        },
      })
    end)
    ok(bytes:find('SOCKET', 1, true) == nil, 'the socket path must be redacted: ' .. bytes)
    ok(bytes:find('CONTROL-TOKEN', 1, true) == nil, 'as the token already was')
    ok(rendered:find('SOCKET', 1, true) == nil, 'and neither reaches the bundle')
  end)

  it('still records what the event was, so the log stays worth reading', function()
    local bytes = capture(function()
      log.event('big.state', { session = 'sess', state = 'reviewing', branch = BRANCH, note = 'landing' })
    end)
    ok(bytes:find('reviewing', 1, true) ~= nil, bytes)
    ok(bytes:find('landing', 1, true) ~= nil, 'fixed prose is not content and stays legible')
    ok(bytes:find('chars>', 1, true) ~= nil, 'the branch is recorded as a size, not dropped')
  end)
end)

describe('a content key never recurses', function()
  -- D1 HIGH: `spec` was a CONTENT_KEY, but the summariser only fired for a
  -- string or a list. A `BigSpec` is an OBJECT, so `redact` walked into it and
  -- `goal`/`approach` — the approved plan, in the reader's own words — landed
  -- verbatim in the log and in the bundle. The same object, one field over
  -- from the `title` that round 2 closed.
  local SPEC = {
    goal = 'stop the hunter2 staging password leaking into auth logs',
    scope = { 'src/hunter2_auth.rs' },
    approach = 'rotate the hunter2 credential and scrub the log sink',
    acceptance = { 'no hunter2 in any sink' },
    outOfScope = { 'the hunter2 rotation runbook' },
  }

  it('summarises a spec object rather than walking into it', function()
    local bytes, rendered = capture(function()
      log.event('big.view', { id = 1, session = { id = 'sess', display = 'building', spec = SPEC } })
    end)
    ok(bytes:find(MARKER, 1, true) == nil, 'HIGH: the approved plan is what the reader typed: ' .. bytes)
    ok(rendered:find(MARKER, 1, true) == nil, 'HIGH: and the bundle attaches the log verbatim')
    ok(bytes:find('spec', 1, true) ~= nil, 'the field is still named')
    ok(bytes:find('keys', 1, true) ~= nil, 'and described by shape: ' .. bytes)
  end)

  it('holds for a spec arriving on its own, outside a session wrapper', function()
    local bytes = capture(function()
      log.event('big.intake', { id = 1, spec = SPEC })
      log.state_change('big', 'approved', { spec = SPEC })
    end)
    ok(bytes:find(MARKER, 1, true) == nil, bytes)
  end)

  it('holds for each spec field arriving unwrapped', function()
    local bytes = capture(function()
      for key, value in pairs(SPEC) do
        log.event('big.notice', { [key] = value })
      end
    end)
    ok(bytes:find(MARKER, 1, true) == nil, 'belt and braces: a spec field can arrive alone: ' .. bytes)
  end)

  -- `pairs` order is not defined, and `redact` walks a table with it: a leak
  -- that depends on which key is visited first would pass intermittently.
  it('does not depend on the order the table happens to be walked in', function()
    for _ = 1, 20 do
      local bytes = capture(function()
        log.event('big.view', { id = 1, session = { spec = SPEC, runner = { pid = 1 }, id = 'sess' } })
      end)
      ok(bytes:find(MARKER, 1, true) == nil, bytes)
    end
  end)

  it('still lets an ordinary settings table through, judged by its own names', function()
    -- Why the escape hatch existed: `context` is a block list in an RPC
    -- payload and a settings table in the config the bundle renders. It is no
    -- longer a content key at all — its children answer for themselves.
    local redacted = log.redact({ context = { max_file_bytes = 204800, blocks = { { text = 'secret' } } } })
    t.eq(204800, redacted.context.max_file_bytes, 'a number is not content')
    t.eq('<6 chars>', redacted.context.blocks[1].text, 'and the text inside it still is')
  end)
end)

describe('a list the user authored is content too', function()
  -- R1 MEDIUM: dropping `context` from CONTENT_KEYS in round 3 was right — it
  -- is a settings table in the config and a block list on the wire — but it
  -- had been covering the `dir` block's `entries`, which is a listing of the
  -- reader's own disk. Nothing else named it, so 400 of 400 file names went
  -- into the log and into the bundle.
  local BLOCKS = {
    { type = 'file', path = '/home/me/proj/a.md', text = 'the hunter2 note' },
    { type = 'dir', path = '/home/me/notes', entries = { 'acme-hunter2.md', 'b.md' } },
    { type = 'selection', path = '/home/me/proj/c.rs', startLine = 1, endLine = 2, text = 'hunter2' },
  }

  it('keeps an attached directory listing out of the log and the bundle', function()
    local bytes, rendered = capture(function()
      log.request('chat.send', 1, { root = '/home/me/proj', prompt = 'look', context = BLOCKS })
    end)
    ok(bytes:find(MARKER, 1, true) == nil, 'MEDIUM: an attached listing is the reader’s disk: ' .. bytes)
    ok(rendered:find(MARKER, 1, true) == nil, 'MEDIUM: and the bundle attaches the log verbatim')
    ok(bytes:find('items>', 1, true) ~= nil, 'the listing is still recorded as a size: ' .. bytes)
  end)

  it('holds for every context block variant, whichever order they arrive in', function()
    for _ = 1, 20 do
      local bytes = capture(function()
        log.request('chat.send', 1, { context = { BLOCKS[3], BLOCKS[2], BLOCKS[1] } })
        log.event('edit.started', { context = BLOCKS })
      end)
      ok(bytes:find(MARKER, 1, true) == nil, bytes)
    end
  end)

  it('keeps diff line arrays out too', function()
    local bytes = capture(function()
      log.event('big.diff', { hunks = { { file = 'a.rs', lines = { '-old hunter2', '+new' } } } })
    end)
    ok(bytes:find(MARKER, 1, true) == nil, 'a hunk’s lines are the file’s contents: ' .. bytes)
  end)
end)

describe('the clip is a budget, not a redactor', function()
  -- A short field that nobody named simply fits inside the 200-byte clip and
  -- is written out whole. Each name gets its own line here, so the clip cannot
  -- hide one behind another.
  local NAMED = {
    answer = 'my hunter2 defence of this thread',
    followup = 'what about hunter2 in the retry path?',
    ungraded = 'could not grade the hunter2 thread',
    label = 'use the hunter2 staging credential',
    detail = 'reads /etc/hunter2.conf',
    entries = { 'hunter2.md' },
  }

  it('records each user-authored field by size, one probe per name', function()
    for key, value in pairs(NAMED) do
      local bytes = capture(function()
        log.event('big.view', { [key] = value })
      end)
      ok(bytes:find(MARKER, 1, true) == nil, key .. ' was written out whole: ' .. bytes)
    end
  end)

  it('holds where they really live — inside a session view', function()
    local bytes, rendered = capture(function()
      log.event('big.view', {
        session = {
          id = 'sess',
          blocks = { { id = 'b1', rounds = { { answer = NAMED.answer, result = { followup = NAMED.followup } } } } },
          conversation = { { role = 'agent', options = { { label = NAMED.label, detail = NAMED.detail } } } },
          ungraded = NAMED.ungraded,
        },
      })
    end)
    ok(bytes:find(MARKER, 1, true) == nil, bytes)
    ok(rendered:find(MARKER, 1, true) == nil, 'bundle')
  end)
end)

describe('the merged timeline keeps the order the file has', function()
  -- G3 HIGH: the plugin stamped 20 bytes ending `Z`, the sidecar 24 ending
  -- `.123Z`, and the merge sorted on a 20-byte key — so `.` (0x2E) beat `Z`
  -- (0x5A) and EVERY agent line was hoisted above every editor line sharing a
  -- second. Both halves append to the same file, so the merge re-ordered a
  -- file that was already correct on disk.
  it('interleaves both halves in write order, not by stamp width', function()
    local path = scratch()
    log.set_level('info', path)
    log.request('big.merge', 7, {})
    log.close()
    -- The sidecar's own line, in the sidecar's own format, inside the same
    -- second: only the sort key's SHAPE can decide the order. Appended second,
    -- and it must stay second.
    local sent = vim.split(read(path), '\n', { plain = true, trimempty = true })[1]
    local second = sent:match('^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)')
    local agent_line = second .. '.999Z agent rpc handled big.merge #7 {}'
    local handle = assert(io.open(path, 'a'))
    handle:write(agent_line .. '\n')
    handle:close()
    t.eq({ sent, agent_line }, log.tail(10), 'the sidecar must not answer a request the log shows as sent afterwards')
  end)

  it('stamps its own lines with milliseconds, the shape the sidecar uses', function()
    local path = scratch()
    log.set_level('info', path)
    log.state_change('big', 'display', { to = 'merged' })
    log.close()
    local first = vim.split(read(path), '\n', { plain = true, trimempty = true })[1]
    ok(first:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ ') ~= nil, 'unexpected stamp: ' .. first)
    t.eq(24, #first:match('^(%S+)'), 'the sort key is the same width on both halves')
  end)
end)

describe('a log that gives up mid-session says so everywhere', function()
  -- G4 MEDIUM: `give_up` is the PRODUCTION failure path — a write with no
  -- handle, a rotation that cannot rename. It turned the level off but never
  -- set `broken` and never told the sidecar, so the doctor reported a
  -- mid-session failure as a user setting and the sidecar kept appending to a
  -- file the plugin had abandoned.
  it('records the failure, names it in the doctor, and stops the mirror', function()
    local agent = require('nvime.agent')
    local real = agent.set_debug_level
    local told = {}
    agent.set_debug_level = function(level)
      told[#told + 1] = level
    end
    local path = scratch()
    local said = {}
    local real_notify = vim.notify
    vim.notify = function(message)
      said[#said + 1] = message
    end
    local finished, err = pcall(function()
      log.set_level('info', path)
      log.close()
      log.event('big.tool', { tool = 'Bash' })
      vim.wait(300, function()
        return #told > 0
      end, 10)
    end)
    vim.notify = real_notify
    agent.set_debug_level = real
    if not finished then
      error(err, 0)
    end
    t.eq(path, log.status().broken, 'the path it gave up on is remembered')
    t.eq({ 'off' }, told, 'the sidecar half must stop mirroring into an abandoned file')
    local entry = require('nvime.diagnostics').log_entry()
    t.eq('warn', entry.level, 'a mid-session failure is not a user setting')
    ok(entry.message:find('stopped', 1, true) ~= nil, entry.message)
    ok(entry.message:find(path, 1, true) ~= nil, entry.message)
    log.set_level('off', scratch())
  end)
end)

describe('the merged tail does not double-count one file', function()
  -- G12 LOW: `M.files` stats candidates, then `M.tail` opens each. Another
  -- editor rotating in between makes one inode readable under two names, and
  -- the dedup was by path string.
  it('lists a file once even when two names reach the same inode', function()
    local path = scratch()
    local handle = assert(io.open(path, 'w'))
    handle:write('2026-01-01T00:00:01.000Z only once\n')
    handle:close()
    local linked = vim.uv.fs_link(path, path .. '.1')
    if not linked then
      return
    end
    log.set_level('info', path)
    log.close()
    local seen = 0
    for _, line in ipairs(log.tail(10)) do
      if line:find('only once', 1, true) ~= nil then
        seen = seen + 1
      end
    end
    t.eq(1, seen, 'one inode is one file, whatever it is called')
  end)
end)
