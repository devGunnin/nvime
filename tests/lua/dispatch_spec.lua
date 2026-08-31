local t = require('harness')
local rpc = require('nvime.rpc')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Frames are dispatched into `vim.schedule`; pump the loop to observe them.
local function flush()
  vim.wait(200, function()
    return false
  end, 10)
end

local function client()
  local events = {}
  local exits = {}
  local c = rpc.new({
    cmd = { 'node' },
    on_event = function(name, params)
      events[#events + 1] = { name = name, params = params }
    end,
    on_exit = function(code)
      exits[#exits + 1] = code
    end,
  })
  return c, events, exits
end

--- Registers a pending callback without needing a live process.
local function expect_reply(c, id)
  local seen = {}
  c.pending[id] = function(err, result)
    seen.err, seen.result, seen.called = err, result, true
  end
  return seen
end

describe('rpc frame dispatch', function()
  it('delivers a successful response as a result, not an error', function()
    local c = client()
    local seen = expect_reply(c, 1)
    c:_dispatch('{"id":1,"ok":true,"result":{"sessionId":"abc"}}')
    flush()
    ok(seen.called, 'the callback must fire')
    eq(nil, seen.err)
    eq({ sessionId = 'abc' }, seen.result)
  end)

  it('delivers a failed response as the sidecar wrote it', function()
    local c = client()
    local seen = expect_reply(c, 2)
    c:_dispatch('{"id":2,"ok":false,"error":{"code":"not_logged_in","message":"sign in"}}')
    flush()
    eq({ code = 'not_logged_in', message = 'sign in' }, seen.err)
    eq(nil, seen.result)
  end)

  it('names an ok:false frame that carries no error object', function()
    local c = client()
    local seen = expect_reply(c, 3)
    c:_dispatch('{"id":3,"ok":false}')
    flush()
    ok(seen.err ~= nil and seen.err.code == 'internal')
  end)

  it('decodes a JSON null to Lua nil, not to vim.NIL', function()
    local c = client()
    local seen = expect_reply(c, 8)
    c:_dispatch('{"id":8,"ok":true,"result":{"current":null,"sessions":[]}}')
    flush()
    eq(nil, seen.result.current)
    ok(seen.result.current ~= vim.NIL, 'vim.NIL is truthy and breaks every caller')
  end)

  it('routes an event frame to the event callback, not to a request', function()
    local c, events = client()
    local seen = expect_reply(c, 4)
    c:_dispatch('{"event":"chat.delta","params":{"id":4,"text":"hi"}}')
    flush()
    eq(1, #events)
    eq('chat.delta', events[1].name)
    eq('hi', events[1].params.text)
    ok(not seen.called, 'an event must not settle a pending request')
  end)

  it('answers each request exactly once', function()
    local c = client()
    local calls = 0
    c.pending[5] = function()
      calls = calls + 1
    end
    c:_dispatch('{"id":5,"ok":true,"result":1}')
    c:_dispatch('{"id":5,"ok":true,"result":1}')
    flush()
    eq(1, calls)
  end)

  it('fails every pending request when a frame cannot be decoded', function()
    local c = client()
    local a = expect_reply(c, 6)
    local b = expect_reply(c, 7)
    c:_dispatch('not json at all')
    flush()
    ok(a.err ~= nil and b.err ~= nil, 'no request may be left hanging')
  end)
end)
