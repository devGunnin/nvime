--- The debug log you can attach to a bug report.
---
--- Off by default and free when off: nothing is formatted, nothing is opened,
--- no file is created. Turned on (config `debug.level`, or `:Nvime debug on`
--- for the session) it records one line per RPC request, reply and event, plus
--- the state transitions the surfaces go through, into one append-only file
--- that the sidecar mirrors its own detail into — so both halves of a stuck
--- run land in one timeline.
---
--- Nothing a user typed and nothing they own ever reaches it: content-bearing
--- fields are recorded as a size, secret-named fields as `<redacted>`, and
--- every payload is clipped. That redaction is a boundary, not a nicety — the
--- whole point of the file is that it can be pasted into a public issue.
local M = {}

--- What `debug.level` may be, weakest first.
M.LEVELS = { 'off', 'info', 'debug' }

local ORDER = { off = 0, info = 1, debug = 2 }

--- The live log is rotated past this, keeping exactly one `.1`. Not a local:
--- the tests lower it to exercise rotation without writing 5 MB.
M.MAX_BYTES = 5 * 1024 * 1024

--- How much of one payload a line may carry.
M.MAX_PAYLOAD_CHARS = 200

M.REDACTED = '<redacted>'

--- Fields that carry what the user wrote or what their files hold. Recorded as
--- a size, never as text — a log that quotes a prompt cannot be pasted into an
--- issue, which is the only reason this log exists.
local CONTENT_KEYS = {
  answers = true,
  comment = true,
  content = true,
  context = true,
  diff = true,
  message = true,
  prompt = true,
  rationale = true,
  spec = true,
  summary = true,
  text = true,
  title = true,
}

--- Substrings that make a field name secret wherever they appear in it.
local SECRET_PARTS = { 'token', 'secret', 'password', 'passwd', 'authorization', 'credential' }

--- How deep `redact` walks before it stops describing and starts eliding.
local MAX_DEPTH = 8

local state = {
  level = 'off',
  --- Where the log is written. Resolved on the first `set_level`, so a caller
  --- can name one (the tests do) instead of writing the user's real log.
  path = nil,
  handle = nil,
  bytes = 0,
  --- Set once the file could not be opened, so a broken log complains once
  --- rather than on every frame.
  failed = false,
}

--- `stdpath('log')`, or `stdpath('state')` on a Neovim that has no log dir.
--- @return string
function M.default_path()
  local ok_log, dir = pcall(vim.fn.stdpath, 'log')
  if not ok_log or type(dir) ~= 'string' or dir == '' then
    dir = vim.fn.stdpath('state')
  end
  return vim.fs.normalize(dir .. '/nvime.log')
end

--- @param name any
--- @return boolean true when a field with this name must never be written out
function M.is_secret_key(name)
  if type(name) ~= 'string' then
    return false
  end
  local lower = name:lower()
  for _, part in ipairs(SECRET_PARTS) do
    if lower:find(part, 1, true) ~= nil then
      return true
    end
  end
  -- `key` only as a whole word or a suffix: `keymaps` is not a secret.
  return lower == 'key' or lower == 'apikey' or lower:match('[_%-]key$') ~= nil or lower:match('api_?key$') ~= nil
end

--- A content-named field only carries content when it is text or a list of it.
--- `context` is a block list in an RPC payload and a settings table in the
--- config; summarising the settings table would gut the bundle it belongs in.
--- @param value any
--- @return boolean
local function is_content(value)
  return type(value) == 'string' or (type(value) == 'table' and vim.islist(value))
end

--- @param value any
--- @param depth integer|nil
--- @return any the same shape with secrets replaced and content summarised
function M.redact(value, depth)
  depth = depth or 0
  if type(value) ~= 'table' then
    return value
  end
  if depth >= MAX_DEPTH then
    return '<deep>'
  end
  local out = {}
  for key, nested in pairs(value) do
    if M.is_secret_key(key) then
      out[key] = M.REDACTED
    elseif CONTENT_KEYS[key] and is_content(nested) then
      out[key] = M.summarise(nested)
    else
      out[key] = M.redact(nested, depth + 1)
    end
  end
  return out
end

--- What a content-bearing field was, without any of what it said.
--- @return string
function M.summarise(value)
  if type(value) == 'string' then
    return string.format('<%d chars>', #value)
  end
  if type(value) == 'table' then
    return string.format('<%d items>', #value)
  end
  return string.format('<%s>', type(value))
end

--- @param text string
--- @return string `text` cut to the payload budget, with an explicit marker
function M.clip(text)
  if #text <= M.MAX_PAYLOAD_CHARS then
    return text
  end
  return text:sub(1, M.MAX_PAYLOAD_CHARS) .. '…(clipped)'
end

--- One payload as a single redacted, clipped line.
--- @param params table|nil
--- @return string
function M.render(params)
  if params == nil then
    return ''
  end
  local encoded_ok, encoded = pcall(vim.json.encode, M.redact(params))
  if not encoded_ok then
    encoded = '<unencodable payload>'
  end
  return M.clip(encoded)
end

local function rotate()
  if state.handle ~= nil then
    state.handle:close()
    state.handle = nil
  end
  os.remove(state.path .. '.1')
  os.rename(state.path, state.path .. '.1')
  state.bytes = 0
end

--- The append handle, opening it on first use. A log that cannot be opened is
--- reported once and turns itself off rather than failing every later frame:
--- diagnostics must never be the thing that breaks the editor.
--- @return file*|nil
local function handle()
  if state.handle ~= nil then
    return state.handle
  end
  if state.failed then
    return nil
  end
  local path = state.path or M.default_path()
  state.path = path
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local opened, err = io.open(path, 'a')
  if opened == nil then
    state.failed = true
    state.level = 'off'
    vim.notify(string.format('nvime: could not open the debug log %s (%s)', path, tostring(err)), vim.log.levels.WARN)
    return nil
  end
  state.handle = opened
  local stat = vim.uv.fs_stat(path)
  state.bytes = stat ~= nil and stat.size or 0
  return opened
end

--- @param level string the level this line needs to be written at
--- @param line string one formatted line, without its newline
local function emit(level, line)
  if ORDER[state.level] < ORDER[level] then
    return
  end
  local file = handle()
  if file == nil then
    return
  end
  local record = os.date('!%Y-%m-%dT%H:%M:%SZ') .. ' ' .. line .. '\n'
  if state.bytes + #record > M.MAX_BYTES then
    rotate()
    file = handle()
    if file == nil then
      return
    end
  end
  file:write(record)
  file:flush()
  state.bytes = state.bytes + #record
end

--- @param level string one of `M.LEVELS`
--- @param path string|nil where to write; defaults to `M.default_path()`
function M.set_level(level, path)
  if not vim.tbl_contains(M.LEVELS, level) then
    error('nvime: debug.level must be one of: ' .. table.concat(M.LEVELS, ', '), 0)
  end
  M.close()
  state.level = level
  state.failed = false
  if path ~= nil then
    assert(type(path) == 'string' and path ~= '', 'log.set_level needs a real path')
    state.path = path
  end
end

--- @return string the level in force right now
function M.level()
  return state.level
end

--- `:Nvime debug toggle`: off ↔ info, leaving `debug` for the config to name.
--- @return string the level now in force
function M.toggle()
  M.set_level(state.level == 'off' and 'info' or 'off')
  return state.level
end

--- @return string the path the log is written to, whether or not it exists
function M.path()
  return state.path or M.default_path()
end

--- Level, path and size — the `:Nvime doctor` row and the bundle's log header.
--- @return table { level, path, size }
function M.status()
  local stat = vim.uv.fs_stat(M.path())
  return { level = state.level, path = M.path(), size = stat ~= nil and stat.size or 0 }
end

--- Releases the file. The next write reopens it; nothing is lost.
function M.close()
  if state.handle ~= nil then
    state.handle:close()
    state.handle = nil
  end
  state.bytes = 0
end

--- Streaming deltas are the bulk of every run and say nothing about what went
--- wrong, so an `info` log keeps them out and a `debug` one takes them.
--- @param name string
--- @return string the level this event is written at
local function event_level(name)
  return name:find('%.delta$') ~= nil and 'debug' or 'info'
end

--- @param method string
--- @param id integer|nil
--- @param params table|nil
function M.request(method, id, params)
  emit('info', string.format('rpc > %s #%s %s', method, tostring(id), M.render(params)))
end

--- @param method string
--- @param id integer|nil
--- @param duration_ms integer
--- @param err table|nil the sidecar's error frame, or nil for a success
function M.reply(method, id, duration_ms, err)
  local outcome = err == nil and 'ok' or ('error ' .. tostring(err.code or 'internal'))
  emit('info', string.format('rpc < %s #%s %dms %s', method, tostring(id), duration_ms, outcome))
end

--- @param name string
--- @param params table|nil
function M.event(name, params)
  emit(event_level(name), string.format('evt   %s %s', name, M.render(params)))
end

--- One state transition in a surface: a display or phase change, an approval,
--- a steer, a merge precondition check.
--- @param surface string 'big' | 'edit' | 'chat' | 'review'
--- @param what string the transition, in the surface's own words
--- @param fields table|nil
function M.state_change(surface, what, fields)
  emit('info', string.format('state %s %s %s', surface, what, M.render(fields)))
end

--- The last `count` lines of the log, oldest first — what `:Nvime log` renders
--- and what the bundle attaches.
--- @param count integer
--- @return string[]
function M.tail(count)
  assert(type(count) == 'number' and count > 0, 'log.tail needs a positive count')
  local file = io.open(M.path(), 'r')
  if file == nil then
    return {}
  end
  -- Ring buffer rather than a full read: the file is capped at 5 MB and only
  -- its tail is ever wanted.
  local ring, total = {}, 0
  for line in file:lines() do
    total = total + 1
    ring[(total - 1) % count + 1] = line
  end
  file:close()
  local out = {}
  local first = total > count and total - count or 0
  for index = first + 1, total do
    out[#out + 1] = ring[(index - 1) % count + 1]
  end
  return out
end

--- `:Nvime log clear`: truncates the file, leaving it in place so the next
--- write does not have to recreate a directory tree.
function M.clear()
  M.close()
  local file = io.open(M.path(), 'w')
  if file == nil then
    vim.notify('nvime: could not clear ' .. M.path(), vim.log.levels.WARN)
    return
  end
  file:close()
end

local view = { win = nil, buf = nil }

local function close_view()
  if view.win ~= nil and vim.api.nvim_win_is_valid(view.win) then
    pcall(vim.api.nvim_win_close, view.win, true)
  end
  if view.buf ~= nil and vim.api.nvim_buf_is_valid(view.buf) then
    pcall(vim.api.nvim_buf_delete, view.buf, { force = true })
  end
  view.win, view.buf = nil, nil
end

--- How much of the log `:Nvime log` shows. The same window the bundle attaches.
M.VIEW_LINES = 200

--- `:Nvime log`: the tail in a readonly scratch split, parked at the bottom so
--- the newest line is the one under the cursor. `q` closes it.
function M.open()
  close_view()
  local lines = M.tail(M.VIEW_LINES)
  if #lines == 0 then
    lines = { string.format('(the log at %s is empty — :Nvime debug on starts recording)', M.path()) }
  end
  vim.cmd('botright new')
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'log'
  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true
  vim.api.nvim_buf_set_name(buf, 'nvime://log')
  vim.wo[win].number = false
  vim.wo[win].wrap = false
  vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
  require('nvime.modes').normal()
  view.win, view.buf = win, buf
  for _, lhs in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', lhs, close_view, { buffer = buf, nowait = true, silent = true, desc = 'nvime: close the log' })
  end
end

function M.close_view()
  close_view()
end

--- Test hook: the split on screen, or nils.
function M.current()
  return view
end

return M
