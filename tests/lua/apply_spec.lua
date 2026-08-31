local t = require('harness')
local apply = require('nvime.apply')
local palette = require('nvime.palette')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local dirs = {}

--- A real file on disk, opened in a real buffer — the only way to exercise
--- the mtime refresh and undo grouping this module exists for.
local function open_file(text)
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, 'p')
  dirs[#dirs + 1] = dir
  local path = dir .. '/queue.py'
  local handle = assert(io.open(path, 'wb'))
  handle:write(text)
  handle:close()
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  apply.reset()
  palette.apply()
  return path, vim.api.nvim_get_current_buf()
end

local function cleanup()
  for _, dir in ipairs(dirs) do
    vim.fn.delete(dir, 'rf')
  end
  dirs = {}
end

local function disk(path)
  local handle = assert(io.open(path, 'rb'))
  local text = handle:read('a')
  handle:close()
  return text
end

--- The agent's half of a run: write the file, then hand nvime the snapshots.
local function agent_wrote(path, before, after)
  local handle = assert(io.open(path, 'wb'))
  handle:write(after)
  handle:close()
  return { path = path, before = { kind = 'text', text = before }, after = { kind = 'text', text = after } }
end

--- Somebody other than the agent writing the file: a formatter, a git
--- checkout, a second editor.
local function externally_wrote(path, text)
  local handle = assert(io.open(path, 'ab'))
  handle:write(text)
  handle:close()
end

local function lines_of(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

--- The text under the cursor, which is what "the cursor stayed put" means.
local function cursor_text(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
end

local function marks(buf)
  return vim.api.nvim_buf_get_extmarks(buf, apply.NS, 0, -1, { details = true })
end

--- Replaces the fade timer with a queue the test drains by hand.
local function with_manual_fade(fn)
  local real = apply.schedule
  local queued = {}
  apply.schedule = function(_, callback)
    queued[#queued + 1] = callback
    return { stop = function() end }
  end
  local function drain()
    local next_fn = table.remove(queued, 1)
    if next_fn ~= nil then
      next_fn()
    end
    return next_fn ~= nil
  end
  local ok_run, err = pcall(fn, drain)
  apply.schedule = real
  if not ok_run then
    error(err, 0)
  end
end

describe('apply.apply', function()
  it('rewrites only the changed hunk and keeps the cursor where it was', function()
    local path, buf = open_file('one\ntwo\nthree\nfour\n')
    vim.api.nvim_win_set_cursor(0, { 4, 2 })
    local status = apply.apply(agent_wrote(path, 'one\ntwo\nthree\nfour\n', 'one\nTWO\nthree\nfour\n'), {
      run_id = 'r1',
      nofade = true,
    })
    eq('applied', status)
    eq({ 'one', 'TWO', 'three', 'four' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    eq({ 4, 2 }, vim.api.nvim_win_get_cursor(0), 'the cursor is untouched')
    eq(false, vim.bo[buf].modified, 'and the buffer matches disk again')
    cleanup()
  end)

  it('clamps the cursor when the file got shorter instead of throwing', function()
    local path, buf = open_file('one\ntwo\nthree\nfour\n')
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    eq('applied', apply.apply(agent_wrote(path, 'one\ntwo\nthree\nfour\n', 'one\n'), { run_id = 'r1', nofade = true }))
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
    eq({ 'one' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    cleanup()
  end)

  it('leaves no "file changed" warning behind for a later checktime', function()
    local path, buf = open_file('one\ntwo\n')
    apply.apply(agent_wrote(path, 'one\ntwo\n', 'one\nTWO\n'), { run_id = 'r1', nofade = true })
    local before = vim.fn.execute('messages')
    vim.cmd('checktime')
    local added = vim.fn.execute('messages'):sub(#before + 1)
    eq('', vim.trim(added), 'W11/W12 would appear here if the stored mtime were stale')
    eq(false, vim.bo[buf].modified)
    cleanup()
  end)

  it('groups a run into one undo block, so a single u reverts all of it', function()
    local path, buf = open_file('a\nb\nc\n')
    apply.apply(agent_wrote(path, 'a\nb\nc\n', 'A\nb\nc\n'), { run_id = 'r1', nofade = true })
    apply.apply(agent_wrote(path, 'A\nb\nc\n', 'A\nB\nc\n'), { run_id = 'r1', nofade = true })
    eq({ 'A', 'B', 'c' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('silent undo')
    end)
    eq({ 'a', 'b', 'c' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'one u, the whole run gone')
    cleanup()
  end)

  it('starts a new undo block for a new run', function()
    local path, buf = open_file('a\nb\n')
    apply.apply(agent_wrote(path, 'a\nb\n', 'A\nb\n'), { run_id = 'r1', nofade = true })
    apply.apply(agent_wrote(path, 'A\nb\n', 'A\nB\n'), { run_id = 'r2', nofade = true })
    vim.api.nvim_buf_call(buf, function()
      vim.cmd('silent undo')
    end)
    eq({ 'A', 'b' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'u undoes the second run only')
    cleanup()
  end)

  it('refuses a buffer with unsaved edits rather than clobbering them', function()
    local path, buf = open_file('a\nb\n')
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'mine' })
    local status, detail = apply.apply(agent_wrote(path, 'a\nb\n', 'a\nB\n'), { run_id = 'r1', nofade = true })
    eq('conflict', status)
    ok(detail:find('unsaved edits') ~= nil)
    eq({ 'a', 'mine' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false), 'the hand edit survives untouched')
    cleanup()
  end)

  it('reports a file nothing has open, so the panel can say so', function()
    local path = open_file('a\n')
    vim.cmd('enew')
    vim.cmd('silent! bwipeout! ' .. vim.fn.bufnr(path))
    eq('not-open', apply.apply(agent_wrote(path, 'a\n', 'b\n'), { run_id = 'r1' }))
    cleanup()
  end)

  it('refuses to guess at a binary or oversized change', function()
    local path, _ = open_file('a\n')
    local status, detail = apply.apply({
      path = path,
      before = { kind = 'opaque', reason = 'binary', bytes = 3 },
      after = { kind = 'opaque', reason = 'binary', bytes = 4 },
    }, { run_id = 'r1' })
    eq('opaque', status)
    ok(detail:find('binary') ~= nil)
    cleanup()
  end)

  it('refreshes the stored mtime even when the buffer already matched', function()
    local path, buf = open_file('a\n')
    -- The user saved the same content the agent then wrote: nothing to rewrite,
    -- but the buffer's idea of the file is still older than disk.
    local change = agent_wrote(path, 'a\n', 'a\n')
    change.before = { kind = 'text', text = 'old\n' }
    eq('unchanged', apply.apply(change, { run_id = 'r1', nofade = true }))
    eq(false, vim.bo[buf].modified)
    cleanup()
  end)

  it('writes back byte for byte when the file has no trailing newline', function()
    local path, buf = open_file('one\ntwo\n')
    eq('applied', apply.apply(agent_wrote(path, 'one\ntwo\n', 'one\nTWO'), { run_id = 'r1', nofade = true }))
    eq('one\nTWO', disk(path), "'fixendofline' must not add a newline the agent did not write")
    eq('one\nTWO', apply.buffer_text(buf))
    cleanup()
  end)

  it('keeps the cursor on its own line when the agent inserts lines above it', function()
    local path, buf = open_file('l1\nl2\nl3\nl4\nl5\n')
    vim.api.nvim_win_set_cursor(0, { 5, 1 })
    eq('l5', cursor_text(buf), 'the probe starts on l5')
    eq(
      'applied',
      apply.apply(agent_wrote(path, 'l1\nl2\nl3\nl4\nl5\n', 'a\nb\nc\nl1\nl2\nl3\nl4\nl5\n'), {
        run_id = 'r1',
        nofade = true,
      })
    )
    eq('l5', cursor_text(buf), 'the cursor rode the content down, not the line number')
    eq(8, vim.api.nvim_win_get_cursor(0)[1])
    eq(1, vim.api.nvim_win_get_cursor(0)[2], 'and kept its column')
    cleanup()
  end)

  it('keeps the cursor on its own line when the agent deletes lines above it', function()
    local path, buf = open_file('l1\nl2\nl3\nl4\nl5\n')
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    eq('applied', apply.apply(agent_wrote(path, 'l1\nl2\nl3\nl4\nl5\n', 'l4\nl5\n'), { run_id = 'r1', nofade = true }))
    eq('l5', cursor_text(buf))
    eq(2, vim.api.nvim_win_get_cursor(0)[1])
    cleanup()
  end)

  it('refuses to write over a change something else made after the agent read the file', function()
    local path, buf = open_file('one\ntwo\n')
    local change = agent_wrote(path, 'one\ntwo\n', 'one\nTWO\n')
    externally_wrote(path, 'EXTERNAL\n')
    local status, detail = apply.apply(change, { run_id = 'r1', nofade = true })
    eq('external-change', status)
    ok(detail:find('changed on disk', 1, true) ~= nil, 'got: ' .. tostring(detail))
    eq('one\nTWO\nEXTERNAL\n', disk(path), 'the other write survives — write! would have destroyed it')
    eq({ 'one', 'two' }, lines_of(buf), 'and the buffer is left as it was')
    cleanup()
  end)

  it('separates a stale buffer from one with unsaved edits', function()
    local path, buf = open_file('a\nb\n')
    -- A shell step rewrote the file; the buffer is clean but out of date.
    local handle = assert(io.open(path, 'wb'))
    handle:write('shell\nb\n')
    handle:close()
    local change = agent_wrote(path, 'shell\nb\n', 'shell\nB\n')
    local status, detail = apply.apply(change, { run_id = 'r1', nofade = true })
    eq('stale-buffer', status)
    ok(detail:find('neither side', 1, true) ~= nil, 'got: ' .. tostring(detail))
    ok(detail:find('unsaved') == nil, 'a clean buffer must not be accused of unsaved edits')
    eq({ 'a', 'b' }, lines_of(buf))
    cleanup()
  end)

  it("gives the user's 'fixendofline' back once the newline is restored", function()
    local path, buf = open_file('a\nb\n')
    eq(true, vim.bo[buf].fixendofline, 'the probe starts from the default')
    eq('applied', apply.apply(agent_wrote(path, 'a\nb\n', 'a\nC'), { run_id = 'r1', nofade = true }))
    eq(false, vim.bo[buf].fixendofline, 'off while the file genuinely has no trailing newline')
    eq('applied', apply.apply(agent_wrote(path, 'a\nC', 'a\nC\n'), { run_id = 'r1', nofade = true }))
    eq(true, vim.bo[buf].fixendofline, "and back on afterwards — the option is the user's")
    eq('a\nC\n', disk(path))
    cleanup()
  end)

  it('does not swallow a failed undo-block break', function()
    local path = open_file('a\n')
    local real_cmd = vim.cmd
    vim.cmd = function(command)
      if type(command) == 'string' and command:find('undolevels', 1, true) ~= nil then
        error('undo break failed')
      end
      return real_cmd(command)
    end
    local ran, err = pcall(apply.apply, agent_wrote(path, 'a\n', 'b\n'), { run_id = 'r1', nofade = true })
    vim.cmd = real_cmd
    eq(false, ran, 'two runs sharing one undo block is the failure this must not hide')
    ok(tostring(err):find('undo break failed', 1, true) ~= nil, 'got: ' .. tostring(err))
    cleanup()
  end)

  it('keeps disk and buffer identical after applying', function()
    local path, buf = open_file('one\ntwo\n')
    apply.apply(agent_wrote(path, 'one\ntwo\n', 'one\ntwo\nthree\n'), { run_id = 'r1', nofade = true })
    eq(disk(path), apply.buffer_text(buf))
    eq('one\ntwo\nthree\n', disk(path))
    cleanup()
  end)
end)

describe('apply: hunk highlights', function()
  it('marks the changed lines, dims them, then clears them', function()
    with_manual_fade(function(drain)
      local path, buf = open_file('one\ntwo\nthree\n')
      apply.apply(agent_wrote(path, 'one\ntwo\nthree\n', 'one\nTWO\nthree\n'), {
        run_id = 'r1',
        fade_ms = 1500,
      })
      local fresh = marks(buf)
      eq(1, #fresh, 'one changed line, one mark')
      eq(1, fresh[1][2], 'on the line that changed')
      eq('NvimeEditChange', fresh[1][4].line_hl_group)

      ok(drain(), 'the fade was scheduled')
      eq('NvimeEditFade', marks(buf)[1][4].line_hl_group, 'it dims first')

      ok(drain(), 'and the clear was scheduled after it')
      eq(0, #marks(buf), 'then the highlight goes away entirely')
      cleanup()
    end)
  end)

  it('marks an insertion as added and a deletion at its surviving line', function()
    local path, buf = open_file('a\nc\n')
    apply.apply(agent_wrote(path, 'a\nc\n', 'a\nb\nc\n'), { run_id = 'r1', nofade = true })
    eq('NvimeEditAdd', marks(buf)[1][4].line_hl_group)

    apply.clear(buf)
    apply.apply(agent_wrote(path, 'a\nb\nc\n', 'a\nc\n'), { run_id = 'r1', nofade = true })
    eq('NvimeEditDelete', marks(buf)[1][4].line_hl_group)
    cleanup()
  end)

  it('keeps the highlight when nofade is set, and clears on request', function()
    with_manual_fade(function(drain)
      local path, buf = open_file('a\nb\n')
      apply.apply(agent_wrote(path, 'a\nb\n', 'a\nB\n'), { run_id = 'r1', nofade = true })
      eq(1, #marks(buf))
      eq(false, drain(), 'nofade schedules nothing at all')
      apply.clear(buf)
      eq(0, #marks(buf))
      cleanup()
    end)
  end)

  it('does not let an earlier fade clear the highlights of a later change', function()
    with_manual_fade(function(drain)
      local path, buf = open_file('a\nb\nc\n')
      apply.apply(agent_wrote(path, 'a\nb\nc\n', 'A\nb\nc\n'), { run_id = 'r1', fade_ms = 1500 })
      apply.apply(agent_wrote(path, 'A\nb\nc\n', 'A\nB\nc\n'), { run_id = 'r1', fade_ms = 1500 })
      -- The first change's fade is stale by now; draining it must be a no-op.
      drain()
      drain()
      ok(#marks(buf) > 0, 'the newer highlights survive the older timer')
      cleanup()
    end)
  end)
end)

describe('apply.recheck', function()
  it('brings a clean buffer up to date after a shell step nvime could not record', function()
    local path, buf = open_file('one\ntwo\n')
    local root = vim.fs.dirname(path)
    -- An approved `sed -i` / `prettier --write`: no snapshot, no changeset.
    local handle = assert(io.open(path, 'wb'))
    handle:write('one\nFORMATTED\n')
    handle:close()

    local reloaded, left = apply.recheck(root, { run_id = 'r1', nofade = true })
    eq({ path }, reloaded)
    eq({}, left)
    eq({ 'one', 'FORMATTED' }, lines_of(buf), 'the buffer no longer lies about the file')
    eq(false, vim.bo[buf].modified)
    cleanup()
  end)

  it('leaves a buffer with unsaved edits alone and names it', function()
    local path, buf = open_file('one\ntwo\n')
    local root = vim.fs.dirname(path)
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { 'mine' })
    local handle = assert(io.open(path, 'wb'))
    handle:write('one\nFORMATTED\n')
    handle:close()

    local reloaded, left = apply.recheck(root, { run_id = 'r1', nofade = true })
    eq({}, reloaded)
    eq({ path }, left)
    eq({ 'one', 'mine' }, lines_of(buf), 'the hand edit survives')
    cleanup()
  end)

  it('says nothing when the shell step changed no open file', function()
    local path = open_file('one\ntwo\n')
    local reloaded, left = apply.recheck(vim.fs.dirname(path), { run_id = 'r1', nofade = true })
    eq({}, reloaded)
    eq({}, left)
    cleanup()
  end)
end)

describe('apply.buffer_for', function()
  it('finds the loaded buffer for a path and ignores nofile surfaces', function()
    local path, buf = open_file('a\n')
    eq(buf, apply.buffer_for(path))
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].buftype = 'nofile'
    eq(buf, apply.buffer_for(path), 'a scratch buffer is never a candidate')
    vim.api.nvim_buf_delete(scratch, { force = true })
    cleanup()
  end)

  it('reports nothing for a path no buffer holds', function()
    eq(nil, apply.buffer_for('/definitely/not/open/here.txt'))
  end)
end)
