local t = require('harness')
local rpc = require('nvime.rpc')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

describe('rpc line framing', function()
  it('yields whole frames only', function()
    local splitter = rpc.new_splitter()
    local lines = splitter:push('{"id":1}\n{"event":"chat.delta"}\n')
    eq({ '{"id":1}', '{"event":"chat.delta"}' }, lines)
    eq(0, splitter:pending())
  end)

  it('holds a partial frame until its newline arrives', function()
    local splitter = rpc.new_splitter()
    eq({}, splitter:push('{"id":'))
    ok(splitter:pending() > 0)
    eq({ '{"id":1}' }, splitter:push('1}\n'))
    eq(0, splitter:pending())
  end)

  it('reassembles a frame delivered one byte at a time', function()
    local splitter = rpc.new_splitter()
    local frame = '{"id":7,"ok":true,"result":{"text":"hi"}}'
    local seen = {}
    for i = 1, #frame + 1 do
      local char = i > #frame and '\n' or frame:sub(i, i)
      vim.list_extend(seen, splitter:push(char))
    end
    eq({ frame }, seen)
  end)

  it('drops blank lines instead of emitting empty frames', function()
    eq({ '{"id":1}' }, rpc.new_splitter():push('\n\n  \n{"id":1}\n'))
  end)

  it('decodes a frame that carries an escaped newline', function()
    local splitter = rpc.new_splitter()
    local encoded = vim.json.encode({ event = 'chat.delta', params = { text = 'a\nb' } })
    local lines = splitter:push(encoded .. '\n')
    eq(1, #lines)
    eq({ event = 'chat.delta', params = { text = 'a\nb' } }, vim.json.decode(lines[1]))
  end)

  it('reports a run-on line as a desync and releases the buffer', function()
    local splitter = rpc.new_splitter()
    local lines, err = splitter:push(string.rep('x', 17 * 1024 * 1024))
    eq({}, lines)
    ok(err ~= nil, 'an overlong line must be reported')
    eq(0, splitter:pending())
  end)
end)

describe('rpc.new', function()
  it('demands a command and both callbacks', function()
    t.throws(function()
      rpc.new({ on_event = function() end, on_exit = function() end })
    end, 'non%-empty cmd')
    t.throws(function()
      rpc.new({ cmd = { 'node' }, on_exit = function() end })
    end, 'on_event')
    t.throws(function()
      rpc.new({ cmd = { 'node' }, on_event = function() end })
    end, 'on_exit')
  end)

  it('fails a request made before the process is up, rather than dropping it', function()
    local client = rpc.new({ cmd = { 'node' }, on_event = function() end, on_exit = function() end })
    local seen = nil
    local id = client:request('ping', nil, function(err)
      seen = err
    end)
    eq(nil, id)
    ok(seen ~= nil and seen.code == 'internal', 'the callback must fire with an error')
  end)
end)
