local t = require('harness')
local approval = require('nvime.approval')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local function request(id, reason)
  return { approvalId = id, tool = 'Bash', summary = 'running rm -rf /', reason = reason or 'runs a shell command' }
end

--- Presses `key` in the float, resolving `<Esc>` to the byte nvim matches on
--- and going through mappings, the way the user's keystroke does.
local function press(key)
  vim.api.nvim_set_current_win(approval.current().win)
  vim.cmd('normal ' .. vim.api.nvim_replace_termcodes(key, true, true, true))
end

--- No `beforeEach` in the harness: each test starts from an empty queue.
local function fresh()
  approval.dismiss_all()
end

local function rendered()
  return table.concat(vim.api.nvim_buf_get_lines(approval.current().buf, 0, -1, false), '\n')
end

describe('approval.ask', function()
  it('shows a float with the ask and answers on y', function()
    fresh()
    local answered = nil
    approval.ask(request('a1'), function(allow)
      answered = allow
    end)
    ok(approval.current() ~= nil, 'the float is on screen')
    ok(rendered():find('rm -rf /', 1, true) ~= nil, 'it says what was asked')
    ok(rendered():find('shell command', 1, true) ~= nil, 'and why nvime will not just allow it')
    press('y')
    eq(true, answered)
    eq(nil, approval.current(), 'and the float goes away')
  end)

  it('denies on n and on <Esc>', function()
    fresh()
    local answers = {}
    approval.ask(request('a1'), function(allow)
      answers[#answers + 1] = allow
    end)
    press('n')
    approval.ask(request('a2'), function(allow)
      answers[#answers + 1] = allow
    end)
    press('<Esc>')
    eq({ false, false }, answers)
  end)

  it('never opens two floats at once, and works through the queue in order', function()
    fresh()
    local answered = {}
    approval.ask(request('first'), function()
      answered[#answered + 1] = 'first'
    end)
    approval.ask(request('second'), function()
      answered[#answered + 1] = 'second'
    end)
    eq(1, approval.queued(), 'the second ask waits its turn')
    eq('first', approval.current().request.approvalId)
    press('y')
    eq('second', approval.current().request.approvalId, 'the next one takes its place')
    press('y')
    eq({ 'first', 'second' }, answered)
    eq(nil, approval.current())
  end)

  it('refuses an ask with no id or no callback', function()
    fresh()
    t.throws(function()
      approval.ask({}, function() end)
    end, 'needs a request')
    t.throws(function()
      approval.ask(request('a1'), nil)
    end, 'needs an answer callback')
    approval.dismiss_all()
  end)
end)

describe('approval.settle', function()
  it('withdraws the ask the sidecar stopped waiting for, without answering', function()
    fresh()
    local answered = false
    approval.ask(request('a1'), function()
      answered = true
    end)
    eq(true, approval.settle('a1'))
    eq(nil, approval.current())
    eq(false, answered, 'a withdrawn ask is not a denial the user made')
  end)

  it('withdraws one still in the queue and lets the rest through', function()
    fresh()
    local answered = {}
    approval.ask(request('a1'), function()
      answered[#answered + 1] = 'a1'
    end)
    approval.ask(request('a2'), function()
      answered[#answered + 1] = 'a2'
    end)
    eq(true, approval.settle('a2'))
    eq(0, approval.queued())
    press('y')
    eq({ 'a1' }, answered)
  end)

  it('reports an id it knows nothing about', function()
    fresh()
    eq(false, approval.settle('nobody'))
  end)
end)

describe('approval.dismiss_all', function()
  it('denies everything outstanding when the surface goes away', function()
    fresh()
    local answers = {}
    approval.ask(request('a1'), function(allow)
      answers[#answers + 1] = allow
    end)
    approval.ask(request('a2'), function(allow)
      answers[#answers + 1] = allow
    end)
    approval.dismiss_all()
    eq({ false, false }, answers, 'an ask nobody can answer must not be left allowing')
    eq(nil, approval.current())
    eq(0, approval.queued())
  end)
end)
