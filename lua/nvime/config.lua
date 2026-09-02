local M = {}

--- The gate's difficulty dial. The sidecar owns the thresholds these name;
--- this list is only what a user may write in `setup`.
M.DIFFICULTIES = { 'vibe', 'easy', 'medium', 'extreme' }

--- The glyph sets `nvime.icons` can draw from.
M.ICON_SETS = { 'unicode', 'ascii' }

--- Reasoning-effort levels a `models.*` lane may name. The SDK also accepts
--- 'xhigh'/'max'; nvime's config and `:Nvime model` picker offer only these.
M.EFFORTS = { 'low', 'medium', 'high' }

--- The per-mode dials `models.*` covers, and the lanes `:Nvime model` offers.
M.MODEL_LANES = { 'chat', 'edit', 'big_build', 'big_intake', 'big_triage', 'big_grade', 'explain' }

--- What opening chat with no prior selection does: start clean, or pick this
--- project's last conversation back up.
M.CHAT_DEFAULTS = { 'new', 'resume-last' }

--- Lanes whose output the comprehension gate depends on: they may never run
--- at effort 'low', and their configured effort never falls back to nil —
--- see `validate()` and the `models` defaults below.
M.GATE_LANES = { 'big_triage', 'big_grade' }

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
  chat = {
    -- 'new': opening chat always starts a fresh conversation; past ones are
    -- still reachable through <C-r>. 'resume-last': pick this project's most
    -- recent conversation back up on open.
    default = 'new',
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
    -- Deadline for control requests. A streaming turn is exempt: it is bounded
    -- by the user's stop key, not a timer.
    request_timeout_ms = 15000,
  },
  -- Per-mode model + reasoning-effort overrides, threaded into every agent
  -- turn that mode runs. `model` nil means the CLI's own default;
  -- `:Nvime model` layers a session-scoped override on top of these.
  models = {
    chat = { model = nil, effort = nil },
    edit = { model = nil, effort = nil },
    big_build = { model = nil, effort = nil },
    big_intake = { model = nil, effort = nil },
    -- Triage decides what the gate reviews, and grading IS the gate; neither
    -- may run at effort 'low' (validated below, and enforced again in
    -- `nvime.models`), and neither defaults to nil — an unset gate effort
    -- must never silently inherit an ambient one, so it names 'medium'.
    big_triage = { model = nil, effort = 'medium' },
    big_grade = { model = nil, effort = 'medium' },
    explain = { model = nil, effort = nil },
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
  organization = {
    -- Paid enforcement stays opt-in for the community plugin. A managed
    -- deployment supplies both the service and its native signing binary.
    control_plane_url = nil,
    trust_core = nil,
    github = 'gh',
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

local function validate_organization(opts)
  check_type(opts.organization, 'table', 'organization')
  local endpoint = opts.organization.control_plane_url
  local trust = opts.organization.trust_core
  if endpoint == nil and trust == nil then
    check_type(opts.organization.github, 'string', 'organization.github')
    return
  end
  if endpoint == nil or trust == nil then
    fail('organization.control_plane_url and organization.trust_core must be configured together')
  end
  check_type(endpoint, 'string', 'organization.control_plane_url')
  check_type(trust, 'string', 'organization.trust_core')
  check_type(opts.organization.github, 'string', 'organization.github')
  if endpoint == '' or trust == '' or opts.organization.github == '' then
    fail('organization settings must not be empty')
  end
  if
    not endpoint:match('^https://')
    and not endpoint:match('^http://localhost[:/]')
    and not endpoint:match('^http://127%.0%.0%.1[:/]')
  then
    fail('organization.control_plane_url must use HTTPS or loopback HTTP')
  end
end

--- Keys `setup()` accepts that the defaults table cannot show: a nil default
--- does not exist in a Lua table, and `agent.model` is retired but must reach
--- `validate`, which explains where it went.
local function optional_keys()
  local allowed = {
    ['agent.claude'] = true,
    ['agent.model'] = true,
    ['organization.control_plane_url'] = true,
    ['organization.trust_core'] = true,
  }
  for _, lane in ipairs(M.MODEL_LANES) do
    allowed['models.' .. lane .. '.model'] = true
    allowed['models.' .. lane .. '.effort'] = true
  end
  return allowed
end

--- Rejects a key the defaults do not name, at every nesting level, with the
--- path the user wrote. A misspelt key is the most common config mistake there
--- is, and a silently ignored `pannel` block gives no signal at all.
--- @param user table the user's own table, never the merged one
--- @param known table the defaults at this level
--- @param path string dotted path of `user`, '' at the top
--- @param allowed table paths valid despite having no default
local function check_keys(user, known, path, allowed)
  for key, value in pairs(user) do
    local full = path == '' and tostring(key) or (path .. '.' .. tostring(key))
    local default = known[key]
    if default == nil and not allowed[full] then
      fail(string.format('unknown option %s', full))
    end
    if type(default) == 'table' and type(value) == 'table' then
      check_keys(value, default, full, allowed)
    end
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
  check_type(opts.chat.default, 'string', 'chat.default')
  if not vim.tbl_contains(M.CHAT_DEFAULTS, opts.chat.default) then
    fail('chat.default must be one of: ' .. table.concat(M.CHAT_DEFAULTS, ', '))
  end
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
  -- Expanded here so `~/...` reaches the spawn as a real path; the spawn takes
  -- the string verbatim.
  opts.agent.node = vim.fn.expand(opts.agent.node)
  -- A warning, never a failure: this is the one check that reads the machine,
  -- and a GUI Neovim started without the shell's PATH would otherwise have its
  -- whole nvime config rejected — along with the `:Nvime doctor` built to
  -- explain exactly this. Doctor and the spawn stay the authority.
  if vim.fn.executable(opts.agent.node) ~= 1 then
    vim.notify(
      'nvime: agent.node is not executable: ' .. opts.agent.node .. ' — run :Nvime doctor',
      vim.log.levels.WARN
    )
  end
  if opts.agent.model ~= nil then
    fail('agent.model was replaced by models.<lane>.model — see :h nvime-configuration')
  end
  if opts.agent.claude ~= nil then
    check_type(opts.agent.claude, 'string', 'agent.claude')
  end
  check_type(opts.agent.request_timeout_ms, 'number', 'agent.request_timeout_ms')
  if opts.agent.request_timeout_ms < 1000 then
    fail('agent.request_timeout_ms must be at least 1000')
  end
  check_type(opts.models, 'table', 'models')
  for _, lane in ipairs(M.MODEL_LANES) do
    local dial = opts.models[lane]
    check_type(dial, 'table', 'models.' .. lane)
    if dial.model ~= nil then
      check_type(dial.model, 'string', 'models.' .. lane .. '.model')
    end
    if dial.effort ~= nil then
      check_type(dial.effort, 'string', 'models.' .. lane .. '.effort')
      if not vim.tbl_contains(M.EFFORTS, dial.effort) then
        fail('models.' .. lane .. '.effort must be one of: ' .. table.concat(M.EFFORTS, ', '))
      end
    end
  end
  for _, lane in ipairs(M.GATE_LANES) do
    if opts.models[lane].effort == 'low' then
      fail(
        'models.'
          .. lane
          .. '.effort may not be low — it feeds the comprehension gate '
          .. 'and never runs at the shallowest effort'
      )
    end
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
  validate_organization(opts)
  return opts
end

--- Merges `user` over the defaults, validates, and installs the result.
function M.setup(user)
  if user ~= nil and type(user) ~= 'table' then
    fail('expected a table of options, got ' .. type(user))
  end
  check_keys(user or {}, defaults, '', optional_keys())
  options = validate(vim.tbl_deep_extend('force', vim.deepcopy(defaults), user or {}))
  return options
end

function M.get()
  return options
end

M.defaults = defaults

return M
