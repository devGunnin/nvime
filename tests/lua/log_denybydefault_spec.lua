--- Round 5: the log is DENY BY DEFAULT.
---
--- Four rounds each found the neighbouring field — the runner record, then the
--- title, then the spec beside it, then a `dir` block's listing. Enumerating
--- what to hide was the defect: every round the list was one name short of the
--- payload. So the rule is inverted here. A string is written only under a
--- name known to be safe; everything else is a size, whether or not anyone has
--- thought about it yet.
---
--- These tests assert the RULE, not a list of known leaks. The older leak
--- suites still pass beside them, but they are consequences now.
local t = require('harness')
local bundle = require('nvime.bundle')
local log = require('nvime.log')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local MARKER = 'hunter2'

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

--- The lines the bundle would attach, rendered the way it renders them.
local function bundled()
  local status = log.status()
  status.tail = log.tail(500)
  return table.concat(bundle.render({ environment = {}, config = {}, doctor = {}, log = status }), '\n')
end

local function capture(emit)
  local path = scratch()
  log.set_level('info', path)
  emit()
  local rendered = bundled()
  log.close()
  return read(path), rendered
end

describe('deny by default: a string needs a safe name', function()
  it('writes a string under a name nobody vouched for as a size', function()
    local bytes = capture(function()
      log.event('big.notice', { zzz_unthought_of = 'the hunter2 staging password' })
    end)
    ok(bytes:find(MARKER, 1, true) == nil, 'an unknown name must never be trusted: ' .. bytes)
    ok(bytes:find('chars>', 1, true) ~= nil, bytes)
  end)

  -- `reason` was a SAFE_KEYS candidate. It is not an enum: `policy.lua`'s
  -- deny/ask reasons are built prose that embed an error message and a path,
  -- `steer` returns an arbitrary close reason, and triage sets it from
  -- `cause.message`. It reaches the wire on `big.denied` and `edit.approval`.
  it('denies reason, which carries free text however enum-shaped it looks', function()
    local bytes = capture(function()
      log.event('big.denied', { tool = 'Write', reason = 'nvime could not resolve /etc/hunter2.conf' })
    end)
    ok(bytes:find(MARKER, 1, true) == nil, bytes)
    ok(bytes:find('Write', 1, true) ~= nil, 'the tool name is the diagnostic signal and stays')
  end)

  it('recurses into an object so its leaves are judged by their own names', function()
    local bytes = capture(function()
      log.event('big.view', {
        session = { id = 'sess', display = 'building', spec = { goal = 'fix the ' .. MARKER } },
      })
    end)
    ok(bytes:find(MARKER, 1, true) == nil, bytes)
    ok(bytes:find('building', 1, true) ~= nil, 'a safe leaf under an unsafe parent still reads')
    ok(bytes:find('sess', 1, true) ~= nil, bytes)
  end)

  it('passes numbers and booleans through whatever they are called', function()
    local redacted = log.redact({ anything_at_all = 42, whatever = true, nested = { n = -1.5 } })
    eq(42, redacted.anything_at_all)
    eq(true, redacted.whatever)
    eq(-1.5, redacted.nested.n)
  end)

  it('keeps a list of strings as a count, even under a safe name', function()
    local redacted = log.redact({ files = { 'a.rs', 'b.rs' }, seq = { 1, 2, 3 } })
    eq('<2 items>', redacted.files, 'a list of strings is a size, safe name or not')
    eq({ 1, 2, 3 }, redacted.seq, 'a list of numbers under a safe name still reads')
  end)

  it('gives a secret name precedence over a safe one', function()
    -- `path` is safe; `socket` is secret and contains no safe substring.
    local redacted = log.redact({ path = '/home/me/proj', socket = '/run/user/1/x.sock' })
    eq('/home/me/proj', redacted.path)
    eq(log.REDACTED, redacted.socket)
  end)

  it('never lets the clip be the reason something is safe', function()
    local bytes = capture(function()
      log.event('big.notice', { unnamed = MARKER })
    end)
    ok(bytes:find(MARKER, 1, true) == nil, 'a seven-character secret fits the clip and must still go: ' .. bytes)
  end)
end)

describe('deny by default: a safe key needs a producer that vouches for it', function()
  -- F1 MEDIUM: `origin` was allowed as "which editor sent a steer". It is not
  -- machine identity on the way IN: `runsock.ts` accepts any string as a
  -- steer's `from` and only ever renders it, so a peer chooses the label. The
  -- plugin only ever type-checks it — the value is never read.
  it('denies a steer origin, which a peer chooses the text of', function()
    local bytes, rendered = capture(function()
      log.event('big.steer', { state = 'queued', origin = 'from-' .. MARKER, mine = false })
    end)
    ok(bytes:find(MARKER, 1, true) == nil, 'a peer-supplied label is not machine identity: ' .. bytes)
    ok(rendered:find(MARKER, 1, true) == nil, 'and the bundle attaches the log verbatim')
    ok(bytes:find('queued', 1, true) ~= nil, 'the steer state is nvime’s own and stays')
  end)

  -- F7: a safe name with no producer is a free pass for whatever gets that
  -- name next; `model` is typed by hand at `:Nvime model`.
  it('denies a name nothing produces, and one the reader types', function()
    local redacted = log.redact({ outcome = MARKER, model = 'my-' .. MARKER .. '-model' })
    eq('<7 chars>', redacted.outcome, 'no producer means no vouching')
    eq('<16 chars>', redacted.model, 'a model id is typed by hand at :Nvime model')
  end)
end)

describe('deny by default: the timeline stays readable', function()
  it('renders every safe key that carries a string', function()
    for _, key in ipairs(log.SAFE_KEYS) do
      local value = 'v-' .. key
      local redacted = log.redact({ [key] = value })
      eq(value, redacted[key], key .. ' is on the safe list but did not render')
    end
  end)

  it('keeps the fields a stuck run is diagnosed from', function()
    local bytes = capture(function()
      log.request('big.merge', 7, { root = '/home/me/proj', sessionId = 'sess-1' })
      log.reply('big.merge', 7, 810, { code = 'agent_error' })
      log.state_change('edit', 'start', { kind = 'selection', file = 'src/auth.rs', range = '10-24' })
      log.event('big.state', { session = 'sess-1', state = 'reviewing', phase = 'triage' })
    end)
    for _, needle in ipairs({
      'big.merge',
      '/home/me/proj',
      'sess-1',
      'agent_error',
      'selection',
      'src/auth.rs',
      '10-24',
      'reviewing',
      'triage',
    }) do
      ok(bytes:find(needle, 1, true) ~= nil, 'the log must still say ' .. needle .. ': ' .. bytes)
    end
  end)
end)

describe('deny by default: a property, not a list', function()
  --- One random value tree. Strings are the sentinel; keys are random names
  --- that are deliberately NOT on the safe list.
  local function noise(depth, rand)
    if depth <= 0 or rand(3) == 1 then
      return 'leading ' .. MARKER .. ' trailing'
    end
    local out = {}
    for index = 1, rand(4) do
      out['k' .. rand(100000) .. '_' .. index] = noise(depth - 1, rand)
    end
    return out
  end

  it('never writes a sentinel under 200 random shapes, in the log or the bundle', function()
    -- Seeded, so a failure is reproducible rather than a story about a run.
    math.randomseed(20260902)
    local rand = function(n)
      return math.random(n)
    end
    local path = scratch()
    log.set_level('info', path)
    for _ = 1, 200 do
      log.event('big.view', noise(4, rand))
      log.request('chat.send', 1, noise(3, rand))
      log.state_change('big', 'random', noise(3, rand))
    end
    local rendered = bundled()
    log.close()
    local bytes = read(path)
    ok(bytes:find(MARKER, 1, true) == nil, 'a random shape reached the log')
    ok(rendered:find(MARKER, 1, true) == nil, 'a random shape reached the bundle')
    ok(#bytes > 0, 'the log was actually written to')
  end)
end)

describe('deny by default: the real payloads, repeatedly', function()
  local BLOCKS = {
    { type = 'file', path = '/home/me/proj/a.md', text = 'the ' .. MARKER .. ' note' },
    { type = 'dir', path = '/home/me/notes', entries = { 'acme-' .. MARKER .. '.md' } },
    { type = 'selection', path = '/home/me/proj/c.rs', startLine = 1, endLine = 2, text = MARKER },
  }

  local SESSION = {
    id = 'sess-1',
    title = 'fix the ' .. MARKER .. ' leak',
    state = 'building',
    display = 'building',
    steerable = true,
    spec = { goal = MARKER, scope = { MARKER }, approach = MARKER, acceptance = {}, outOfScope = {} },
    conversation = { { role = 'user', text = MARKER, options = { { label = MARKER, detail = MARKER } } } },
    blocks = { { id = 'b1', files = { 'a.rs' }, rounds = { { answer = MARKER, result = { followup = MARKER } } } } },
    base = { commit = 'aa9fb774', branch = 'nvime/big/fix-the-' .. MARKER },
    worktree = { path = '/home/me/.local/share/nvime/big/wt' },
    runner = { pid = 4242, socket = '/run/' .. MARKER .. '.sock', token = MARKER },
  }

  it('holds across every real shape, fifty times over', function()
    local path = scratch()
    log.set_level('info', path)
    for _ = 1, 50 do
      log.event('big.view', { id = 1, session = SESSION })
      log.request('chat.send', 2, { root = '/home/me/proj', prompt = MARKER, context = BLOCKS })
      log.request('edit.start', 3, { scope = { kind = 'selection', path = '/home/me/proj/c.rs', text = MARKER } })
      log.state_change('edit', 'start', { kind = 'selection', file = '/home/me/proj/c.rs', range = '1-2' })
      log.event('big.notice', { text = 'the merge failed: ' .. MARKER })
      log.reply('big.merge', 3, 12, { code = 'agent_error', message = MARKER, detail = MARKER })
    end
    local rendered = bundled()
    log.close()
    local bytes = read(path)
    ok(bytes:find(MARKER, 1, true) == nil, 'the sentinel reached the log')
    ok(rendered:find(MARKER, 1, true) == nil, 'the sentinel reached the bundle')
    -- Asserted on the short lines, where what survives is the rule rather than
    -- the 200-byte clip: a whole `SessionView` is wider than the budget, and
    -- which of its fields lands inside it is JSON key order.
    local edit_line = bytes:match('[^\n]*state edit start[^\n]*') or ''
    for _, needle in ipairs({ 'selection', '/home/me/proj/c.rs', '1-2' }) do
      ok(edit_line:find(needle, 1, true) ~= nil, 'the edit line must still say ' .. needle .. ': ' .. edit_line)
    end
    local rpc_line = bytes:match('[^\n]*rpc > chat%.send[^\n]*') or ''
    ok(rpc_line:find('/home/me/proj', 1, true) ~= nil, 'the project root still reads: ' .. rpc_line)
    local reply_line = bytes:match('[^\n]*rpc < big%.merge[^\n]*') or ''
    ok(reply_line:find('agent_error', 1, true) ~= nil, 'the failure code still reads: ' .. reply_line)
  end)
end)
