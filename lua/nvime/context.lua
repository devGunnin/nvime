--- Deliberate context: `@file` / `@dir` tokens in a prompt, and the visual
--- selection. Reads are bounded so a stray `@/` can never stall the editor or
--- blow the request up; anything skipped is reported rather than dropped.
local config = require('nvime.config')

local M = {}

local SKIP_DIRS = { ['.git'] = true, ['node_modules'] = true, ['.venv'] = true, ['target'] = true }

--- Project root for the current buffer: the enclosing git repo, else the cwd.
function M.project_root()
  local start = vim.api.nvim_buf_get_name(0)
  if start == '' then
    start = vim.uv.cwd()
  end
  local root = vim.fs.root(start, { '.git' })
  return vim.fs.normalize(root or vim.uv.cwd())
end

local function resolve(token, root)
  local path = vim.fs.normalize(vim.fn.expand(token))
  if not vim.startswith(path, '/') then
    path = vim.fs.normalize(root .. '/' .. path)
  end
  return path
end

--- Reads raw bytes, never `readfile`: readfile turns every NUL into a newline,
--- so the binary check has to happen before any decoding.
local function read_file(path, stat, limits)
  if stat.size > limits.max_file_bytes then
    return nil, string.format('%s is %d bytes, over the %d byte limit', path, stat.size, limits.max_file_bytes)
  end
  local handle, open_err = io.open(path, 'rb')
  if handle == nil then
    return nil, string.format('could not read %s (%s)', path, tostring(open_err))
  end
  local raw = handle:read(limits.max_file_bytes)
  handle:close()
  raw = raw or ''
  if raw:find('\0', 1, true) ~= nil then
    return nil, string.format('%s looks binary', path)
  end
  -- Drop the trailing newline only; the rest stays byte-faithful.
  local text = (raw:gsub('\n$', ''))
  return { type = 'file', path = path, text = text }, nil
end

local function list_dir(path, limits)
  local entries = {}
  local iter = vim.fs.dir(path, {
    depth = 3,
    skip = function(name)
      return not SKIP_DIRS[name]
    end,
  })
  for name, kind in iter do
    if #entries >= limits.max_dir_entries then
      break
    end
    entries[#entries + 1] = kind == 'directory' and (name .. '/') or name
  end
  if #entries == 0 then
    return nil, string.format('%s is empty', path)
  end
  table.sort(entries)
  return { type = 'dir', path = path, entries = entries }, nil
end

--- Expands every `@path` token in `prompt` into a context block.
--- The tokens stay in the prompt text so the model sees what was referenced.
--- `root` is passed in, never recomputed: the caller sends the same root to the
--- sidecar, and the prompt buffer is not a real path so it cannot supply one.
--- @param prompt string
--- @param root string absolute project root relative `@paths` resolve against
--- @return table[] blocks
--- @return string[] warnings for tokens that could not be attached
function M.expand(prompt, root)
  assert(type(prompt) == 'string', 'context.expand needs a prompt string')
  assert(type(root) == 'string' and vim.startswith(root, '/'), 'context.expand needs an absolute root')
  local limits = config.get().context
  local blocks, warnings, seen = {}, {}, {}

  for at, token in prompt:gmatch('()@([%w%._%-~/]+)') do
    local before = prompt:sub(at - 1, at - 1)
    local path = resolve(token, root)
    -- `foo@bar.com` is an address, not a reference: `@` must start a word.
    if before:match('[%w%.]') == nil and not seen[path] then
      seen[path] = true
      local stat = vim.uv.fs_stat(path)
      if stat == nil then
        warnings[#warnings + 1] = string.format('@%s did not resolve to a file or directory', token)
      else
        local block, err
        if stat.type == 'directory' then
          block, err = list_dir(path, limits)
        else
          block, err = read_file(path, stat, limits)
        end
        if block ~= nil then
          blocks[#blocks + 1] = block
        else
          warnings[#warnings + 1] = err
        end
      end
    end
  end
  return blocks, warnings
end

--- The active visual selection as a context block, or nil outside visual mode.
--- Reads the live visual marks, so it works from inside the mapping itself.
--- @return table|nil block
function M.selection()
  local anchor = vim.fn.getpos('v')
  local cursor = vim.fn.getpos('.')
  local first, last = anchor[2], cursor[2]
  if first > last then
    first, last = last, first
  end
  if first < 1 then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(0, first - 1, last, false)
  if #lines == 0 then
    return nil
  end
  local path = vim.api.nvim_buf_get_name(0)
  return {
    type = 'selection',
    path = path ~= '' and vim.fs.normalize(path) or M.project_root() .. '/[No Name]',
    startLine = first,
    endLine = last,
    text = table.concat(lines, '\n'),
  }
end

return M
