--- The per-lane model + reasoning-effort dial: `config.get().models` is the
--- static default, and `:Nvime model` layers a session-scoped override on top
--- (cleared per lane back to the default with its 'reset' entry). Neither
--- table nor override ever reaches the SDK by name lookup — both are passed
--- through as plain strings, so a future model name needs no plugin change.
local compose = require('nvime.compose')
local config = require('nvime.config')
local picker = require('nvime.picker')

local M = {}

--- @type table<string, {model: string|nil, effort: string|nil}>
local overrides = {}

local function require_lane(caller, lane)
  assert(
    type(lane) == 'string' and vim.tbl_contains(config.MODEL_LANES, lane),
    caller .. ': unknown lane ' .. tostring(lane)
  )
end

--- Triage decides what the gate reviews, and grading IS the gate; running
--- either at the shallowest effort would let the gate miss what it exists to
--- catch. Mirrors the config-time refusal in `nvime.config`, so a runtime
--- override cannot do what `setup()` already refuses.
local function refuse_low_gate(lane, effort)
  if vim.tbl_contains(config.GATE_LANES, lane) and effort == 'low' then
    error(string.format("nvime: models.%s.effort may not be 'low' — it feeds the comprehension gate", lane), 0)
  end
end

--- The dial in effect for `lane`: the session override if one is set, else
--- the configured default. Always a table — an unset field just means the
--- CLI's own default, never a missing return value.
--- @param lane string
--- @return table { model: string|nil, effort: string|nil }
function M.dial(lane)
  require_lane('models.dial', lane)
  return overrides[lane] or config.get().models[lane]
end

--- Sets a session-scoped override for `lane`, layered field-by-field over the
--- configured default — only the field actually chosen replaces it. Passing
--- nil for a field means "leave it at the configured value", not "force the
--- CLI default"; `M.reset` is how a lane goes back to nothing but config.
--- @param lane string
--- @param model string|nil already-chosen model, or nil to keep the configured one
--- @param effort string|nil one of `config.EFFORTS`, or nil to keep the configured one
function M.set(lane, model, effort)
  require_lane('models.set', lane)
  if model ~= nil then
    assert(type(model) == 'string' and model ~= '', 'models.set: model must be a non-empty string or nil')
  end
  if effort ~= nil then
    assert(vim.tbl_contains(config.EFFORTS, effort), 'models.set: bad effort ' .. tostring(effort))
  end
  local configured = config.get().models[lane]
  local merged_model = model ~= nil and model or configured.model
  local merged_effort = effort ~= nil and effort or configured.effort
  refuse_low_gate(lane, merged_effort)
  overrides[lane] = { model = merged_model, effort = merged_effort }
end

--- Clears the session override for `lane`, back to its configured default.
--- @param lane string
function M.reset(lane)
  require_lane('models.reset', lane)
  overrides[lane] = nil
end

--- Whether `lane` differs from nvime's own shipped default: either the
--- user's config or a session override changed it. A gate lane's shipped
--- default effort is 'medium', never nil (see `nvime.config`) — that floor
--- is not itself a change, only picking something else is.
--- @param lane string
--- @return boolean
function M.active(lane)
  local dial = M.dial(lane)
  local shipped = config.defaults.models[lane]
  return dial.model ~= shipped.model or dial.effort ~= shipped.effort
end

--- One `<lane>:<model|->/<effort|->` entry per lane whose dial is active, in
--- `config.MODEL_LANES` order. Empty when nothing differs from nvime's own
--- shipped defaults.
--- @return string[]
function M.summary()
  local lines = {}
  for _, lane in ipairs(config.MODEL_LANES) do
    if M.active(lane) then
      local dial = M.dial(lane)
      lines[#lines + 1] = string.format('%s:%s/%s', lane, dial.model or '-', dial.effort or '-')
    end
  end
  return lines
end

--- Test hook: drops every session override.
function M.reset_all()
  overrides = {}
end

--- Derives from `config.EFFORTS` so the picker can never drift from the one
--- list nvime otherwise validates against.
local EFFORT_CHOICES = { 'default' }
for _, effort in ipairs(config.EFFORTS) do
  EFFORT_CHOICES[#EFFORT_CHOICES + 1] = effort
end

--- Step 3: pick the effort (or reset the whole override), then commit.
--- @param lane string
--- @param model string|nil already typed in the previous step
local function open_effort_step(lane, model)
  local items = { { label = 'reset — use the configured default', value = 'reset' } }
  for _, effort in ipairs(EFFORT_CHOICES) do
    if not (vim.tbl_contains(config.GATE_LANES, lane) and effort == 'low') then
      items[#items + 1] = { label = effort, value = effort }
    end
  end
  picker.open(items, {
    title = string.format(' %s effort ', lane),
    on_choice = function(choice)
      if choice == 'reset' then
        M.reset(lane)
        vim.notify('nvime: ' .. lane .. ' reset to the configured default')
        return
      end
      local effort = choice == 'default' and nil or choice
      M.set(lane, model, effort)
      vim.notify(string.format('nvime: %s now %s/%s', lane, model or 'default', effort or 'default'))
    end,
  })
end

--- Step 2: type a model id (or 'default' for the CLI default), then choose effort.
--- @param lane string
local function open_model_step(lane)
  local current = M.dial(lane)
  compose.open({
    title = string.format(' %s model ', lane),
    hint = "type a model id, or 'default' to leave it at the configured value",
    text = current.model ~= nil and { current.model } or nil,
    on_submit = function(text)
      local trimmed = vim.trim(text)
      local model = trimmed:lower() == 'default' and nil or trimmed
      open_effort_step(lane, model)
    end,
  })
end

--- `:Nvime model`: pick a lane, then type/choose its model and effort. A
--- session-scoped override on top of `models.*` from `setup()`, cleared per
--- lane with the effort step's 'reset' entry.
function M.open()
  local items = {}
  for _, lane in ipairs(config.MODEL_LANES) do
    local dial = M.dial(lane)
    local label = string.format('%-11s %s/%s', lane, dial.model or 'default', dial.effort or 'default')
    items[#items + 1] = { label = label, value = lane, lead = 12, current = M.active(lane) }
  end
  return picker.open(items, {
    title = ' nvime model ',
    on_choice = open_model_step,
  })
end

return M
