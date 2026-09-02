--- `:Nvime bundle` — one markdown file you can attach to a bug report.
---
--- Issue #10 ("stuck, never allowing me to merge") had nothing attachable: no
--- log, no way to say what nvime was doing. This gathers all of it — versions,
--- the machine, the config, the doctor's findings, the tail of the debug log,
--- and the big change's own state and last events — into one file whose path
--- lands in the registers, ready to paste.
---
--- Redaction is a boundary, not a nicety: everything user-supplied goes
--- through `nvime.log`'s redactor on the way in, so a token-shaped setting
--- cannot reach a file whose whole purpose is to be posted in public.
local diagnostics = require('nvime.diagnostics')
local log = require('nvime.log')

local M = {}

--- Log lines the bundle attaches.
M.LOG_LINES = 200

--- Run-log events the bundle attaches, newest last.
M.RUNLOG_EVENTS = 50

--- @param lines string[] accumulator
--- @param label string
--- @param body string[]
local function section(lines, label, body)
  lines[#lines + 1] = '## ' .. label
  lines[#lines + 1] = ''
  for _, line in ipairs(body) do
    lines[#lines + 1] = line
  end
  lines[#lines + 1] = ''
end

--- @param body string[]
--- @return string[] the same lines inside a fenced block
local function fenced(body, language)
  local out = { '```' .. (language or '') }
  for _, line in ipairs(body) do
    out[#out + 1] = line
  end
  out[#out + 1] = '```'
  return out
end

--- @param entries table[] doctor entries
--- @return string[]
local function doctor_lines(entries)
  local out = {}
  for _, entry in ipairs(entries) do
    out[#out + 1] = string.format('- [%s] %s', entry.level, entry.message)
    if entry.advice ~= nil and entry.advice ~= '' then
      out[#out + 1] = '      fix: ' .. entry.advice
    end
  end
  if #out == 0 then
    out[1] = '- (no checks ran)'
  end
  return out
end

--- The big change's view, with only the fields a bug report needs — never its
--- spec, its threads or anything else the reader wrote.
--- @param session table|nil
--- @return string[]
local function session_lines(session)
  if session == nil then
    return { 'no big change is selected in this editor.' }
  end
  local out = {}
  for _, field in ipairs({ 'id', 'title', 'state', 'display', 'runner', 'steerable' }) do
    out[#out + 1] = string.format('- %s: %s', field, vim.inspect(session[field]))
  end
  local base, head = session.base or {}, session.head or {}
  out[#out + 1] = string.format('- base sha: %s (%s)', tostring(base.commit or session.baseSha), tostring(base.branch))
  out[#out + 1] = string.format('- head sha: %s', tostring(head.commit or session.headSha))
  return out
end

--- @param events table[]|nil run-log events, oldest first
--- @return string[]
local function runlog_lines(events)
  if events == nil or #events == 0 then
    return { '(no build events recorded for this big change)' }
  end
  local out = {}
  for _, event in ipairs(events) do
    out[#out + 1] = string.format('%6s  %-16s %s', tostring(event.seq), event.event, log.render(event.params))
  end
  return out
end

--- The whole bundle, as lines. Pure: everything it needs is in `parts`, so the
--- rendering — and the redaction it applies — is testable without a sidecar,
--- a repository or a machine to probe.
--- @param parts table environment, config, doctor, log, session, runlog
--- @return string[]
function M.render(parts)
  assert(type(parts) == 'table', 'bundle.render needs the gathered parts')
  assert(type(parts.log) == 'table', 'bundle.render needs the log status')
  local lines = { '# nvime diagnostics bundle', '', 'generated ' .. os.date('!%Y-%m-%dT%H:%M:%SZ'), '' }

  local environment = {}
  for _, row in ipairs(parts.environment or {}) do
    environment[#environment + 1] = string.format('- %s: %s', row.label, row.value)
  end
  section(lines, 'environment', environment)

  section(lines, 'configuration', fenced(vim.split(vim.inspect(log.redact(parts.config or {})), '\n'), 'lua'))
  section(lines, 'doctor', doctor_lines(parts.doctor or {}))

  local status = parts.log
  section(lines, 'debug log', {
    string.format('- level: %s', status.level),
    string.format('- path: %s', status.path),
    string.format('- size: %d bytes', status.size),
  })
  section(lines, string.format('debug log — last %d lines', M.LOG_LINES), fenced(status.tail or {}))

  section(lines, 'big change', session_lines(parts.session))
  section(
    lines,
    string.format('big change — last %d run-log events', M.RUNLOG_EVENTS),
    fenced(runlog_lines(parts.runlog))
  )
  return lines
end

--- @param now integer|nil unix seconds; defaults to the clock
--- @return string where a bundle written now would land
function M.path(now)
  local stamp = os.date('!%Y%m%dT%H%M%SZ', now or os.time())
  return vim.fs.normalize(vim.fn.stdpath('cache') .. '/nvime-bundle-' .. stamp .. '.md')
end

--- @param path string
--- @param parts table
--- @return string path
function M.write_to(path, parts)
  assert(type(path) == 'string' and path ~= '', 'bundle.write_to needs a path')
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local file, err = io.open(path, 'w')
  if file == nil then
    error(string.format('nvime: could not write the bundle to %s (%s)', path, tostring(err)), 0)
  end
  file:write(table.concat(M.render(parts), '\n') .. '\n')
  file:close()
  return path
end

--- Hands the path to the user the two ways they can use it: the clipboard, and
--- a message they can read. `+` is best-effort — a headless or provider-less
--- Neovim has no system clipboard, and that must not fail the bundle.
--- @param path string
function M.deliver(path)
  vim.fn.setreg('"', path)
  pcall(vim.fn.setreg, '+', path)
  vim.notify('nvime: diagnostics bundle written to ' .. path)
end

--- What can be read without asking the sidecar anything.
--- @return table parts, missing only `runlog`
local function gather_local()
  local config = require('nvime.config').get()
  local uname = vim.uv.os_uname()
  local root = require('nvime.agent').plugin_root()
  local sha = diagnostics.probe({ 'git', '-C', root, 'rev-parse', '--short', 'HEAD' }) or 'unknown'
  local node = diagnostics.probe({ config.agent.node, '--version' }) or 'not found'
  local claude = diagnostics.probe({ config.agent.claude or 'claude', '--version' }) or 'not found'
  local status = log.status()
  status.tail = log.tail(M.LOG_LINES)
  return {
    environment = {
      { label = 'nvime', value = string.format('%s (%s)', require('nvime.version'), sha) },
      { label = 'neovim', value = tostring(vim.version()) },
      { label = 'os', value = string.format('%s %s %s', uname.sysname, uname.release, uname.machine) },
      { label = 'node', value = node },
      { label = 'claude', value = claude },
    },
    config = config,
    doctor = diagnostics.run(),
    log = status,
  }
end

--- Writes the bundle and hands its path back.
---
--- Asynchronous for one reason: the run-log tail lives in the sidecar. When
--- there is no big change selected — or the sidecar cannot answer — the bundle
--- is still written, saying so, rather than not being written at all.
--- @param on_done fun(path: string)|nil
function M.write(on_done)
  local parts = gather_local()
  local big = require('nvime.big').state()
  parts.session = big.session

  local function finish()
    local path = M.write_to(M.path(), parts)
    M.deliver(path)
    if on_done ~= nil then
      on_done(path)
    end
  end

  if big.session == nil or big.root == nil then
    finish()
    return
  end
  require('nvime.agent').request('big.runlog', {
    root = big.root,
    sessionId = big.session.id,
    limit = M.RUNLOG_EVENTS,
  }, function(err, result)
    -- A sidecar that cannot answer is itself worth reporting: the bundle says
    -- what went wrong instead of pretending the build had no events.
    parts.runlog = err == nil and (result or {}).events
      or { { seq = 0, event = 'runlog.unavailable', params = { code = err.code } } }
    finish()
  end)
end

return M
