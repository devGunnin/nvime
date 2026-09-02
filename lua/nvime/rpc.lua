--- Newline-delimited JSON client for the nvime sidecar.
---
--- Every process interaction is callback-driven (`vim.system`), so nothing here
--- ever blocks the editor. Frames arrive in a fast event context; the decode is
--- pure Lua and the user callbacks are handed to `vim.schedule`.
---
--- This is also where the debug log sees the wire: every request, reply and
--- event passes through here exactly once, and only here are the method a
--- reply answers and how long it took both still known.
local log = require('nvime.log')

local M = {}

--- A run-on line means the peer desynchronized, not that it is chatty.
local MAX_LINE_BYTES = 16 * 1024 * 1024
local MAX_STDERR_LINES = 50

--- Reassembles whole lines out of arbitrarily chunked output.
local Splitter = {}
Splitter.__index = Splitter

function M.new_splitter()
  return setmetatable({ buffer = '' }, Splitter)
end

--- @param chunk string
--- @return string[] complete lines
--- @return string|nil error when the buffer grew past the line limit
function Splitter:push(chunk)
  self.buffer = self.buffer .. chunk
  local lines = {}
  -- Scan with an index and slice once: re-slicing per frame is O(n^2) on a
  -- chunk carrying many streamed deltas, and this runs in a fast event context.
  local start = 1
  while true do
    local nl = self.buffer:find('\n', start, true)
    if nl == nil then
      break
    end
    local line = vim.trim(self.buffer:sub(start, nl - 1))
    start = nl + 1
    if line ~= '' then
      lines[#lines + 1] = line
    end
  end
  self.buffer = self.buffer:sub(start)
  if #self.buffer > MAX_LINE_BYTES then
    self.buffer = ''
    return lines, 'sidecar output exceeded the line limit without a newline'
  end
  return lines, nil
end

--- @return integer bytes held back waiting for a newline
function Splitter:pending()
  return #self.buffer
end

local Client = {}
Client.__index = Client

--- Request ids are unique per Neovim session, not per client: a respawned
--- sidecar restarting at 1 would collide with an id a caller is still tracking.
local next_id = 0

--- @param opts table cmd (string[]), cwd, env, on_event(name, params), on_exit(code, stderr)
function M.new(opts)
  assert(type(opts.cmd) == 'table' and #opts.cmd > 0, 'rpc.new needs a non-empty cmd')
  assert(type(opts.on_event) == 'function', 'rpc.new needs an on_event callback')
  assert(type(opts.on_exit) == 'function', 'rpc.new needs an on_exit callback')
  return setmetatable({
    cmd = opts.cmd,
    cwd = opts.cwd,
    env = opts.env,
    on_event = opts.on_event,
    on_exit = opts.on_exit,
    pending = {},
    --- What each in-flight id asked and when, so a reply can be logged with
    --- the method it answers and its round-trip time. Cleared with `pending`.
    sent = {},
    stderr = {},
    splitter = M.new_splitter(),
    proc = nil,
  }, Client)
end

function Client:is_running()
  return self.proc ~= nil
end

--- @return boolean ok
--- @return string|nil error
function Client:start()
  if self.proc ~= nil then
    return true, nil
  end
  local ok, proc = pcall(vim.system, self.cmd, {
    cwd = self.cwd,
    env = self.env,
    stdin = true,
    stdout = function(err, data)
      self:_on_stdout(err, data)
    end,
    stderr = function(err, data)
      self:_on_stderr(err, data)
    end,
    text = true,
  }, function(result)
    self:_on_exit(result)
  end)
  if not ok then
    return false, tostring(proc)
  end
  self.proc = proc
  return true, nil
end

--- Sends a request; `cb(err, result)` is always called exactly once — on the
--- reply, when the sidecar dies in flight, or when the deadline passes.
--- @param method string
--- @param params table|nil
--- @param cb fun(err: table|nil, result: any)
--- @param timeout_ms integer|nil deadline; nil for a streaming turn, which has none
--- @return integer|nil request id, usable with `chat.cancel`
function Client:request(method, params, cb, timeout_ms)
  assert(type(method) == 'string' and method ~= '', 'rpc.request needs a method name')
  assert(type(cb) == 'function', 'rpc.request needs a callback')
  assert(
    timeout_ms == nil or (type(timeout_ms) == 'number' and timeout_ms > 0),
    'rpc.request needs a positive timeout or none'
  )
  if self.proc == nil then
    cb({ code = 'internal', message = 'the nvime sidecar is not running' }, nil)
    return nil
  end
  next_id = next_id + 1
  local id = next_id

  local timer = nil
  -- The reply and the deadline both race to answer `id`. `self.pending[id]`
  -- is the single source of truth for who won: whichever of `_dispatch` and
  -- the timer's own callback clears it first is the one that gets to settle,
  -- decided synchronously at that point rather than inside the vim.schedule
  -- each defers to — otherwise a reply that arrives in the same tick the
  -- deadline fires can still lose to a timeout it already beat.
  self.pending[id] = function(err, result)
    if timer ~= nil then
      timer:stop()
      timer:close()
      timer = nil
    end
    cb(err, result)
  end

  if timeout_ms ~= nil then
    timer = vim.uv.new_timer()
    timer:start(timeout_ms, 0, function()
      local settle = self:_claim(id)
      if settle == nil then
        return
      end
      vim.schedule(function()
        settle({
          code = 'internal',
          message = string.format('the sidecar did not answer %s within %dms', method, timeout_ms),
        }, nil)
      end)
    end)
  end

  self.sent[id] = { method = method, at = vim.uv.now() }
  log.request(method, id, params)

  local line = vim.json.encode({ id = id, method = method, params = params or vim.empty_dict() })
  local written, err = pcall(function()
    self.proc:write(line .. '\n')
  end)
  if not written then
    local settle = self:_claim(id)
    if settle ~= nil then
      settle({ code = 'internal', message = 'could not write to the sidecar', detail = tostring(err) }, nil)
    end
    return nil
  end
  return id
end

--- Removes and returns the pending callback for `id`, or nil if something
--- else (a reply, a write failure, `_fail_all`) already claimed it.
---
--- The returned callback logs the outcome first, so every way a request can
--- settle — a reply, a deadline, a failed write — leaves one line, and none of
--- them has to remember to log for itself.
function Client:_claim(id)
  local settle = self.pending[id]
  if settle == nil then
    return nil
  end
  self.pending[id] = nil
  local sent = self.sent[id]
  self.sent[id] = nil
  return function(err, result)
    if sent ~= nil then
      log.reply(sent.method, id, vim.uv.now() - sent.at, err)
    end
    settle(err, result)
  end
end

function Client:stop()
  local proc = self.proc
  if proc == nil then
    return
  end
  -- Ask first; the sidecar exits on its own when stdin closes.
  self:request('shutdown', nil, function() end)
  pcall(function()
    proc:write(nil)
  end)
  vim.defer_fn(function()
    if self.proc == proc then
      pcall(function()
        proc:kill('sigterm')
      end)
    end
  end, 1000)
end

function Client:_on_stdout(err, data)
  if err ~= nil then
    self:_fail_all({ code = 'internal', message = 'sidecar stdout error', detail = tostring(err) })
    return
  end
  if data == nil then
    return
  end
  local lines, overflow = self.splitter:push(data)
  for _, line in ipairs(lines) do
    self:_dispatch(line)
  end
  if overflow ~= nil then
    self:_fail_all({ code = 'internal', message = overflow })
  end
end

--- `luanil` matters: without it a JSON `null` decodes to `vim.NIL`, a userdata
--- that is truthy in Lua and blows up the first time a caller indexes it.
local DECODE_OPTS = { luanil = { object = true, array = true } }

function Client:_dispatch(line)
  local ok, frame = pcall(vim.json.decode, line, DECODE_OPTS)
  if not ok or type(frame) ~= 'table' then
    self:_fail_all({ code = 'internal', message = 'undecodable frame from the sidecar', detail = line })
    return
  end
  if frame.event ~= nil then
    local name, params = frame.event, frame.params or {}
    log.event(name, params)
    vim.schedule(function()
      self.on_event(name, params)
    end)
    return
  end
  local cb = self:_claim(frame.id)
  if cb == nil then
    return
  end
  -- Not `cond and nil or fallback`: in Lua that always yields the fallback.
  local err = nil
  if frame.ok ~= true then
    err = frame.error or { code = 'internal', message = 'the sidecar reported an unnamed failure' }
  end
  local result = frame.result
  vim.schedule(function()
    cb(err, result)
  end)
end

function Client:_on_stderr(_, data)
  if data == nil or data == '' then
    return
  end
  for _, line in ipairs(vim.split(data, '\n', { plain = true, trimempty = true })) do
    self.stderr[#self.stderr + 1] = line
    if #self.stderr > MAX_STDERR_LINES then
      table.remove(self.stderr, 1)
    end
  end
end

function Client:_on_exit(result)
  self.proc = nil
  local code = result and result.code or -1
  local tail = table.concat(self.stderr, '\n')
  self:_fail_all({
    code = 'internal',
    message = string.format('the nvime sidecar exited (code %d)', code),
    detail = tail ~= '' and tail or nil,
  })
  vim.schedule(function()
    self.on_exit(code, tail)
  end)
end

--- No request is ever left hanging: a dead sidecar fails everything in flight.
function Client:_fail_all(err)
  local pending, sent = self.pending, self.sent
  self.pending, self.sent = {}, {}
  for id, cb in pairs(pending) do
    local record = sent[id]
    if record ~= nil then
      log.reply(record.method, id, vim.uv.now() - record.at, err)
    end
    vim.schedule(function()
      cb(err, nil)
    end)
  end
end

M.Client = Client

return M
