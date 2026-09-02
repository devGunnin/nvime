local t = require('harness')
local log = require('nvime.log')

local describe, it, eq, ok, throws = t.describe, t.it, t.eq, t.ok, t.throws

--- A fresh log path under nvim's own temp dir: never the operator's real
--- `stdpath('log')`, which a headless run must not touch.
local function scratch()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir .. '/nvime.log'
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

local function lines(path)
  return vim.split(read(path) or '', '\n', { plain = true, trimempty = true })
end

describe('nvime.log level', function()
  it('writes nothing and creates no file at level off', function()
    local path = scratch()
    log.set_level('off', path)
    log.request('big.merge', 7, { root = '/repo' })
    log.reply('big.merge', 7, 12, nil)
    log.event('big.delta', { text = 'hi' })
    log.state_change('big', 'display', { from = 'reviewing', to = 'merged' })
    log.close()
    eq(nil, read(path), 'level off must not even create the file')
  end)

  it('rejects a level it does not know', function()
    throws(function()
      log.set_level('verbose', scratch())
    end, 'debug.level')
  end)

  it('writes one line per request and per reply at info', function()
    local path = scratch()
    log.set_level('info', path)
    log.request('big.merge', 7, { root = '/repo', sessionId = 'abc' })
    log.reply('big.merge', 7, 1234, nil)
    log.close()
    local written = lines(path)
    eq(2, #written, 'one request line and one reply line')
    ok(written[1]:find('big.merge', 1, true) ~= nil, 'the request line names the method')
    ok(written[1]:find('#7', 1, true) ~= nil, 'the request line names the request id')
    ok(written[2]:find('1234ms', 1, true) ~= nil, 'the reply line carries the duration')
    ok(written[2]:find('ok', 1, true) ~= nil, 'the reply line carries the outcome')
  end)

  it('names the error code on a failed reply', function()
    local path = scratch()
    log.set_level('info', path)
    log.reply('big.merge', 9, 5, { code = 'base-moved', message = 'the base moved' })
    log.close()
    local written = lines(path)
    eq(1, #written)
    ok(written[1]:find('base%-moved') ~= nil, 'the outcome must name the failure code')
  end)

  it('records a state transition with its surface and fields', function()
    local path = scratch()
    log.set_level('info', path)
    log.state_change('big', 'display', { from_display = 'reviewing', to_display = 'merged' })
    log.close()
    local written = lines(path)
    eq(1, #written)
    ok(written[1]:find('big', 1, true) ~= nil, 'the line names the surface')
    ok(written[1]:find('merged', 1, true) ~= nil, 'the line carries the transition')
  end)

  it('keeps streaming deltas out of an info log and lets them into a debug one', function()
    local quiet = scratch()
    log.set_level('info', quiet)
    log.event('big.delta', { text = 'one token' })
    log.event('big.done', { ok = true })
    log.close()
    eq(1, #lines(quiet), 'info records the terminal event but not every delta')

    local loud = scratch()
    log.set_level('debug', loud)
    log.event('big.delta', { text = 'one token' })
    log.event('big.done', { ok = true })
    log.close()
    eq(2, #lines(loud), 'debug records the deltas too')
  end)
end)

describe('nvime.log redaction', function()
  it('treats secret-shaped names as secret and ordinary ones as not', function()
    for _, name in ipairs({ 'token', 'accessToken', 'api_key', 'apiKey', 'key', 'secret', 'Authorization' }) do
      ok(log.is_secret_key(name), name .. ' must be treated as a secret')
    end
    for _, name in ipairs({ 'keymaps', 'monkey', 'sessionId', 'root', 'difficulty' }) do
      ok(not log.is_secret_key(name), name .. ' must not be mistaken for a secret')
    end
  end)

  it('replaces a secret value at every nesting level', function()
    local redacted = log.redact({
      root = '/repo',
      organization = { api_key = 'sk-ant-notreal-0001', github = 'gh' },
    })
    eq('/repo', redacted.root, 'a safe name still reads')
    eq('<2 chars>', redacted.organization.github, 'an unvouched-for name is a size')
    eq(log.REDACTED, redacted.organization.api_key)
  end)

  it('redacts only secrets in nvime’s own settings, which have a bounded shape', function()
    -- `redact_secrets` is for the config the bundle renders: `setup()` refuses
    -- a key the defaults do not name, so there is nothing unvouched-for in it.
    local settings = log.redact_secrets({
      organization = { api_key = 'sk-ant-notreal-0001', github = 'gh' },
      keymaps = { chat = '<leader>nc' },
    })
    eq('gh', settings.organization.github)
    eq('<leader>nc', settings.keymaps.chat)
    eq(log.REDACTED, settings.organization.api_key)
  end)

  it('never lets a secret value reach a logged line', function()
    local path = scratch()
    log.set_level('info', path)
    log.request('organization.attest', 3, { root = '/repo', token = 'sk-ant-notreal-0002' })
    log.close()
    local body = read(path)
    ok(body:find('sk%-ant%-notreal%-0002') == nil, 'the secret must not appear in the log')
    ok(body:find(log.REDACTED, 1, true) ~= nil, 'the field is present, its value redacted')
  end)

  it('summarises user content instead of writing it out', function()
    local path = scratch()
    log.set_level('info', path)
    log.request('chat.send', 4, { root = '/repo', prompt = string.rep('a', 400) })
    log.close()
    local body = read(path)
    ok(body:find('aaaa', 1, true) == nil, 'prompt text must never be written')
    ok(body:find('400 chars', 1, true) ~= nil, 'its size is recorded instead')
  end)

  it('reduces anything not vouched for, whatever shape it arrives in', function()
    -- Round 5: there is no list of dangerous names any more. A string needs a
    -- safe name; a list needs a safe name AND numeric elements; an object
    -- recurses so each leaf answers for itself.
    eq('<2 items>', log.redact({ answers = { { text = 'a' }, { text = 'b' } } }).answers)
    eq('<8 chars>', log.redact({ prompt = 'a prompt' }).prompt)
    eq('<7 chars>', log.redact({ spec = { goal = 'ship it' } }).spec.goal, 'the leaf answers for itself')
  end)

  it('lets a number through under any name, and a string under none', function()
    eq(204800, log.redact({ context = { max_file_bytes = 204800 } }).context.max_file_bytes)
    eq('<1 items>', log.redact({ context = { { path = 'a', text = 'x' } } }).context)
  end)

  it('clips a long payload to roughly the line budget', function()
    local path = scratch()
    log.set_level('info', path)
    log.request('big.open', 5, { root = string.rep('/deep', 200) })
    log.close()
    local written = lines(path)
    eq(1, #written)
    ok(#written[1] < 400, 'a logged line stays short: ' .. #written[1])
  end)
end)

describe('nvime.log rotation', function()
  it('caps the live log at 5 MB', function()
    eq(5 * 1024 * 1024, log.MAX_BYTES)
  end)

  it('rotates past the cap and keeps exactly one .1', function()
    local path = scratch()
    -- Every line is clipped to the payload budget, so filling a real 5 MB
    -- would take ~65k writes per rotation. The cap is asserted above; here it
    -- is lowered so two rotations are actually exercised. Restored whatever
    -- happens: a failure here must not leave the module capped at 4 KB for
    -- every spec that runs after this one.
    local real_cap = log.MAX_BYTES
    local finished, err = pcall(function()
      log.MAX_BYTES = 4096
      log.set_level('info', path)
      for index = 1, 400 do
        log.state_change('big', 'bulk', { n = index })
      end
      log.close()
      local size = vim.uv.fs_stat(path).size
      ok(vim.uv.fs_stat(path .. '.1') ~= nil, 'the rotated file must exist')
      eq(nil, vim.uv.fs_stat(path .. '.2'), 'only one rotated file is ever kept')
      ok(size < 4096, 'the live log stays under the cap, got ' .. size)
    end)
    log.MAX_BYTES = real_cap
    if not finished then
      error(err, 0)
    end
  end)
end)

describe('nvime.log viewer', function()
  it('clear truncates the file without removing it', function()
    local path = scratch()
    log.set_level('info', path)
    log.state_change('big', 'display', { to = 'merged' })
    log.clear()
    eq('', read(path) or '<missing>', 'clear leaves an empty file, not a missing one')
    log.state_change('big', 'display', { to = 'reviewing' })
    log.close()
    eq(1, #lines(path), 'the log keeps working after a clear')
  end)

  it('opens the log in a readonly scratch split parked at the tail', function()
    local path = scratch()
    log.set_level('info', path)
    for index = 1, 40 do
      log.state_change('big', 'bulk', { n = index })
    end
    log.open()
    local win = log.current().win
    ok(win ~= nil and vim.api.nvim_win_is_valid(win), 'the log opens a window')
    local buf = vim.api.nvim_win_get_buf(win)
    eq(false, vim.bo[buf].modifiable, 'the log view is nomodifiable')
    eq(true, vim.bo[buf].readonly, 'the log view is readonly')
    eq(vim.api.nvim_buf_line_count(buf), vim.api.nvim_win_get_cursor(win)[1], 'it follows the tail')
    log.close_view()
    eq(nil, log.current().win, 'q closes it')
    log.close()
  end)

  it('reports the level, path and size for the doctor row', function()
    local path = scratch()
    log.set_level('info', path)
    log.state_change('big', 'display', { to = 'merged' })
    log.close()
    local status = log.status()
    eq('info', status.level)
    eq(path, status.path)
    ok(status.size > 0, 'the size is the file on disk')
  end)
end)

describe('nvime.log session toggle', function()
  it('toggles between off and info without touching the configured path', function()
    local path = scratch()
    log.set_level('off', path)
    eq('info', log.toggle(), 'toggling an off log turns it on')
    eq('off', log.toggle(), 'toggling it again turns it back off')
    eq(path, log.status().path, 'the path survives the toggle')
    log.close()
  end)
end)

describe('nvime.log wiring at the rpc boundary', function()
  local rpc = require('nvime.rpc')

  --- A client with a stub process, so a request can be sent without a sidecar.
  local function client()
    local c = rpc.new({
      cmd = { 'node' },
      on_event = function() end,
      on_exit = function() end,
    })
    c.proc = {
      write = function() end,
    }
    return c
  end

  local function flush()
    vim.wait(200, function()
      return false
    end, 10)
  end

  it('records the request, the reply and its outcome', function()
    local path = scratch()
    log.set_level('info', path)
    local c = client()
    local id = c:request('big.merge', { root = '/repo' }, function() end)
    ok(id ~= nil, 'the request went out')
    c:_dispatch(vim.json.encode({ id = id, ok = true, result = {} }))
    flush()
    log.close()
    local written = lines(path)
    eq(2, #written, vim.inspect(written))
    ok(written[1]:find('big.merge', 1, true) ~= nil, written[1])
    ok(written[2]:find('big.merge', 1, true) ~= nil, 'the reply names the method its request had')
    ok(written[2]:find('ms', 1, true) ~= nil, written[2])
  end)

  it('records a server-pushed event', function()
    local path = scratch()
    log.set_level('debug', path)
    local c = client()
    c:_dispatch('{"event":"big.tool","params":{"tool":"Edit"}}')
    flush()
    log.close()
    local written = lines(path)
    eq(1, #written, vim.inspect(written))
    ok(written[1]:find('big.tool', 1, true) ~= nil, written[1])
  end)

  it('writes nothing at all when the log is off', function()
    local path = scratch()
    log.set_level('off', path)
    local c = client()
    local id = c:request('big.merge', { root = '/repo' }, function() end)
    c:_dispatch(vim.json.encode({ id = id, ok = true, result = {} }))
    c:_dispatch('{"event":"big.tool","params":{}}')
    flush()
    log.close()
    eq(nil, read(path), 'an off log costs nothing and creates no file')
  end)
end)

describe('doctor log row', function()
  local diagnostics = require('nvime.diagnostics')

  it('reports the level, path and size once the log is on', function()
    local path = scratch()
    log.set_level('info', path)
    log.state_change('big', 'display', { to = 'merged' })
    log.close()
    local entry = diagnostics.log_entry()
    eq('info', entry.level, 'the row is informational, never a failure')
    ok(entry.message:find('level info', 1, true) ~= nil, entry.message)
    ok(entry.message:find(path, 1, true) ~= nil, entry.message)
    ok(entry.message:find(' bytes', 1, true) ~= nil, entry.message)
  end)

  it('says how to turn the log on when it is off', function()
    log.set_level('off', scratch())
    local entry = diagnostics.log_entry()
    ok(entry.message:find('off', 1, true) ~= nil, entry.message)
    ok(entry.message:find(':Nvime debug on', 1, true) ~= nil, entry.message)
  end)
end)
