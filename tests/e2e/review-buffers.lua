--- The review pane, end to end against the real agent: build a change, open
--- the review tab on it, and prove the pane is the REAL FILE — the clone's own
--- path, a normal buffer the filetype/treesitter/LSP pipeline attaches to, with
--- the diff laid over it as marks rather than baked into the text.
local lib = dofile(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)) .. '/lib.lua')

local repo = assert(vim.env.NVIME_E2E_REPO, 'NVIME_E2E_REPO names the scratch repo')
local model = vim.env.NVIME_E2E_MODEL
local threads = require('nvime.threads')
local reviewbuf = require('nvime.reviewbuf')

--- Stands in for the reader's own config: nothing in stock Neovim starts
--- treesitter highlighting on its own, so the smoke opts in the way a user
--- does — on FileType. Whether it takes hold is the thing being measured.
vim.api.nvim_create_autocmd('FileType', {
  pattern = 'lua',
  callback = function(event)
    pcall(vim.treesitter.start, event.buf)
  end,
})

local function press(buf, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
    if map.lhs == lhs and map.callback ~= nil then
      map.callback()
      return
    end
  end
  lib.die('the review tab has no ' .. lhs .. ' mapping')
end

local function pane_buf()
  local win = threads.view().pane_win
  if win == nil or not vim.api.nvim_win_is_valid(win) then
    lib.die('the review pane is not open')
  end
  return vim.api.nvim_win_get_buf(win)
end

--- The treesitter captures on the first non-blank code row of `buf`, which is
--- what a colorscheme paints from. Empty means no highlighting at all.
local function captures(buf)
  if vim.treesitter.highlighter.active[buf] == nil then
    return nil
  end
  -- Headless never redraws, so nothing parses lazily; a real editor gets this
  -- for free on the first paint.
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or parser == nil then
    return nil
  end
  parser:parse(true)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for row, line in ipairs(lines) do
    local col = line:find('%S')
    if col ~= nil and #line > 4 then
      local found = vim.treesitter.get_captures_at_pos(buf, row - 1, col - 1)
      local names = {}
      for _, capture in ipairs(found) do
        names[#names + 1] = capture.capture
      end
      if #names > 0 then
        return string.format('%d:%d %s | %s', row, col, table.concat(names, ','), line)
      end
    end
  end
  return nil
end

--- Everything the review drew over the file, counted by kind.
local function annotations(buf)
  local bands, virtual = 0, 0
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, reviewbuf.NS, 0, -1, { details = true })) do
    if mark[4].line_hl_group ~= nil then
      bands = bands + 1
    end
    virtual = virtual + #(mark[4].virt_lines or {})
  end
  return bands, virtual
end

local created = lib.call('big.create', { root = repo, title = 'add a jitter helper', difficulty = 'vibe' }, 60000)
local id = created.session.id
lib.say('SESSION ' .. id)

lib.call('big.intake', {
  root = repo,
  sessionId = id,
  message = table.concat({
    'In pool.lua, add a next_delay(attempt) function returning a jittered exponential backoff,',
    'and change connect() to use it. Keep it to pool.lua.',
    'The spec is ready as written — answer with it and do not ask further questions.',
  }, ' '),
  model = model,
}, 600000)

lib.call('big.approve', { root = repo, sessionId = id }, 120000)
local built = lib.call('big.build', { root = repo, sessionId = id, model = model, triageModel = model }, 1800000)
lib.say('BUILT ' .. built.session.display .. ' threads=' .. tostring(built.session.counts.total))
if not built.session.hasDiff then
  lib.die('the build captured no diff to review')
end

threads.open(repo, built.session)
if not vim.wait(10000, function()
  return threads.view().showing ~= nil
end, 100) then
  lib.die('the review pane never rendered')
end

local buf = pane_buf()
local name = vim.api.nvim_buf_get_name(buf)
lib.say(string.format('PANE showing=%s file=%q', tostring(threads.view().showing), name))
if threads.view().showing ~= 'file' then
  lib.die('the pane did not open on the real file')
end
if not vim.startswith(name, built.session.worktree.path .. '/') then
  lib.die('the pane is not reading the build clone: ' .. name)
end
if vim.fn.filereadable(name) ~= 1 then
  lib.die('the pane buffer is not a readable file on disk')
end
lib.say(
  string.format(
    'BUFFER filetype=%s buftype=%q modifiable=%s listed=%s',
    vim.bo[buf].filetype,
    vim.bo[buf].buftype,
    tostring(vim.bo[buf].modifiable),
    tostring(vim.bo[buf].buflisted)
  )
)
if vim.bo[buf].buftype ~= '' or vim.bo[buf].modifiable then
  lib.die('the pane is not a normal, read-only file buffer')
end

local shown = captures(buf)
if shown == nil then
  lib.die('treesitter painted nothing on the pane — there is no highlighting')
end
lib.say('TREESITTER ' .. shown)

local bands, virtual = annotations(buf)
lib.say(string.format('MARKS bands=%d virtual_lines=%d', bands, virtual))
if bands == 0 and virtual == 0 then
  lib.die('the diff left no annotation on the file')
end
if
  vim.iter(vim.api.nvim_buf_get_lines(buf, 0, -1, false)):any(function(line)
    return line:sub(1, 3) == '@@ ' or line:sub(1, 4) == '--- '
  end)
then
  lib.die('diff text leaked into the buffer — treesitter is reading a rendering')
end

-- `:LspInfo`-level attachment: a real server if the host has one, otherwise the
-- honest weaker claim — this is an ordinary file buffer a server would attach
-- to. No server is installed for the smoke.
if vim.fn.executable('lua-language-server') == 1 then
  local client = vim.lsp.start({
    name = 'nvime-e2e',
    cmd = { 'lua-language-server' },
    root_dir = built.session.worktree.path,
  }, { bufnr = buf })
  local attached = client ~= nil
    and vim.wait(30000, function()
      return #vim.lsp.get_clients({ bufnr = buf }) > 0
    end, 200)
  if not attached then
    lib.die('lua-language-server is installed but would not attach to the pane')
  end
  lib.say('LSP attached=' .. vim.lsp.get_clients({ bufnr = buf })[1].name)
else
  lib.say('LSP no-server-on-host; pane is a normal file buffer at ' .. name)
end

press(buf, ']c')
lib.say('HUNKS location=' .. threads.view().location .. '/' .. #threads.view().locations)

press(pane_buf(), 't')
local unified = pane_buf()
if unified ~= threads.view().pane_buf then
  lib.die('t did not fall back to the unified diff')
end
lib.say('UNIFIED lines=' .. vim.api.nvim_buf_line_count(unified))
press(unified, 't')
if vim.api.nvim_buf_get_name(pane_buf()) ~= name then
  lib.die('t did not come back to the same file')
end
lib.say('ROUNDTRIP ' .. vim.api.nvim_buf_get_name(pane_buf()))

local held = vim.tbl_values(reviewbuf.buffers())
threads.close()
for _, held_buf in ipairs(held) do
  if vim.api.nvim_buf_is_valid(held_buf) then
    lib.die('a clone buffer survived the review')
  end
end
lib.say('CLOSED wiped=' .. #held)
os.exit(0)
