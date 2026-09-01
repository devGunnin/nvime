local M = {}

--- The gate's difficulty dial. The sidecar owns the thresholds these name;
--- this list is only what a user may write in `setup`.
M.DIFFICULTIES = { 'vibe', 'easy', 'medium', 'extreme' }

--- The glyph sets `nvime.icons` can draw from.
M.ICON_SETS = { 'unicode', 'ascii' }

--- Defaults. `setup()` deep-merges the user table over this and validates the result.
local defaults = {
  panel = {
    width = 80,
    prompt_height = 3,
    position = 'right',
  },
  ui = {
    -- Plain Unicode glyphs (no private-use Nerd Font codepoints), or ASCII for
    -- a terminal font that has neither.
    icons = 'unicode',
  },
  keymaps = {
    -- Opt-in: nvime claims no global keys until you ask it to.
    enabled = false,
    chat = '<leader>nc',
    send_selection = '<leader>ns',
    edit = '<leader>ne',
    changeset = '<leader>nd',
    big = '<leader>nB',
  },
  edit = {
    -- How long a fresh hunk stays brightly highlighted before it dims.
    fade_ms = 1500,
    -- Keep the highlight until the next change to that buffer instead.
    nofade = false,
    -- How long the sidecar holds a tool call waiting for your y/n.
    approval_timeout_ms = 60000,
  },
  big = {
    -- How hard the comprehension gate is for a new big change:
    -- vibe (no gate) / easy 40 / medium 70 / extreme 90.
    difficulty = 'medium',
    -- Throw the build clone away once the change has landed. Off by default:
    -- the clone is the only place the build's own history still exists.
    cleanup_on_merge = false,
  },
  agent = {
    node = 'node',
    -- Absolute path to the claude binary; nil resolves it from PATH.
    claude = nil,
    -- Model id passed to the SDK; nil uses the CLI default.
    model = nil,
    -- Deadline for control requests. A streaming turn is exempt: it is bounded
    -- by the user's stop key, not a timer.
    request_timeout_ms = 15000,
  },
  context = {
    max_file_bytes = 200 * 1024,
    max_dir_entries = 200,
  },
  project_instructions = {
    -- CLAUDE.md / AGENTS.md / .nvime/instructions.md, sent to chat and edit as
    -- an explicit, marked-untrusted block. Off disables reading the file at all.
    enabled = true,
  },
}

local options = vim.deepcopy(defaults)

local function fail(message)
  error('nvime.setup: ' .. message, 0)
end

local function check_type(value, expected, path)
  if type(value) ~= expected then
    fail(string.format('%s must be a %s, got %s', path, expected, type(value)))
  end
end

local function validate(opts)
  check_type(opts.panel.width, 'number', 'panel.width')
  if opts.panel.width < 20 or opts.panel.width > 400 then
    fail('panel.width must be between 20 and 400')
  end
  check_type(opts.panel.prompt_height, 'number', 'panel.prompt_height')
  if opts.panel.prompt_height < 1 or opts.panel.prompt_height > 20 then
    fail('panel.prompt_height must be between 1 and 20')
  end
  if opts.panel.position ~= 'right' and opts.panel.position ~= 'left' then
    fail("panel.position must be 'right' or 'left'")
  end
  check_type(opts.ui.icons, 'string', 'ui.icons')
  if not vim.tbl_contains(M.ICON_SETS, opts.ui.icons) then
    fail('ui.icons must be one of: ' .. table.concat(M.ICON_SETS, ', '))
  end
  check_type(opts.keymaps.enabled, 'boolean', 'keymaps.enabled')
  check_type(opts.keymaps.chat, 'string', 'keymaps.chat')
  check_type(opts.keymaps.send_selection, 'string', 'keymaps.send_selection')
  check_type(opts.keymaps.edit, 'string', 'keymaps.edit')
  check_type(opts.keymaps.changeset, 'string', 'keymaps.changeset')
  check_type(opts.keymaps.big, 'string', 'keymaps.big')
  check_type(opts.edit.fade_ms, 'number', 'edit.fade_ms')
  if opts.edit.fade_ms < 100 then
    fail('edit.fade_ms must be at least 100')
  end
  check_type(opts.edit.nofade, 'boolean', 'edit.nofade')
  check_type(opts.edit.approval_timeout_ms, 'number', 'edit.approval_timeout_ms')
  if opts.edit.approval_timeout_ms < 1000 then
    fail('edit.approval_timeout_ms must be at least 1000')
  end
  check_type(opts.big.difficulty, 'string', 'big.difficulty')
  if not vim.tbl_contains(M.DIFFICULTIES, opts.big.difficulty) then
    fail('big.difficulty must be one of: ' .. table.concat(M.DIFFICULTIES, ', '))
  end
  check_type(opts.big.cleanup_on_merge, 'boolean', 'big.cleanup_on_merge')
  check_type(opts.agent.node, 'string', 'agent.node')
  if opts.agent.claude ~= nil then
    check_type(opts.agent.claude, 'string', 'agent.claude')
  end
  if opts.agent.model ~= nil then
    check_type(opts.agent.model, 'string', 'agent.model')
  end
  check_type(opts.agent.request_timeout_ms, 'number', 'agent.request_timeout_ms')
  if opts.agent.request_timeout_ms < 1000 then
    fail('agent.request_timeout_ms must be at least 1000')
  end
  check_type(opts.context.max_file_bytes, 'number', 'context.max_file_bytes')
  if opts.context.max_file_bytes < 1024 then
    fail('context.max_file_bytes must be at least 1024')
  end
  check_type(opts.context.max_dir_entries, 'number', 'context.max_dir_entries')
  if opts.context.max_dir_entries < 1 then
    fail('context.max_dir_entries must be at least 1')
  end
  check_type(opts.project_instructions.enabled, 'boolean', 'project_instructions.enabled')
  return opts
end

--- Merges `user` over the defaults, validates, and installs the result.
function M.setup(user)
  if user ~= nil and type(user) ~= 'table' then
    fail('expected a table of options, got ' .. type(user))
  end
  options = validate(vim.tbl_deep_extend('force', vim.deepcopy(defaults), user or {}))
  return options
end

function M.get()
  return options
end

M.defaults = defaults

return M
