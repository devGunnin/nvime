--- `@file`/`@dir` completion for prompt buffers. One cache per project root,
--- built by walking the tree with `vim.fs.dir` and dropping whatever
--- `.gitignore` excludes — the root file and any nested ones — never a
--- shell-out to git, which stays the sidecar's job. The walk is chunked
--- across scheduled steps and capped, so typing `@` in a huge repo never
--- blocks the editor.
local M = {}

--- Entries kept per root. Past this the walk stops rather than growing
--- unbounded on a repo with a very deep or very wide tree. Measured at ~0.7
--- microseconds per entry (6000-file fixture, 4ms full walk), so this is
--- still comfortably non-blocking even fully spent.
local MAX_ENTRIES = 20000

--- Rows offered per completion popup. The cache can hold far more than this.
local MAX_SHOWN = 50

--- Directories the walk never descends into, checked by basename at every
--- depth — the same scope `context.lua`'s own directory skip-list has.
local SKIP_DIRS = { ['.git'] = true, ['node_modules'] = true, ['.venv'] = true, ['target'] = true }

--- How many filesystem entries one scheduled step processes before yielding
--- back to the event loop.
local CHUNK = 200

--- root -> { files = string[], dirs = string[], truncated = boolean } | 'loading'
local cache = {}

--- One gitignore glob SEGMENT (no `/` of its own) translated to a Lua
--- pattern: `*` -> any run of characters, `?` -> one character, `[...]` -> a
--- Lua character class (a leading `!` negates, matching git's `[!...]`),
--- everything else literal.
--- @param segment string
--- @return string
local function segment_to_pattern(segment)
  local out = { '^' }
  local i, n = 1, #segment
  while i <= n do
    local char = segment:sub(i, i)
    if char == '*' then
      out[#out + 1] = '.*'
      i = i + 1
    elseif char == '?' then
      out[#out + 1] = '.'
      i = i + 1
    elseif char == '[' then
      local close = segment:find(']', i + 1, true)
      if close == nil then
        -- No matching `]`: git treats a malformed class as a literal `[`.
        out[#out + 1] = '%['
        i = i + 1
      else
        local body = segment:sub(i + 1, close - 1)
        if vim.startswith(body, '!') then
          body = '^' .. body:sub(2)
        end
        out[#out + 1] = '[' .. (body:gsub('%%', '%%%%')) .. ']'
        i = close + 1
      end
    elseif char:match('%p') ~= nil then
      out[#out + 1] = '%' .. char
      i = i + 1
    else
      out[#out + 1] = char
      i = i + 1
    end
  end
  out[#out + 1] = '$'
  return table.concat(out)
end

--- Reads one directory's own `.gitignore` into match rules. `dir` is the
--- absolute directory holding it.
--- @param dir string
--- @return table[] each { negate, dir_only, anchored, segments|basename_pattern }
local function load_gitignore(dir)
  local handle = io.open(dir .. '/.gitignore', 'rb')
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
      local rule = { negate = negate, dir_only = dir_only }
      -- A pattern with an internal `/` is anchored to this .gitignore's own
      -- directory even without a leading `/`, exactly as git anchors it.
      if anchored or trimmed:find('/', 1, true) ~= nil then
        rule.anchored = true
        local segments = {}
        for _, seg in ipairs(vim.split(trimmed, '/', { plain = true })) do
          segments[#segments + 1] = seg == '**' and '**' or segment_to_pattern(seg)
        end
        rule.segments = segments
      else
        rule.anchored = false
        rule.basename_pattern = segment_to_pattern(trimmed)
      end
      rules[#rules + 1] = rule
    end
  end
  return rules
end

--- Whether `pattern_segs[pi..]` matches `path_segs[si..]`. A `**` segment
--- matches zero or more path segments — tried greedily-to-none, since a
--- pattern this short (a handful of rules, shallow trees) never needs more.
--- @param pattern_segs table
--- @param pi integer
--- @param path_segs table
--- @param si integer
--- @return boolean
local function segments_match(pattern_segs, pi, path_segs, si)
  while pi <= #pattern_segs do
    local seg = pattern_segs[pi]
    if seg == '**' then
      if pi == #pattern_segs then
        return true
      end
      for skip = si, #path_segs + 1 do
        if segments_match(pattern_segs, pi + 1, path_segs, skip) then
          return true
        end
      end
      return false
    end
    if si > #path_segs or path_segs[si]:match(seg) == nil then
      return false
    end
    pi = pi + 1
    si = si + 1
  end
  return si > #path_segs
end

--- Whether one rule matches `local_path` — relative to the `.gitignore`
--- directory that owns the rule, no leading `/`.
--- @param rule table
--- @param local_path string
--- @return boolean
local function rule_matches(rule, local_path)
  if not rule.anchored then
    return vim.fs.basename(local_path):match(rule.basename_pattern) ~= nil
  end
  local path_segs = vim.split(local_path, '/', { plain = true })
  return segments_match(rule.segments, 1, path_segs, 1)
end

--- `relpath` (root-relative) expressed relative to `base` (also
--- root-relative, `''` meaning the root itself) — nil when `relpath` is not
--- under `base` at all.
--- @param base string
--- @param relpath string
--- @return string|nil
local function relative_to(base, relpath)
  if base == '' then
    return relpath
  end
  if relpath == base then
    return ''
  end
  local prefix = base .. '/'
  if vim.startswith(relpath, prefix) then
    return relpath:sub(#prefix + 1)
  end
  return nil
end

--- Whether `relpath` is ignored by any rule in `chain` — a list of `{ base,
--- rules }` scopes ordered root-first. Rules apply in that order, so a
--- negation in a DEEPER `.gitignore` can override an ignore from a shallower
--- one, exactly as git resolves nested `.gitignore` files.
--- @param chain table[]
--- @param relpath string
--- @param is_dir boolean
--- @return boolean
local function is_ignored(chain, relpath, is_dir)
  local ignored = false
  for _, scope in ipairs(chain) do
    local local_path = relative_to(scope.base, relpath)
    if local_path ~= nil and local_path ~= '' then
      for _, rule in ipairs(scope.rules) do
        if (is_dir or not rule.dir_only) and rule_matches(rule, local_path) then
          ignored = not rule.negate
        end
      end
    end
  end
  return ignored
end

--- The root-relative parent directory of `relpath` (`''` for a top-level
--- entry).
--- @param relpath string
--- @return string
local function parent_of(relpath)
  local at = relpath:match('()/[^/]*$')
  if at == nil then
    return ''
  end
  return relpath:sub(1, at - 1)
end

--- The rule chain applicable to everything directly inside `dir_relpath`
--- (`''` for the root) — its ancestors' rules, then its own if it has a
--- `.gitignore`. Memoized in `built`, keyed by directory, so a repo with many
--- files but few directories loads each `.gitignore` at most once.
--- @param root string
--- @param built table<string, table[]>
--- @param dir_relpath string
--- @return table[]
local function chain_for(root, built, dir_relpath)
  local cached = built[dir_relpath]
  if cached ~= nil then
    return cached
  end
  local parent_chain = dir_relpath == '' and {} or chain_for(root, built, parent_of(dir_relpath))
  local abs = dir_relpath == '' and root or (root .. '/' .. dir_relpath)
  local own = load_gitignore(abs)
  local chain = parent_chain
  if #own > 0 then
    chain = {}
    for i, scope in ipairs(parent_chain) do
      chain[i] = scope
    end
    chain[#chain + 1] = { base = dir_relpath, rules = own }
  end
  built[dir_relpath] = chain
  return chain
end

--- Walks `root`, a few hundred entries per scheduled step, honoring every
--- applicable `.gitignore` (root and nested) and `SKIP_DIRS`. `on_done(files,
--- dirs, truncated)` runs exactly once, whatever stopped the walk — reaching
--- the end, or `MAX_ENTRIES`.
--- @param root string
--- @param on_done fun(files: string[], dirs: string[], truncated: boolean)
local function walk_async(root, on_done)
  local files, dirs = {}, {}
  local built = {}
  local iter = vim.fs.dir(root, {
    depth = 20,
    skip = function(relpath)
      if SKIP_DIRS[vim.fs.basename(relpath)] then
        return false
      end
      local chain = chain_for(root, built, parent_of(relpath))
      return not is_ignored(chain, relpath, true)
    end,
  })
  local function step()
    for _ = 1, CHUNK do
      local name, kind = iter()
      if name == nil then
        on_done(files, dirs, false)
        return
      end
      if (#files + #dirs) >= MAX_ENTRIES then
        on_done(files, dirs, true)
        return
      end
      local chain = chain_for(root, built, parent_of(name))
      if kind == 'directory' then
        if not SKIP_DIRS[vim.fs.basename(name)] and not is_ignored(chain, name, true) then
          dirs[#dirs + 1] = name
        end
      elseif kind == 'file' and not is_ignored(chain, name, false) then
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
  walk_async(root, function(files, dirs, truncated)
    table.sort(files)
    table.sort(dirs)
    cache[root] = { files = files, dirs = dirs, truncated = truncated }
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

--- One non-selectable completion row noting how many matches were left out —
--- past `MAX_SHOWN` for this prefix, or because the walk itself hit
--- `MAX_ENTRIES` before finishing the tree. `empty = 1` is required or Vim
--- drops a `word = ''` item outright; `dup = 1` keeps it from being folded
--- into a real entry that happens to share the empty word.
--- @param hidden integer matches past MAX_SHOWN for this prefix, or 0
--- @param walk_truncated boolean the cached listing itself is incomplete
--- @return table|nil
local function truncation_notice(hidden, walk_truncated)
  local parts = {}
  if hidden > 0 then
    parts[#parts + 1] = string.format('+%d more — narrow the prefix', hidden)
  end
  if walk_truncated then
    parts[#parts + 1] = 'project listing truncated — some files are not offered'
  end
  if #parts == 0 then
    return nil
  end
  return { word = '', abbr = table.concat(parts, '; '), empty = 1, dup = 1 }
end

--- Candidates for `prefix` (the text typed after `@`), from whatever is
--- cached for `root` right now. Never fetches, never blocks — directories
--- and files are interleaved by budget so neither can starve the other, each
--- directory with a trailing `/` so a reader can tell them from files.
--- @param root string
--- @param prefix string
--- @return table[] strings, or a trailing notice dict when something is hidden
function M.candidates(root, prefix)
  assert(type(prefix) == 'string', 'completion.candidates needs a prefix string')
  local entry = cache[root]
  if type(entry) ~= 'table' then
    return {}
  end
  local matched_dirs, matched_files = {}, {}
  for _, path in ipairs(entry.dirs) do
    if vim.startswith(path, prefix) then
      matched_dirs[#matched_dirs + 1] = path .. '/'
    end
  end
  for _, path in ipairs(entry.files) do
    if vim.startswith(path, prefix) then
      matched_files[#matched_files + 1] = path
    end
  end
  -- Directories first, but capped so files still get a share of MAX_SHOWN
  -- even in a repo with 50+ matching directories at the top level.
  local dir_budget = math.min(#matched_dirs, math.ceil(MAX_SHOWN / 2))
  local file_budget = MAX_SHOWN - dir_budget
  if #matched_files < file_budget then
    dir_budget = math.min(#matched_dirs, MAX_SHOWN - #matched_files)
  end
  local out = {}
  for i = 1, math.min(dir_budget, #matched_dirs) do
    out[#out + 1] = matched_dirs[i]
  end
  for i = 1, math.min(MAX_SHOWN - #out, #matched_files) do
    out[#out + 1] = matched_files[i]
  end
  local hidden = (#matched_dirs + #matched_files) - #out
  local notice = truncation_notice(hidden, entry.truncated)
  if notice ~= nil then
    out[#out + 1] = notice
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
--- @return integer|table
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
