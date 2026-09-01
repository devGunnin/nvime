--- `@file`/`@dir` completion for prompt buffers. One cache per project root,
--- built by walking the tree with `vim.fs.dir` and dropping whatever the
--- root `.gitignore` excludes — never a shell-out to git, which stays the
--- sidecar's job. The walk is chunked across scheduled steps and capped, so
--- typing `@` in a huge repo never blocks the editor.
local M = {}

--- Entries kept per root. Past this the walk stops rather than growing
--- unbounded on a repo with a very deep or very wide tree.
local MAX_ENTRIES = 4000

--- Rows offered per completion popup. The cache can hold far more than this.
local MAX_SHOWN = 50

--- Directories the walk never descends into, checked by basename at every
--- depth — `.gitignore` itself does not (and should not have to) list these.
local SKIP_DIRS = { ['.git'] = true }

--- How many filesystem entries one scheduled step processes before yielding
--- back to the event loop.
local CHUNK = 200

--- root -> { files = string[], dirs = string[] } | 'loading'
local cache = {}

--- Reads the project's root `.gitignore` into match rules. Only the root
--- file — nested `.gitignore`s are not consulted, matching the scope
--- `context.lua`'s own directory skip-list has always had.
--- @param root string
--- @return table[] each { pattern, negate, dir_only, anchored }
local function load_gitignore(root)
  local handle = io.open(root .. '/.gitignore', 'rb')
  if handle == nil then
    return {}
  end
  local raw = handle:read('*a') or ''
  handle:close()
  local rules = {}
  for _, line in ipairs(vim.split(raw, '\n', { plain = true })) do
    local trimmed = vim.trim(line)
    if trimmed ~= '' and not vim.startswith(trimmed, '#') then
      local negate = vim.startswith(trimmed, '!')
      if negate then
        trimmed = trimmed:sub(2)
      end
      local dir_only = vim.endswith(trimmed, '/')
      if dir_only then
        trimmed = trimmed:sub(1, -2)
      end
      local anchored = vim.startswith(trimmed, '/')
      if anchored then
        trimmed = trimmed:sub(2)
      end
      rules[#rules + 1] = { pattern = trimmed, negate = negate, dir_only = dir_only, anchored = anchored }
    end
  end
  return rules
end

--- One gitignore glob, as a Lua pattern: `*` -> any run of non-slash
--- characters, `?` -> one character, everything else literal.
--- @param glob string
--- @return string
local function glob_to_pattern(glob)
  local out = { '^' }
  for char in glob:gmatch('.') do
    if char == '*' then
      out[#out + 1] = '[^/]*'
    elseif char == '?' then
      out[#out + 1] = '[^/]'
    elseif char:match('%p') ~= nil then
      out[#out + 1] = '%' .. char
    else
      out[#out + 1] = char
    end
  end
  out[#out + 1] = '$'
  return table.concat(out)
end

--- Whether one rule matches `relpath` (root-relative, no leading `/`). A
--- pattern with no `/` of its own matches a basename at any depth, exactly as
--- git matches a bare name; a pattern with a `/` (leading or internal) is
--- anchored to the `.gitignore`'s own directory — here, always the root.
--- @param rule table
--- @param relpath string
--- @return boolean
local function rule_matches(rule, relpath)
  local anchored = rule.anchored or rule.pattern:find('/', 1, true) ~= nil
  local pattern = glob_to_pattern(rule.pattern)
  if anchored then
    return relpath:match(pattern) ~= nil
  end
  return vim.fs.basename(relpath):match(pattern) ~= nil
end

--- Whether `relpath` is ignored, applying every rule in order — a later rule
--- (including a `!` negation) overrides an earlier match, as git does.
--- @param rules table[]
--- @param relpath string
--- @param is_dir boolean
--- @return boolean
local function is_ignored(rules, relpath, is_dir)
  local ignored = false
  for _, rule in ipairs(rules) do
    if (is_dir or not rule.dir_only) and rule_matches(rule, relpath) then
      ignored = not rule.negate
    end
  end
  return ignored
end

--- Walks `root`, a few hundred entries per scheduled step, honoring `rules`
--- and `SKIP_DIRS`. `on_done(files, dirs)` runs exactly once, whatever
--- stopped the walk — reaching the end, or `MAX_ENTRIES`.
--- @param root string
--- @param rules table[]
--- @param on_done fun(files: string[], dirs: string[])
local function walk_async(root, rules, on_done)
  local files, dirs = {}, {}
  local iter = vim.fs.dir(root, {
    depth = 20,
    skip = function(relpath)
      if SKIP_DIRS[vim.fs.basename(relpath)] then
        return false
      end
      return not is_ignored(rules, relpath, true)
    end,
  })
  local function step()
    for _ = 1, CHUNK do
      local name, kind = iter()
      if name == nil or (#files + #dirs) >= MAX_ENTRIES then
        on_done(files, dirs)
        return
      end
      if kind == 'directory' then
        if not SKIP_DIRS[vim.fs.basename(name)] and not is_ignored(rules, name, true) then
          dirs[#dirs + 1] = name
        end
      elseif kind == 'file' and not is_ignored(rules, name, false) then
        files[#files + 1] = name
      end
    end
    vim.schedule(step)
  end
  step()
end

--- Rebuilds the cache for `root`. Safe to call while a fetch for the same
--- root is already in flight — the second call is a no-op, not a second walk.
--- @param root string absolute project root
--- @param on_done fun()|nil called once the cache is ready
function M.refresh(root, on_done)
  assert(type(root) == 'string' and vim.startswith(root, '/'), 'completion.refresh needs an absolute root')
  if cache[root] == 'loading' then
    return
  end
  cache[root] = 'loading'
  walk_async(root, load_gitignore(root), function(files, dirs)
    table.sort(files)
    table.sort(dirs)
    cache[root] = { files = files, dirs = dirs }
    if on_done ~= nil then
      on_done()
    end
  end)
end

--- Whether `root` has a ready cache — never triggers a fetch itself.
--- @param root string
--- @return boolean
function M.ready(root)
  return type(cache[root]) == 'table'
end

--- Test hook: drops whatever is cached for `root`.
--- @param root string
function M.invalidate(root)
  cache[root] = nil
end

--- Candidates for `prefix` (the text typed after `@`), from whatever is
--- cached for `root` right now. Never fetches, never blocks — directories
--- first, each with a trailing `/` so a reader can tell them from files.
--- @param root string
--- @param prefix string
--- @return string[]
function M.candidates(root, prefix)
  assert(type(prefix) == 'string', 'completion.candidates needs a prefix string')
  local entry = cache[root]
  if type(entry) ~= 'table' then
    return {}
  end
  local out = {}
  for _, path in ipairs(entry.dirs) do
    if #out >= MAX_SHOWN then
      return out
    end
    if vim.startswith(path, prefix) then
      out[#out + 1] = path .. '/'
    end
  end
  for _, path in ipairs(entry.files) do
    if #out >= MAX_SHOWN then
      return out
    end
    if vim.startswith(path, prefix) then
      out[#out + 1] = path
    end
  end
  return out
end

--- Where `@path` completion should start on `line` at 0-based cursor `col`,
--- or -1 when the cursor is not right after a `@` reference — including an
--- email address, where `@` does not start a word (the same rule
--- `context.expand` applies to an already-typed token).
--- @param line string
--- @param col integer 0-based byte column
--- @return integer
function M.start_col(line, col)
  assert(type(line) == 'string', 'completion.start_col needs a line')
  assert(type(col) == 'number' and col >= 0, 'completion.start_col needs a non-negative column')
  local before = line:sub(1, col)
  local at = before:find('@[%w%._%-~/]*$')
  if at == nil then
    return -1
  end
  local preceding = before:sub(at - 1, at - 1)
  if preceding:match('[%w%.]') ~= nil then
    return -1
  end
  return at
end

--- The buffer's `completefunc`/`omnifunc`. Scoped to the root the panel
--- captured for this buffer (`vim.b.nvime_root`) rather than re-derived from
--- the prompt buffer's own path, which is not a real one.
--- @param findstart integer
--- @param base string
--- @return integer|string[]
function M.completefunc(findstart, base)
  local root = vim.b.nvime_root
  if type(root) ~= 'string' then
    return findstart == 1 and -1 or {}
  end
  if findstart == 1 then
    return M.start_col(vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)[2])
  end
  if not M.ready(root) then
    M.refresh(root)
    return {}
  end
  return M.candidates(root, base)
end

return M
