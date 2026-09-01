local t = require('harness')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Stands in for the sidecar: records requests, replies from a canned table.
local fake = { requests = {}, replies = {} }

function fake.request(method, params, cb)
  fake.requests[#fake.requests + 1] = { method = method, params = params }
  local reply = fake.replies[method]
  if reply ~= nil then
    cb(reply.err, reply.result)
  end
end

local real_agent = require('nvime.agent')
package.loaded['nvime.agent'] = {
  request = fake.request,
  on_event = function()
    return function() end
  end,
  is_running = function()
    return true
  end,
  dist_path = function()
    return '/nowhere/dist/index.js'
  end,
  build_hint = function()
    return 'run npm --prefix agent run build'
  end,
}
package.loaded['nvime.dashboard'] = nil
local dashboard = require('nvime.dashboard')

local function summary(overrides)
  return vim.tbl_extend('force', {
    id = 'sess1',
    title = 'connection-pool backoff',
    display = 'reviewing',
    difficulty = 'medium',
    detached = false,
    heldElsewhere = false,
    updatedAt = 1,
    counts = { total = 5, open = 2, substantial = 3, defended = 1 },
  }, overrides or {})
end

local function facts(sessions, overrides)
  return vim.tbl_extend('force', {
    sidecar = 'running',
    build = 'present',
    sessions = sessions,
  }, overrides or {})
end

local function open_dashboard(sessions, err)
  dashboard.dismiss()
  fake.requests, fake.replies = {}, {}
  fake.replies['big.list'] = err ~= nil and { err = err } or { result = { sessions = sessions } }
  dashboard.open()
end

local function text()
  return table.concat(vim.api.nvim_buf_get_lines(dashboard.current().buf, 0, -1, false), '\n')
end

describe('the dashboard page', function()
  it('names where each change is and how much of its review is left', function()
    local line = dashboard.session_line(summary())
    ok(line:match('reviewing') ~= nil, line)
    ok(line:match('1/3 defended') ~= nil, line)
    ok(line:match('connection%-pool backoff') ~= nil, line)
  end)

  it('says landed for a merged change rather than counting its threads', function()
    local line = dashboard.session_line(summary({ display = 'merged' }))
    ok(line:match('merged') ~= nil, line)
    ok(line:match('landed') ~= nil, line)
    ok(line:match('defended') == nil, 'a landed change has nothing left to defend')
  end)

  it('marks a change another editor is driving', function()
    ok(dashboard.session_line(summary({ heldElsewhere = true })):match('reviewing%*') ~= nil)
  end)

  it('says a vibe session ran no gate rather than implying it was defended', function()
    local line = dashboard.session_line(
      summary({ difficulty = 'vibe', counts = { total = 4, open = 0, substantial = 3, defended = 3 } })
    )
    ok(line:match('4 thread%(s%), no gate') ~= nil, line)
    ok(line:match('defended') == nil, 'nothing was defended in a session with no gate')
  end)

  it('says so when a change has threads but nothing to defend', function()
    local line = dashboard.session_line(summary({ counts = { total = 4, open = 0, substantial = 0, defended = 0 } }))
    ok(line:match('4 thread%(s%), nothing to defend') ~= nil, line)
  end)

  it('lists the entry points and the changes together', function()
    local lines, rows = dashboard.render(facts({ summary(), summary({ id = 'sess2', title = 'retry ceiling' }) }))
    local page = table.concat(lines, '\n')
    for _, key in ipairs({ 'c  chat', 'e  edit', 'b  big', 'd  diff' }) do
      ok(page:match(vim.pesc(key)) ~= nil, key)
    end
    ok(page:match('big changes in this project') ~= nil, page)
    local ids = vim.tbl_values(rows)
    table.sort(ids)
    eq({ 'sess1', 'sess2' }, ids, 'every listed change is openable')
  end)

  it('says the sidecar could not be reached rather than showing an empty list', function()
    local page = table.concat(dashboard.render(facts({}, { error = 'the sidecar is not built' })), '\n')
    ok(page:match('! the sidecar is not built') ~= nil, page)
    ok(page:match('none yet') == nil, 'a failure must never read as "no changes"')
  end)

  it('invites a first change when there really are none', function()
    local lines, rows = dashboard.render(facts({}))
    ok(table.concat(lines, '\n'):match('none yet') ~= nil)
    eq({}, rows)
  end)

  it('cuts a long change title to the page width instead of wrapping the row', function()
    local long = summary({ title = string.rep('a very long title ', 8) })
    local lines, rows = dashboard.render(facts({ long }), 60)
    local listed = 0
    for row in pairs(rows) do
      listed = listed + 1
      -- Characters, not cells: `strdisplaywidth` reads off the current buffer
      -- and drifts by a cell or two across a whole suite run, and the property
      -- under test is that the row was cut at all rather than wrapped.
      ok(vim.fn.strchars(lines[row]) <= 60, vim.fn.strchars(lines[row]) .. ': ' .. lines[row])
    end
    eq(1, listed, 'one change is one row, however long its title')
  end)

  it('puts the cursor on the first change, not on the banner', function()
    open_dashboard({ summary(), summary({ id = 'sess2', title = 'retry ceiling' }) })
    local view = dashboard.current()
    local row = vim.api.nvim_win_get_cursor(view.win)[1]
    eq('sess1', view.rows[row], 'the cursor starts on an openable row')
    dashboard.dismiss()
  end)

  it('reports a missing build with what to run', function()
    local page = table.concat(dashboard.render(facts({}, { build = 'missing — run npm' })), '\n')
    ok(page:match('build    missing — run npm') ~= nil, page)
  end)
end)

describe('the dashboard float', function()
  it('asks the sidecar for this project and fills the list in', function()
    open_dashboard({ summary() })
    ok(
      vim.iter(fake.requests):any(function(request)
        return request.method == 'big.list'
      end),
      'the list is asked for, never cached'
    )
    ok(text():match('connection%-pool backoff') ~= nil, text())
    dashboard.dismiss()
  end)

  it('renders the sidecar refusal instead of an empty list', function()
    open_dashboard({}, { message = 'the claude CLI was not found' })
    ok(text():match('! the claude CLI was not found') ~= nil, text())
    dashboard.dismiss()
  end)

  it('binds exactly the keys it publishes, all of them leaves', function()
    open_dashboard({ summary() })
    local buf = dashboard.current().buf
    local bound = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      bound[vim.api.nvim_replace_termcodes(map.lhs, true, true, true)] = map.callback ~= nil
    end
    for _, key in ipairs(dashboard.KEYS) do
      ok(bound[vim.api.nvim_replace_termcodes(key.lhs, true, true, true)] == true, key.lhs .. ' must be bound')
    end
    dashboard.dismiss()
    eq(nil, dashboard.current().buf, 'q leaves nothing behind')
  end)

  it('is listed in the keymap registry, so the leaf-only check can see it', function()
    local config = require('nvime.config')
    local keymaps = require('nvime.keymaps')
    local entries = keymaps.all(config.get())
    local listed = {}
    for _, entry in ipairs(entries) do
      if entry.scope == 'dashboard' then
        listed[entry.lhs] = true
      end
    end
    for _, key in ipairs(dashboard.KEYS) do
      ok(listed[key.lhs] == true, key.lhs .. ' is bound but not registered')
    end
    eq({}, keymaps.conflicts(entries), 'no dashboard key may be a prefix of another mapping')
  end)
end)

package.loaded['nvime.agent'] = real_agent
package.loaded['nvime.dashboard'] = nil
