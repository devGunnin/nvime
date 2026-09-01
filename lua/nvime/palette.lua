--- Colours come from the active colorscheme, so nvime always looks native.
---
--- Only foregrounds are read. Every background nvime paints — chrome, badges,
--- code blocks, hunk bands — is that foreground blended into the editor's own
--- Normal background at a low alpha, so a tint is legible in a light scheme and
--- a dark one alike, and a colorscheme that leaves `DiffAdd`'s background grey
--- (nvim's own default does) still gets a green band for an added hunk.
local M = {}

--- Used only when a colorscheme defines none of the groups we read.
local FALLBACK = {
  fg = '#d5d9e4',
  bg = '#12141b',
  bg_light = '#f4f4f2',
  dim = '#8b91a5',
  accent = '#e8b45a',
  agent = '#7aa7d9',
  session = '#b294c9',
  error = '#de7681',
  ok = '#86c78c',
}

--- How far each painted background travels from Normal's toward its colour.
local ALPHA = {
  surface = 0.07,
  badge = 0.20,
  code = 0.05,
  hunk = 0.16,
  fade = 0.05,
}

--- @param hex string '#rrggbb'
--- @return integer, integer, integer
local function channels(hex)
  local value = tonumber(hex:sub(2), 16)
  return math.floor(value / 65536) % 256, math.floor(value / 256) % 256, value % 256
end

--- `colour` mixed `amount` of the way into `onto`.
--- @param colour string '#rrggbb'
--- @param onto string '#rrggbb'
--- @param amount number 0..1
--- @return string '#rrggbb'
function M.blend(colour, onto, amount)
  assert(type(colour) == 'string' and #colour == 7, 'blend needs a #rrggbb colour')
  assert(type(onto) == 'string' and #onto == 7, 'blend needs a #rrggbb base')
  assert(type(amount) == 'number' and amount >= 0 and amount <= 1, 'blend amount must be 0..1')
  local cr, cg, cb = channels(colour)
  local br, bg, bb = channels(onto)
  local function mix(a, b)
    return math.floor(b + (a - b) * amount + 0.5)
  end
  return string.format('#%02x%02x%02x', mix(cr, br), mix(cg, bg), mix(cb, bb))
end

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
--- @return table<string,string>
function M.resolve()
  local fg = pick({ 'Normal' }, 'fg') or FALLBACK.fg
  -- A cleared Normal bg is the common transparent-terminal setup. With no
  -- signal from the colorscheme itself, `&background` is the only honest
  -- guess at the terminal's polarity — a fixed dark fallback paints a light
  -- terminal's chrome near-black.
  local bg = pick({ 'Normal' }, 'bg') or (vim.o.background == 'light' and FALLBACK.bg_light or FALLBACK.bg)
  local p = {
    fg = fg,
    bg = bg,
    dim = pick({ 'Comment', 'NonText' }, 'fg') or FALLBACK.dim,
    accent = pick({ 'DiagnosticWarn', 'Title', 'Special' }, 'fg') or FALLBACK.accent,
    agent = pick({ 'DiagnosticInfo', 'Function', 'DiffChange' }, 'fg') or FALLBACK.agent,
    session = pick({ 'DiagnosticHint', 'Identifier', 'DiffAdd' }, 'fg') or FALLBACK.session,
    error = pick({ 'DiagnosticError', 'ErrorMsg' }, 'fg') or FALLBACK.error,
    -- Diff foregrounds, not backgrounds: many schemes (nvim's default among
    -- them) give the diff groups a neutral grey background that says nothing.
    added = pick({ 'Added', 'diffAdded', 'DiagnosticOk', 'String' }, 'fg') or FALLBACK.ok,
    changed = pick({ 'Changed', 'diffChanged', 'DiagnosticInfo', 'Function' }, 'fg') or FALLBACK.agent,
    removed = pick({ 'Removed', 'diffRemoved', 'DiagnosticError', 'ErrorMsg' }, 'fg') or FALLBACK.error,
    code = pick({ 'String', 'Constant' }, 'fg') or fg,
  }
  p.surface = M.blend(p.fg, bg, ALPHA.surface)
  p.code_bg = M.blend(p.fg, bg, ALPHA.code)
  p.fade_bg = M.blend(p.fg, bg, ALPHA.fade)
  p.add_bg = M.blend(p.added, bg, ALPHA.hunk)
  p.change_bg = M.blend(p.changed, bg, ALPHA.hunk)
  p.delete_bg = M.blend(p.removed, bg, ALPHA.hunk)
  return p
end

--- nvime's own highlight groups, defined from the resolved palette.
--- @param p table a resolved palette
--- @return table<string, table>
function M.groups(p)
  local badge = function(colour)
    return { fg = colour, bg = M.blend(colour, p.bg, ALPHA.badge), bold = true }
  end
  return {
    NvimeUser = { fg = p.accent, bold = true },
    NvimeAgent = { fg = p.agent, bold = true },
    NvimeHeading = { fg = p.accent, bold = true },
    NvimeCode = { fg = p.code, bg = p.code_bg },
    NvimeFence = { fg = p.dim, bg = p.code_bg },
    NvimeInlineCode = { fg = p.code },
    NvimeBold = { bold = true },
    NvimeItalic = { italic = true },
    NvimeDim = { fg = p.dim },
    NvimeActivity = { fg = p.session },
    NvimeError = { fg = p.error },
    NvimeSession = { fg = p.session },
    NvimeSelected = { fg = p.accent, bold = true },
    -- Chrome: a winbar reads as a bar, not as another line of scrollback.
    NvimeBar = { fg = p.session, bg = p.surface, bold = true },
    NvimeBarDim = { fg = p.dim, bg = p.surface },
    NvimeBarKey = { fg = p.accent, bg = p.surface, bold = true },
    NvimeCursorLine = { bg = p.surface },
    -- Labels sit left of the value they name and must not compete with it.
    NvimeLabel = { fg = p.dim },
    NvimeKey = { fg = p.accent, bold = true },
    NvimeOk = { fg = p.added, bold = true },
    NvimeWarn = { fg = p.accent, bold = true },
    -- Changeset rows: the file, then what changed in it.
    NvimeFile = { fg = p.fg, bold = true },
    NvimeAdded = { fg = p.added },
    NvimeChanged = { fg = p.changed },
    NvimeRemoved = { fg = p.removed },
    -- Big change review: the chip a thread carries in the list.
    NvimeThreadDefend = badge(p.error),
    NvimeThreadClear = badge(p.added),
    NvimeThreadAuto = { fg = p.dim, bg = p.surface },
    NvimeThreadOpen = badge(p.accent),
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
  for name, spec in pairs(M.groups(palette)) do
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
