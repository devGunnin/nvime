--- `:Nvime bundle` — one markdown file you can attach to a bug report.
---
--- Issue #10 ("stuck, never allowing me to merge") had nothing attachable: no
--- log, no way to say what nvime was doing. This gathers all of it — versions,
--- the machine, the config, the doctor's findings, the tail of the debug log,
--- and the big change's own state and last events — into one file whose path
--- lands in the registers, ready to paste.
---
--- THE BUNDLE PRINTS WHAT IT NAMES, NEVER WHAT IT IS HANDED. Every section is
--- an allow-list. The session view is a `BigSession` the sidecar spreads
--- wholesale: it carries the runner's control token and socket, the spec, the
--- conversation, and a `title` that IS the first 80 characters of what the
--- user typed. Dumping that object — however it is filtered afterwards — puts
--- the next field somebody adds to it straight into a public issue. So the
--- session, and every run-log event's params, are built field by field here,
--- and `log.redact` is applied on top as belt-and-braces.
local diagnostics = require('nvime.diagnostics')
local log = require('nvime.log')

local M = {}

--- Log lines the bundle attaches, merged across every process's log.
M.LOG_LINES = 200

--- Run-log events the bundle attaches, newest last.
M.RUNLOG_EVENTS = 50

--- A hung `claude` is the likeliest thing to be wrong when someone reaches for
--- this command, so no probe it runs may hold the editor for longer than this.
M.PROBE_TIMEOUT_MS = 3000

--- Owner-only: the bundle carries the doctor output, which names the git
--- identity, and the log tail, which names every project path.
local OWNER_ONLY = 384

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

--- @param value any
--- @return string a scalar rendered plainly, or a placeholder — never a table
local function scalar(value)
  if value == nil then
    return '(none)'
  end
  if type(value) == 'table' then
    return '(omitted)'
  end
  return tostring(value)
end

--- @param at number|nil epoch milliseconds
--- @return string
local function moment(at)
  if type(at) ~= 'number' then
    return '(none)'
  end
  return os.date('!%Y-%m-%dT%H:%M:%SZ', math.floor(at / 1000))
end

--- The detached runner, by the only two things a bug report can act on: which
--- process it is, and whether it is still there. NEVER its token, NEVER its
--- socket — together those are a live control channel into the build.
--- @param runner table|nil
--- @return string
local function runner_line(runner)
  if type(runner) ~= 'table' or type(runner.pid) ~= 'number' then
    return '- runner: (none recorded)'
  end
  local signalled, result = pcall(vim.uv.kill, runner.pid, 0)
  local alive = signalled and result ~= nil
  return string.format('- runner: pid %d, %s', runner.pid, alive and 'alive' or 'gone')
end

--- The big change, field by named field.
--- @param session table|nil
--- @return string[]
local function session_lines(session)
  if type(session) ~= 'table' then
    return { 'no big change is selected in this editor.' }
  end
  local base = type(session.base) == 'table' and session.base or {}
  local merge = type(session.merge) == 'table' and session.merge or {}
  local worktree = type(session.worktree) == 'table' and session.worktree or {}
  return {
    '- id: ' .. scalar(session.id),
    '- state: ' .. scalar(session.state),
    '- display: ' .. scalar(session.display),
    '- steerable: ' .. scalar(session.steerable),
    '- base sha: ' .. scalar(base.commit) .. ' (branch ' .. scalar(base.branch) .. ')',
    '- head sha: ' .. scalar(merge.commit),
    '- worktree: ' .. scalar(worktree.path),
    runner_line(session.runner),
    '- created: ' .. moment(session.createdAt),
    '- updated: ' .. moment(session.updatedAt),
  }
end

--- What each run-log event is allowed to say about itself. A `big.delta` is
--- the model's own words, a `big.tool` summary quotes the reader's files: both
--- are recorded by size. Anything not named here is described by its shape.
--- @param event string
--- @param params table
--- @return string
local function event_params(event, params)
  if type(params) ~= 'table' then
    return ''
  end
  if event:find('%.delta$') ~= nil then
    return string.format('%d bytes', #tostring(params.text or ''))
  end
  if event:find('%.tool$') ~= nil then
    return string.format('%s (summary %d bytes)', scalar(params.tool), #tostring(params.summary or ''))
  end
  if event:find('%.phase$') ~= nil or event:find('%.state$') ~= nil then
    return scalar(params.phase or params.state)
  end
  local names = {}
  for key in pairs(params) do
    names[#names + 1] = tostring(key)
  end
  table.sort(names)
  return 'keys: ' .. table.concat(names, ', ')
end

--- @param events table[]|nil run-log events, oldest first
--- @return string[]
local function runlog_lines(events)
  if events == nil or #events == 0 then
    return { '(no build events recorded for this big change)' }
  end
  local out = {}
  for _, event in ipairs(events) do
    out[#out + 1] =
      string.format('%6s  %-16s %s', scalar(event.seq), scalar(event.event), event_params(event.event, event.params))
  end
  return out
end

--- The whole bundle, as lines. Pure, so the allow-list — and the redaction on
--- top of it — is testable without a sidecar, a repository or a machine.
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

  -- Redacted on top of the allow-list: two independent reasons a secret would
  -- have to survive to reach the file.
  section(lines, 'big change', session_lines(log.redact(parts.session)))
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

--- The first free name at or after `path`: `-2`, `-3`, … The stamp is only
--- accurate to the second, and two bundles in one second must not overwrite.
--- @param path string
--- @return string|nil path, nil when nothing could be created
local function create_exclusive(path)
  local stem = path:gsub('%.md$', '')
  for attempt = 1, 50 do
    local candidate = attempt == 1 and path or string.format('%s-%d.md', stem, attempt)
    local fd = vim.uv.fs_open(candidate, 'wx', OWNER_ONLY)
    if fd ~= nil then
      vim.uv.fs_close(fd)
      return candidate
    end
    if vim.uv.fs_stat(candidate) == nil then
      -- Not a collision: the directory is missing or unwritable, and a
      -- different name will not help.
      return nil
    end
  end
  return nil
end

--- @param path string
--- @param parts table
--- @return string|nil the path actually written, or nil when it could not be
function M.write_to(path, parts)
  assert(type(path) == 'string' and path ~= '', 'bundle.write_to needs a path')
  pcall(vim.fn.mkdir, vim.fs.dirname(path), 'p')
  local target = create_exclusive(path)
  if target == nil then
    vim.notify('nvime: could not write the diagnostics bundle to ' .. path, vim.log.levels.ERROR)
    return nil
  end
  local file, err = io.open(target, 'w')
  if file == nil then
    vim.notify(string.format('nvime: could not write the diagnostics bundle (%s)', tostring(err)), vim.log.levels.ERROR)
    return nil
  end
  file:write(table.concat(M.render(parts), '\n') .. '\n')
  file:close()
  vim.uv.fs_chmod(target, OWNER_ONLY)
  return target
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

--- The two version probes the doctor does not already pay for, both bounded
--- and both off the main thread. `cb(facts)` runs once, when both have
--- answered or timed out.
--- @param claude string the claude binary to ask
--- @param root string a directory inside the nvime checkout
--- @param cb fun(facts: table) { sha, claude }
function M.probe_versions(claude, root, cb)
  assert(type(cb) == 'function', 'bundle.probe_versions needs a callback')
  local facts, outstanding = {}, 2
  local function done()
    outstanding = outstanding - 1
    if outstanding == 0 then
      cb(facts)
    end
  end
  local function answer(key)
    return function(output, err)
      -- A probe that missed its deadline says so: an empty row would read as
      -- "not installed", which is a different bug report entirely.
      facts[key] = output or ((err == nil or err == '') and '(timed out)' or ('(failed: ' .. err .. ')'))
      done()
    end
  end
  diagnostics.probe_async({ 'git', '-C', root, 'rev-parse', '--short', 'HEAD' }, M.PROBE_TIMEOUT_MS, answer('sha'))
  diagnostics.probe_async({ claude, '--version' }, M.PROBE_TIMEOUT_MS, answer('claude'))
end

--- Everything the bundle needs, gathered without a second sidecar and without
--- a second `node` probe: `diagnostics.run` already pays for those, and its
--- own probes are bounded down to the bundle's deadline.
--- @param cb fun(parts: table)
local function gather(cb)
  local config = require('nvime.config').get()
  local agent = require('nvime.agent')
  local uname = vim.uv.os_uname()
  local entries, facts = diagnostics.run(nil, {
    skip_sidecar = true,
    probe_timeout_ms = M.PROBE_TIMEOUT_MS,
  })
  local status = log.status()
  status.tail = log.tail(M.LOG_LINES)
  M.probe_versions(config.agent.claude or 'claude', agent.plugin_root(), function(probed)
    cb({
      environment = {
        { label = 'nvime', value = string.format('%s (%s)', require('nvime.version'), probed.sha) },
        { label = 'neovim', value = tostring(vim.version()) },
        { label = 'os', value = string.format('%s %s %s', uname.sysname, uname.release, uname.machine) },
        { label = 'node', value = facts.node or '(not found)' },
        { label = 'claude', value = probed.claude },
      },
      config = config,
      doctor = entries,
      log = status,
    })
  end)
end

--- Writes the bundle and hands its path back.
---
--- Asynchronous throughout: the version probes are off the main thread and the
--- run-log tail lives in the sidecar. When there is no big change selected — or
--- the sidecar cannot answer — the bundle is still written, saying so.
--- @param on_done fun(path: string|nil)|nil
function M.write(on_done)
  gather(function(parts)
    local big = require('nvime.big').state()
    parts.session = big.session

    local function finish()
      local path = M.write_to(M.path(), parts)
      if path ~= nil then
        M.deliver(path)
      end
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
  end)
end

return M
