local t = require('harness')
local completion = require('nvime.completion')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

local function sandbox()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, 'p')
  return dir
end

--- Pumps the event loop until `root`'s cache is ready — the walk is chunked
--- across `vim.schedule`, so nothing but `vim.wait` will ever finish it.
local function wait_ready(root, ms)
  ok(
    vim.wait(ms or 3000, function()
      return completion.ready(root)
    end, 10),
    'the cache for ' .. root .. ' never became ready'
  )
end

describe('completion.start_col', function()
  it('starts right after the @, keeping it in the typed prompt', function()
    eq(9, completion.start_col('explain @foo', 12))
  end)

  it('is -1 with no @ before the cursor', function()
    eq(-1, completion.start_col('explain foo', 11))
  end)

  it('does not treat an email address as a reference', function()
    eq(-1, completion.start_col('mail someone@example', 20))
  end)

  it('is -1 once something other than a path character breaks the run', function()
    eq(-1, completion.start_col('@foo bar', 8))
  end)
end)

describe('completion.refresh / completion.candidates', function()
  it('lists files and directories under the root, respecting .gitignore', function()
    local dir = sandbox()
    vim.fn.writefile({ 'a = 1' }, dir .. '/keep.py')
    vim.fn.writefile({ 'x' }, dir .. '/ignored.log')
    vim.fn.mkdir(dir .. '/sub', 'p')
    vim.fn.writefile({ 'b = 2' }, dir .. '/sub/nested.py')
    vim.fn.mkdir(dir .. '/build', 'p')
    vim.fn.writefile({ 'z' }, dir .. '/build/output.txt')
    vim.fn.writefile({ '*.log', 'build/' }, dir .. '/.gitignore')

    completion.invalidate(dir)
    completion.refresh(dir)
    wait_ready(dir)

    local candidates = completion.candidates(dir, '')
    ok(vim.tbl_contains(candidates, 'keep.py'), vim.inspect(candidates))
    ok(vim.tbl_contains(candidates, 'sub/nested.py'), vim.inspect(candidates))
    ok(vim.tbl_contains(candidates, 'sub/'), vim.inspect(candidates))
    ok(not vim.tbl_contains(candidates, 'ignored.log'), vim.inspect(candidates))
    ok(not vim.iter(candidates):any(function(c)
      return vim.startswith(c, 'build')
    end), vim.inspect(candidates))
    vim.fn.delete(dir, 'rf')
  end)

  it('narrows to the typed prefix', function()
    local dir = sandbox()
    vim.fn.writefile({ 'a' }, dir .. '/alpha.py')
    vim.fn.writefile({ 'b' }, dir .. '/beta.py')
    completion.invalidate(dir)
    completion.refresh(dir)
    wait_ready(dir)
    eq({ 'alpha.py' }, completion.candidates(dir, 'al'))
    vim.fn.delete(dir, 'rf')
  end)

  it('un-ignores what a later negated pattern names', function()
    local dir = sandbox()
    vim.fn.writefile({ 'x' }, dir .. '/keep.log')
    vim.fn.writefile({ 'y' }, dir .. '/drop.log')
    vim.fn.writefile({ '*.log', '!keep.log' }, dir .. '/.gitignore')
    completion.invalidate(dir)
    completion.refresh(dir)
    wait_ready(dir)
    local candidates = completion.candidates(dir, '')
    ok(vim.tbl_contains(candidates, 'keep.log'), vim.inspect(candidates))
    ok(not vim.tbl_contains(candidates, 'drop.log'), vim.inspect(candidates))
    vim.fn.delete(dir, 'rf')
  end)

  it('shows files even when 50+ directories alone would otherwise fill every row', function()
    local dir = sandbox()
    for i = 1, 60 do
      vim.fn.mkdir(string.format('%s/d%02d', dir, i), 'p')
    end
    vim.fn.writefile({ 'x' }, dir .. '/only-file.txt')
    completion.invalidate(dir)
    completion.refresh(dir)
    wait_ready(dir)
    local candidates = completion.candidates(dir, '')
    local has_file = false
    for _, c in ipairs(candidates) do
      if c == 'only-file.txt' then
        has_file = true
      end
    end
    ok(has_file, 'a lone file must not be starved out by 60 matching directories: ' .. vim.inspect(candidates))
    vim.fn.delete(dir, 'rf')
  end)

  it('surfaces how many matches were left out of the popup, instead of silently capping', function()
    local dir = sandbox()
    for i = 1, 70 do
      vim.fn.writefile({ 'x' }, string.format('%s/f%03d.txt', dir, i))
    end
    completion.invalidate(dir)
    completion.refresh(dir)
    wait_ready(dir)
    local candidates = completion.candidates(dir, '')
    local notice = candidates[#candidates]
    ok(type(notice) == 'table', 'the last row should be a truncation notice: ' .. vim.inspect(notice))
    ok(notice.empty == 1, 'an empty-word notice needs empty=1 or Vim drops it')
    ok(notice.abbr:find('more') ~= nil, notice.abbr)
    vim.fn.delete(dir, 'rf')
  end)

  it('answers nothing before the cache is warm, rather than walking the tree inline', function()
    local dir = sandbox()
    vim.fn.writefile({ 'a' }, dir .. '/alpha.py')
    completion.invalidate(dir)
    eq({}, completion.candidates(dir, ''))
    eq(false, completion.ready(dir))
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('completion vs git — differential gitignore matching', function()
  it(
    'agrees with `git ls-files --others --exclude-standard` on character classes, ** across /, and nested .gitignore',
    function()
      local dir = sandbox()
      vim.fn.system({ 'git', 'init', '-q', dir })
      ok(vim.v.shell_error == 0, 'git init failed, cannot run the differential test')

      -- Character class: b.txt is ignored ([ab].txt), a.txt and c.txt are not.
      vim.fn.writefile({ 'x' }, dir .. '/a.txt')
      vim.fn.writefile({ 'x' }, dir .. '/b.txt')
      vim.fn.writefile({ 'x' }, dir .. '/c.txt')

      -- `**` must cross more than one `/`.
      vim.fn.mkdir(dir .. '/deep/nested', 'p')
      vim.fn.writefile({ 'x' }, dir .. '/deep/deep.txt')
      vim.fn.writefile({ 'x' }, dir .. '/deep/nested/deep.txt')
      vim.fn.writefile({ 'x' }, dir .. '/deep/keep.txt')

      -- A nested .gitignore, scoped to its own directory only.
      vim.fn.mkdir(dir .. '/sub', 'p')
      vim.fn.writefile({ 'x' }, dir .. '/sub/nested-ignored.py')
      vim.fn.writefile({ 'x' }, dir .. '/sub/kept.py')
      vim.fn.writefile({ 'nested-ignored.py' }, dir .. '/sub/.gitignore')

      vim.fn.writefile({ '[ab].txt', '**/deep.txt' }, dir .. '/.gitignore')

      local out = vim.fn.systemlist({ 'git', '-C', dir, 'ls-files', '--others', '--exclude-standard' })
      ok(vim.v.shell_error == 0, 'git ls-files failed: ' .. table.concat(out, '\n'))
      local expected = {}
      for _, path in ipairs(out) do
        expected[path] = true
      end
      ok(next(expected) ~= nil, 'fixture produced no git-tracked files to compare against')

      completion.invalidate(dir)
      completion.refresh(dir)
      wait_ready(dir)
      local candidates = completion.candidates(dir, '')
      local offered = {}
      for _, c in ipairs(candidates) do
        if type(c) == 'string' and not vim.endswith(c, '/') then
          offered[c] = true
        end
      end

      for path in pairs(expected) do
        ok(offered[path] == true, path .. ' — git offers it, the matcher does not')
      end
      for path in pairs(offered) do
        ok(expected[path] == true, path .. ' — the matcher offers it, git ignores it')
      end
      vim.fn.delete(dir, 'rf')
    end
  )
end)

describe('completion — a malformed .gitignore pattern degrades, never crashes', function()
  it('skips a `[]]` class instead of throwing, and does not filter anything with it', function()
    local dir = sandbox()
    vim.fn.writefile({ 'x' }, dir .. '/keep.py')
    -- `[]]` is git's spelling for "a literal `]`" — legitimate syntax that
    -- used to compile to an invalid Lua pattern and throw at match time.
    vim.fn.writefile({ 'x' }, dir .. '/oddname]file.txt')
    vim.fn.writefile({ '[]]*.txt' }, dir .. '/.gitignore')
    completion.invalidate(dir)
    completion.refresh(dir)
    wait_ready(dir)

    local candidates = completion.candidates(dir, '')
    ok(vim.tbl_contains(candidates, 'keep.py'), vim.inspect(candidates))
    ok(
      vim.tbl_contains(candidates, 'oddname]file.txt'),
      'a skipped rule must filter nothing, not fall back to matching everything: ' .. vim.inspect(candidates)
    )
    vim.fn.delete(dir, 'rf')
  end)

  it('recovers instead of getting stuck at "loading" forever', function()
    local dir = sandbox()
    vim.fn.writefile({ 'x' }, dir .. '/keep.py')
    vim.fn.writefile({ '[]]*.txt' }, dir .. '/.gitignore')

    completion.invalidate(dir)
    completion.refresh(dir)
    wait_ready(dir)
    ok(completion.ready(dir), 'the cache must not be stuck on the loading sentinel')

    -- A second refresh after invalidate must also complete cleanly.
    completion.invalidate(dir)
    completion.refresh(dir)
    wait_ready(dir)
    ok(completion.ready(dir), 'a later refresh must still be able to complete')
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('completion — ** backtracking is bounded', function()
  it('matches an 11-** / 20-deep tree in well under a second', function()
    local dir = sandbox()
    -- One rule, 11 `**` segments — without memoisation this backtracks
    -- combinatorially over every split point; the reviewer measured 13s for
    -- this exact shape.
    local pattern = string.rep('**/', 11) .. 'nomatch.txt'
    vim.fn.writefile({ pattern }, dir .. '/.gitignore')

    local path = dir
    for i = 1, 20 do
      path = path .. '/d' .. i
      vim.fn.mkdir(path, 'p')
    end
    for i = 1, 10 do
      vim.fn.writefile({ 'x' }, string.format('%s/f%02d.txt', path, i))
    end

    -- Entry count (~30) stays well under the walk's CHUNK size, so a warm
    -- `refresh` completes synchronously — this measures the matcher itself,
    -- not scheduler latency.
    completion.invalidate(dir)
    local clock = vim.uv or vim.loop
    local start = clock.hrtime()
    completion.refresh(dir)
    local elapsed_ms = (clock.hrtime() - start) / 1e6

    ok(completion.ready(dir), 'a small tree must finish synchronously, inside refresh() itself')
    ok(elapsed_ms < 100, string.format('refresh took %dms, expected sub-100ms once memoised', elapsed_ms))
    vim.fn.delete(dir, 'rf')
  end)
end)

describe('completion.completefunc', function()
  it('answers -1 on findstart, and no candidates, without a bound root', function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    eq(-1, completion.completefunc(1, ''))
    eq({}, completion.completefunc(0, ''))
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  it('finds the start column and then the candidates, through the buffer-local root', function()
    local dir = sandbox()
    vim.fn.writefile({ 'a' }, dir .. '/alpha.py')
    completion.invalidate(dir)
    completion.refresh(dir)
    wait_ready(dir)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.b[buf].nvime_root = dir
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'look at @al' })
    vim.api.nvim_win_set_cursor(0, { 1, 11 })

    eq(9, completion.completefunc(1, ''))
    eq({ 'alpha.py' }, completion.completefunc(0, 'al'))

    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(dir, 'rf')
  end)

  it('starts a fetch instead of answering stale data when the cache is cold', function()
    local dir = sandbox()
    vim.fn.writefile({ 'a' }, dir .. '/alpha.py')
    completion.invalidate(dir)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buf)
    vim.b[buf].nvime_root = dir

    eq({}, completion.completefunc(0, ''))
    wait_ready(dir)
    eq({ 'alpha.py' }, completion.candidates(dir, ''))

    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(dir, 'rf')
  end)
end)
