--- Colours come from the active colorscheme, so nvime always looks native.
--- The fallback table below is the only hardcoded colour in the plugin.
local M = {}

--- Used only when a colorscheme defines none of the groups we read.
local FALLBACK = {
  fg = '#d5d9e4',
  dim = '#8b91a5',
  accent = '#e8b45a',
  agent = '#7aa7d9',
  session = '#b294c9',
  error = '#de7681',
  code_bg = nil,
  add_bg = '#1f3326',
  change_bg = '#26303f',
  delete_bg = '#3a2226',
  fade_bg = '#22242b',
}

--- First group in `names` that defines `attr`, as a "#rrggbb" string.
local function pick(names, attr)
  for _, name in ipairs(names) do
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
    if ok and type(hl[attr]) == 'number' then
      return string.format('#%06x', hl[attr])
    end
  end
  return nil
end

--- Resolves the palette from the current colorscheme.
--- @return table<string,string|nil>
function M.resolve()
  return {
    fg = pick({ 'Normal' }, 'fg') or FALLBACK.fg,
    dim = pick({ 'Comment', 'NonText' }, 'fg') or FALLBACK.dim,
    accent = pick({ 'DiagnosticWarn', 'Title', 'Special' }, 'fg') or FALLBACK.accent,
    agent = pick({ 'DiagnosticInfo', 'Function', 'DiffChange' }, 'fg') or FALLBACK.agent,
    session = pick({ 'DiagnosticHint', 'Identifier', 'DiffAdd' }, 'fg') or FALLBACK.session,
    error = pick({ 'DiagnosticError', 'ErrorMsg', 'DiffDelete' }, 'fg') or FALLBACK.error,
    code = pick({ 'String', 'Constant' }, 'fg') or FALLBACK.fg,
    code_bg = pick({ 'CursorLine', 'ColorColumn' }, 'bg') or FALLBACK.code_bg,
    -- Hunk backgrounds come from the colorscheme's own diff groups, so a live
    -- edit reads the same as `:diffthis` does in that theme.
    add_bg = pick({ 'DiffAdd', 'DiffAdded' }, 'bg') or FALLBACK.add_bg,
    change_bg = pick({ 'DiffChange', 'DiffText' }, 'bg') or FALLBACK.change_bg,
    delete_bg = pick({ 'DiffDelete', 'DiffRemoved' }, 'bg') or FALLBACK.delete_bg,
    fade_bg = pick({ 'CursorLine', 'ColorColumn' }, 'bg') or FALLBACK.fade_bg,
  }
end

--- nvime's own highlight groups, defined from the resolved palette.
local function groups(p)
  return {
    NvimeUser = { fg = p.accent, bold = true },
    NvimeAgent = { fg = p.agent, bold = true },
    NvimeHeading = { fg = p.accent, bold = true },
    NvimeCode = { fg = p.code, bg = p.code_bg },
    NvimeFence = { fg = p.dim },
    NvimeInlineCode = { fg = p.code },
    NvimeBold = { bold = true },
    NvimeItalic = { italic = true },
    NvimeDim = { fg = p.dim },
    NvimeActivity = { fg = p.session },
    NvimeError = { fg = p.error },
    NvimeSession = { fg = p.session },
    NvimeSelected = { fg = p.accent, bold = true },
    -- Big change review: the chip a thread carries in the list.
    NvimeThreadDefend = { fg = p.error, bold = true },
    NvimeThreadClear = { fg = p.session, bold = true },
    NvimeThreadAuto = { fg = p.dim },
    NvimeThreadOpen = { fg = p.accent, bold = true },
    -- Live edit: a fresh hunk, then the dimmer group it fades through.
    NvimeEditAdd = { bg = p.add_bg },
    NvimeEditChange = { bg = p.change_bg },
    NvimeEditDelete = { bg = p.delete_bg },
    NvimeEditFade = { bg = p.fade_bg },
  }
end

--- (Re)defines nvime's highlight groups from the active colorscheme.
function M.apply()
  local palette = M.resolve()
  for name, spec in pairs(groups(palette)) do
    vim.api.nvim_set_hl(0, name, spec)
  end
  return palette
end

--- Re-resolves on every colorscheme change; safe to call more than once.
function M.attach()
  local group = vim.api.nvim_create_augroup('NvimePalette', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    desc = 'nvime: re-resolve the palette from the new colorscheme',
    callback = function()
      M.apply()
    end,
  })
  return M.apply()
end

M.FALLBACK = FALLBACK

return M
