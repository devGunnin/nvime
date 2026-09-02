--- The debug log you can attach to a bug report.
---
--- Off by default and free when off: the level is the first thing every public
--- function here checks, before any string is built, so a streamed token pays
--- nothing at `off`. Turned on (config `debug.level`, or `:Nvime debug on` for
--- the session) it records one line per RPC request, reply and event, plus the
--- state transitions the surfaces go through, into an append-only file that
--- the sidecar mirrors its own detail into — so both halves of a stuck run
--- land in one timeline.
---
--- One file per process (`nvime-<pid>.log`): two editors sharing one file
--- rotate over each other's history, silently. `:Nvime log` and the bundle
--- merge every process's file back together by timestamp.
---
--- Every write happens on the RPC receive path, which is a FAST EVENT CONTEXT:
--- nothing below `emit` may call `vim.fn.*` or `vim.notify`. The handle is
--- opened in `set_level` and `clear` — both ordinary main-loop calls — and a
--- write that finds no handle drops its line and says so once, scheduled.
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

--- How many BYTES of one payload a line may carry. Bytes, not characters: the
--- cut is backed off to a character boundary but the budget is a byte budget.
M.MAX_PAYLOAD_CHARS = 200

M.REDACTED = '<redacted>'

--- Owner-only. The log carries project paths, session ids and RPC timings, and
--- the bundle built from it carries the git identity as well.
local OWNER_ONLY = 384

--- `2026-01-01T00:00:00.000Z` — the prefix every line starts with, and the key
--- the multi-process merge sorts on. Milliseconds are not decoration: the
--- sidecar writes `toISOString()` into the SAME file, and a narrower key made
--- `.` (0x2E) beat `Z` (0x5A), hoisting every agent line above every editor
--- line that shared a second.
local TIMESTAMP_BYTES = 24

--- Another process's log is pruned once it is this old AND its pid is gone.
local PRUNE_AFTER_SECONDS = 7 * 24 * 60 * 60

--- Fields that carry what the user wrote or what their files hold. Recorded
--- as a size, never as text — a log that quotes a prompt cannot be pasted into
--- an issue, which is the only reason this log exists.
---
--- A big change's `branch` is `nvime/big/<slug of its title>`, and its title
--- is the first 80 characters of what the user typed — so a branch name is the
--- reader's own words, and so is any slug built from one. The `spec` fields are
--- listed individually as well as under `spec`: they can arrive unwrapped.
---
--- `context` is deliberately NOT here. It is a block list in an RPC payload and
--- a settings table in the config the bundle renders; naming it meant one of
--- the two was always wrong. Its children answer for themselves instead.
local CONTENT_KEYS = {
  acceptance = true,
  answers = true,
  approach = true,
  branch = true,
  comment = true,
  content = true,
  diff = true,
  goal = true,
  message = true,
  outOfScope = true,
  prompt = true,
  rationale = true,
  scope = true,
  slug = true,
  spec = true,
  summary = true,
  text = true,
  title = true,
}

--- Substrings that make a field name secret wherever they appear in it.
--- `socket` is here because the runner's control socket plus its token are a
--- live channel into a running build; the bundle's session section already
--- refuses to print either.
local SECRET_PARTS = { 'token', 'secret', 'password', 'passwd', 'authorization', 'credential', 'socket' }

--- How deep `redact` walks before it stops describing and starts eliding.
local MAX_DEPTH = 8

local state = {
  level = 'off',
  --- Where this process writes. Resolved on `set_level`, so a caller can name
  --- one (the tests do) instead of writing the user's real log.
  path = nil,
  handle = nil,
  bytes = 0,
  --- The path the log gave up on, and why, or nil. Keeps "the user asked for
  --- off" apart from "the log could not be written", which the doctor must not
  --- blur — including when the failure happens mid-session.
  broken = nil,
  broken_reason = nil,
  --- Set once a write path gave up, so it complains once and then stays quiet.
  said = false,
}

--- `stdpath('log')`, or `stdpath('state')` on a Neovim that has no log dir.
--- @return string this process's own log file
function M.default_path()
  local ok_log, dir = pcall(vim.fn.stdpath, 'log')
  if not ok_log or type(dir) ~= 'string' or dir == '' then
    dir = vim.fn.stdpath('state')
  end
  return vim.fs.normalize(string.format('%s/nvime-%d.log', dir, vim.uv.os_getpid()))
end

--- @return string the path this process writes to, whether or not it exists
function M.path()
  return state.path or M.default_path()
end

--- @param level string
--- @return boolean whether a line at `level` would be written right now
function M.enabled(level)
  return ORDER[state.level] >= ORDER[level]
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
    elseif CONTENT_KEYS[key] then
      -- A CONTENT KEY NEVER RECURSES, whatever it holds. `spec` was named here
      -- and still leaked, because walking into the object put its `goal` and
      -- `approach` — the reader's own words — one field beyond the rule.
      out[key] = M.summarise(nested)
    else
      out[key] = M.redact(nested, depth + 1)
    end
  end
  return out
end

--- What a content-bearing field was, without any of what it said. An object is
--- described by its shape — the count alone would not say a spec was there.
--- @return string
function M.summarise(value)
  if type(value) == 'string' then
    return string.format('<%d chars>', #value)
  end
  if type(value) ~= 'table' then
    return string.format('<%s>', type(value))
  end
  if vim.islist(value) then
    return string.format('<%d items>', #value)
  end
  local keys = 0
  for _ in pairs(value) do
    keys = keys + 1
  end
  local encoded_ok, encoded = pcall(vim.json.encode, value)
  return string.format('<%d keys, %d bytes>', keys, encoded_ok and #encoded or 0)
end

--- @param text string
--- @return string `text` cut to the byte budget, backed off to a character
--- boundary so a multi-byte character is never written out in halves
function M.clip(text)
  if #text <= M.MAX_PAYLOAD_CHARS then
    return text
  end
  local cut = M.MAX_PAYLOAD_CHARS
  -- UTF-8 continuation bytes are 10xxxxxx; walk back off them to the lead.
  while cut > 0 do
    local next_byte = text:byte(cut + 1)
    if next_byte == nil or next_byte < 0x80 or next_byte >= 0xC0 then
      break
    end
    cut = cut - 1
  end
  return text:sub(1, cut) .. '…(clipped)'
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

--- Stops writing and says why, once. Reachable from the RPC receive path, so
--- the notice is scheduled — `vim.notify` is refused in a fast event context,
--- and a diagnostic must never be the thing that breaks the editor.
--- @param reason string
local function give_up(reason)
  state.level = 'off'
  state.broken, state.broken_reason = M.path(), reason
  if state.handle ~= nil then
    state.handle:close()
    state.handle = nil
  end
  if state.said then
    return
  end
  state.said = true
  vim.schedule(function()
    -- The sidecar is still appending to a file this half has abandoned; half a
    -- timeline is worse than none, and `set_debug_level` is main-loop only.
    require('nvime.agent').set_debug_level('off')
    vim.notify('nvime: the debug log stopped — ' .. reason, vim.log.levels.WARN)
  end)
end

--- Opens the append handle at `path`. MAIN LOOP ONLY: `vim.fn.mkdir` is
--- refused in a fast event context, which is where every write comes from.
--- @param path string
--- @return boolean opened
--- @return string|nil error
local function open_handle(path)
  pcall(vim.fn.mkdir, vim.fs.dirname(path), 'p')
  local opened, err = io.open(path, 'a')
  if opened == nil then
    return false, tostring(err)
  end
  -- Before the first line, and again on a file an older nvime left at 0644.
  vim.uv.fs_chmod(path, OWNER_ONLY)
  state.handle = opened
  local stat = vim.uv.fs_stat(path)
  state.bytes = stat ~= nil and stat.size or 0
  return true, nil
end

--- @param pid integer
--- @return boolean whether this user still has an nvime running under that id.
--- EPERM (a live process now owned by somebody else) counts as gone, which is
--- the answer this wants: a recycled pid is not the nvime that wrote the log.
local function pid_alive(pid)
  local signalled, result = pcall(vim.uv.kill, pid, 0)
  return signalled and result ~= nil
end

--- Removes a log left behind by an editor that is gone and has been for a
--- week. Never this process's own file, and never a live editor's.
local function prune_stale()
  local dir = vim.fs.dirname(M.path())
  local mine = vim.fs.basename(M.path())
  local cutoff = os.time() - PRUNE_AFTER_SECONDS
  local listed, iter = pcall(vim.fs.dir, dir)
  if not listed then
    return
  end
  for name in iter do
    local pid = name:match('^nvime%-(%d+)%.log$') or name:match('^nvime%-(%d+)%.log%.1$')
    if pid ~= nil and name ~= mine and name ~= mine .. '.1' and not pid_alive(tonumber(pid)) then
      local path = dir .. '/' .. name
      local stat = vim.uv.fs_stat(path)
      if stat ~= nil and stat.mtime.sec < cutoff then
        os.remove(path)
      end
    end
  end
end

--- Renames the live log aside, keeping exactly one `.1`, and reopens.
--- @return boolean rotated — false means writing has stopped and said so
local function rotate()
  local path = M.path()
  if state.handle ~= nil then
    state.handle:close()
    state.handle = nil
  end
  os.remove(path .. '.1')
  local renamed, rename_err = os.rename(path, path .. '.1')
  if not renamed then
    give_up(string.format('could not rotate %s (%s)', path, tostring(rename_err)))
    return false
  end
  local opened, open_err = io.open(path, 'a')
  if opened == nil then
    give_up(string.format('could not reopen %s after rotating (%s)', path, tostring(open_err)))
    return false
  end
  vim.uv.fs_chmod(path, OWNER_ONLY)
  state.handle = opened
  state.bytes = 0
  return true
end

--- The instant, in the sidecar's exact format. `vim.uv.gettimeofday` and
--- `os.date` are both safe in a fast event context; `vim.fn.strftime` is not.
--- @return string 24 bytes, `2026-01-01T00:00:00.000Z`
local function stamp()
  local seconds, micros = vim.uv.gettimeofday()
  return string.format('%s.%03dZ', os.date('!%Y-%m-%dT%H:%M:%S', seconds), math.floor((micros or 0) / 1000))
end

--- Writes one already-formatted line. The LEVEL IS NOT CHECKED HERE — every
--- caller checks it before building the line, which is what makes `off` free.
--- @param line string one formatted line, without its newline
local function emit(line)
  if state.handle == nil then
    give_up('its file is not open')
    return
  end
  local record = stamp() .. ' ' .. line .. '\n'
  if state.bytes + #record > M.MAX_BYTES and not rotate() then
    return
  end
  local file = state.handle
  if file == nil then
    return
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
  state.broken, state.broken_reason, state.said = nil, nil, false
  if path ~= nil then
    assert(type(path) == 'string' and path ~= '', 'log.set_level needs a real path')
    state.path = path
  end
  state.level = level
  if level == 'off' then
    return
  end
  prune_stale()
  local opened, err = open_handle(M.path())
  if opened then
    return
  end
  -- Turning the log on is a main-loop action, so this one is said directly.
  state.level, state.broken = 'off', M.path()
  state.broken_reason = 'the file could not be opened (' .. tostring(err) .. ')'
  vim.notify(string.format('nvime: could not open the debug log %s (%s)', M.path(), err), vim.log.levels.WARN)
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

--- Level, path and size, plus the path an open failed on — the `:Nvime doctor`
--- row and the bundle's log header.
--- @return table { level, path, size, broken }
function M.status()
  local stat = vim.uv.fs_stat(M.path())
  return {
    level = state.level,
    path = M.path(),
    size = stat ~= nil and stat.size or 0,
    broken = state.broken,
    broken_reason = state.broken_reason,
  }
end

--- Releases the file. Nothing reopens it from the write path — that runs in a
--- fast event context — so writes are dropped until `set_level` or `clear`.
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
  if not M.enabled('info') then
    return
  end
  emit(string.format('rpc > %s #%s %s', method, tostring(id), M.render(params)))
end

--- @param method string
--- @param id integer|nil
--- @param duration_ms integer
--- @param err table|nil the sidecar's error frame, or nil for a success
function M.reply(method, id, duration_ms, err)
  if not M.enabled('info') then
    return
  end
  local outcome = err == nil and 'ok' or ('error ' .. tostring(err.code or 'internal'))
  emit(string.format('rpc < %s #%s %dms %s', method, tostring(id), duration_ms, outcome))
end

--- @param name string
--- @param params table|nil
function M.event(name, params)
  -- Cheapest check first: at `off` the event's own name is not even inspected.
  if state.level == 'off' or not M.enabled(event_level(name)) then
    return
  end
  emit(string.format('evt   %s %s', name, M.render(params)))
end

--- One state transition in a surface: a display or phase change, an approval,
--- a steer, a merge precondition check.
--- @param surface string 'big' | 'edit' | 'chat' | 'review'
--- @param what string the transition, in the surface's own words
--- @param fields table|nil
function M.state_change(surface, what, fields)
  if not M.enabled('info') then
    return
  end
  emit(string.format('state %s %s %s', surface, what, M.render(fields)))
end

--- Every nvime log file worth reading, rotated halves before live ones so that
--- lines sharing a timestamp still come out in the order they were written.
--- @return string[]
function M.files()
  local path = M.path()
  local dir = vim.fs.dirname(path)
  local seen, out = {}, {}
  --- Dedup by inode, not by name: another editor rotating between the scan and
  --- the read makes one file readable as both `nvime-X.log` and `.log.1`.
  local function add(candidate)
    local stat = vim.uv.fs_stat(candidate)
    if stat == nil then
      return
    end
    local identity = string.format('%s:%s', tostring(stat.dev), tostring(stat.ino))
    if seen[identity] then
      return
    end
    seen[identity] = true
    out[#out + 1] = candidate
  end
  local names = {}
  local listed, iter = pcall(vim.fs.dir, dir)
  if listed then
    for name in iter do
      if name:match('^nvime%-%d+%.log$') ~= nil or name:match('^nvime%-%d+%.log%.1$') ~= nil then
        names[#names + 1] = name
      end
    end
  end
  table.sort(names)
  add(path .. '.1')
  for _, name in ipairs(names) do
    if name:match('%.1$') ~= nil then
      add(dir .. '/' .. name)
    end
  end
  add(path)
  for _, name in ipairs(names) do
    if name:match('%.1$') == nil then
      add(dir .. '/' .. name)
    end
  end
  return out
end

--- The last `count` lines across every process's log, oldest first — what
--- `:Nvime log` renders and what the bundle attaches. Merged on the timestamp
--- each line starts with: one editor's file is only half the story when two
--- are running, and the rotated `.1` holds the rest of this one's.
--- @param count integer
--- @return string[]
function M.tail(count)
  assert(type(count) == 'number' and count > 0, 'log.tail needs a positive count')
  local entries = {}
  for rank, path in ipairs(M.files()) do
    local file = io.open(path, 'r')
    if file ~= nil then
      local index = 0
      for line in file:lines() do
        index = index + 1
        entries[#entries + 1] = { at = line:sub(1, TIMESTAMP_BYTES), rank = rank, index = index, line = line }
      end
      file:close()
    end
  end
  -- Not a stable sort, so the comparison is made total: same timestamp falls
  -- back to the file, then to the position within it.
  table.sort(entries, function(a, b)
    if a.at ~= b.at then
      return a.at < b.at
    end
    if a.rank ~= b.rank then
      return a.rank < b.rank
    end
    return a.index < b.index
  end)
  local out = {}
  for index = math.max(#entries - count + 1, 1), #entries do
    out[#out + 1] = entries[index].line
  end
  return out
end

local view = { win = nil, buf = nil }

--- How much of the log `:Nvime log` shows. The same window the bundle attaches.
M.VIEW_LINES = 200

--- Fills the open split with the log as it stands now. No-op when none is up.
local function render_view()
  if view.buf == nil or not vim.api.nvim_buf_is_valid(view.buf) then
    return
  end
  local lines = M.tail(M.VIEW_LINES)
  if #lines == 0 then
    lines = { string.format('(the log at %s is empty — :Nvime debug on starts recording)', M.path()) }
  end
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  vim.bo[view.buf].readonly = true
  if view.win ~= nil and vim.api.nvim_win_is_valid(view.win) then
    vim.api.nvim_win_set_cursor(view.win, { vim.api.nvim_buf_line_count(view.buf), 0 })
  end
end

--- `:Nvime log clear`: empties THIS process's file — never another editor's —
--- and reopens the handle before returning, so the next inbound frame has
--- somewhere to write without touching the filesystem itself.
function M.clear()
  M.close()
  local path = M.path()
  local file = io.open(path, 'w')
  if file == nil then
    vim.notify('nvime: could not clear ' .. path, vim.log.levels.WARN)
    return
  end
  file:close()
  vim.uv.fs_chmod(path, OWNER_ONLY)
  if state.level ~= 'off' then
    local opened, err = open_handle(path)
    if not opened then
      state.level, state.broken = 'off', path
      state.broken_reason = 'the file could not be opened (' .. tostring(err) .. ')'
      vim.notify(string.format('nvime: could not reopen %s (%s)', path, err), vim.log.levels.WARN)
    end
  end
  render_view()
end

local function close_view()
  if view.win ~= nil and vim.api.nvim_win_is_valid(view.win) then
    pcall(vim.api.nvim_win_close, view.win, true)
  end
  if view.buf ~= nil and vim.api.nvim_buf_is_valid(view.buf) then
    pcall(vim.api.nvim_buf_delete, view.buf, { force = true })
  end
  view.win, view.buf = nil, nil
end

--- `:Nvime log`: the tail in a readonly scratch split, parked at the bottom so
--- the newest line is the one under the cursor. `q` closes it.
function M.open()
  close_view()
  vim.cmd('botright new')
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'log'
  vim.api.nvim_buf_set_name(buf, 'nvime://log')
  vim.wo[win].number = false
  vim.wo[win].wrap = false
  view.win, view.buf = win, buf
  render_view()
  require('nvime.modes').normal()
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
