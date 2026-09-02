local t = require('harness')
local palette = require('nvime.palette')

local describe, it, eq, ok, throws = t.describe, t.it, t.eq, t.ok, t.throws

--- The three channels of a '#rrggbb' string.
local function channels(hex)
  local value = tonumber(hex:sub(2), 16)
  return math.floor(value / 65536) % 256, math.floor(value / 256) % 256, value % 256
end

--- Runs `fn` under `scheme`, restoring whatever was active afterwards.
local function with_scheme(scheme, background, fn)
  local before = vim.g.colors_name
  local before_bg = vim.o.background
  vim.o.background = background
  vim.cmd.colorscheme(scheme)
  local finished, err = pcall(fn)
  vim.o.background = before_bg
  if before ~= nil then
    pcall(vim.cmd.colorscheme, before)
  end
  if not finished then
    error(err, 0)
  end
end

--- WCAG relative luminance and contrast ratio, for the fallback-polarity test.
local function luminance(hex)
  local r, g, b = channels(hex)
  local function linear(c)
    c = c / 255
    return c <= 0.03928 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
end

local function contrast(a, b)
  local la, lb = luminance(a), luminance(b)
  if la < lb then
    la, lb = lb, la
  end
  return (la + 0.05) / (lb + 0.05)
end

describe('palette.blend', function()
  it('returns each end of the mix untouched', function()
    eq('#ff0000', palette.blend('#ff0000', '#0000ff', 1))
    eq('#0000ff', palette.blend('#ff0000', '#0000ff', 0))
  end)

  it('mixes each channel independently', function()
    eq('#808080', palette.blend('#ffffff', '#000000', 0.5019607843))
  end)

  it('refuses anything that is not a colour and an amount in range', function()
    throws(function()
      palette.blend('red', '#000000', 0.5)
    end)
    throws(function()
      palette.blend('#ffffff', '#000000', 2)
    end)
  end)
end)

describe('palette.resolve', function()
  it('derives every painted background from the editor’s own Normal, not from a diff group', function()
    with_scheme('default', 'dark', function()
      local p = palette.resolve()
      local nr, ng, nb = channels(p.bg)
      for _, key in ipairs({ 'surface', 'code_bg', 'fade_bg', 'add_bg', 'change_bg', 'delete_bg' }) do
        local r, g, b = channels(p[key])
        local distance = math.abs(r - nr) + math.abs(g - ng) + math.abs(b - nb)
        ok(distance > 0, key .. ' must be distinguishable from Normal')
        ok(distance < 200, key .. ' is a tint, not a slab: ' .. p[key])
      end
    end)
  end)

  it('tints an added hunk toward green and a removed one toward red, in either background', function()
    for _, background in ipairs({ 'dark', 'light' }) do
      with_scheme('default', background, function()
        local p = palette.resolve()
        local ar, ag, ab = channels(p.add_bg)
        local dr, dg, db = channels(p.delete_bg)
        ok(ag - ar > 0 and ag - ab > 0, background .. ': an added hunk must read green, got ' .. p.add_bg)
        ok(dr - dg > 0 and dr - db > 0, background .. ': a removed hunk must read red, got ' .. p.delete_bg)
      end)
    end
  end)

  --- A cleared Normal bg (a transparent terminal) used to fall back to a
  --- fixed dark colour regardless of `&background` — a light scheme's dark
  --- foregrounds then landed on a near-black surface, unreadable. The
  --- fallback must follow the terminal's own declared polarity.
  it('keeps every painted surface readable when Normal clears its own background', function()
    for _, background in ipairs({ 'dark', 'light' }) do
      with_scheme('default', background, function()
        local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
        vim.api.nvim_set_hl(0, 'Normal', { fg = normal.fg })
        local p = palette.resolve()
        local groups = palette.groups(p)
        for _, key in ipairs({ 'surface', 'code_bg', 'fade_bg', 'add_bg', 'change_bg', 'delete_bg' }) do
          local c = contrast(p.fg, p[key])
          ok(c >= 3.0, background .. ' ' .. key .. ': text on it must clear 3.0, got ' .. c)
        end
        for _, name in ipairs({ 'NvimeThreadDefend', 'NvimeThreadClear', 'NvimeThreadOpen' }) do
          local chip = groups[name]
          local c = contrast(chip.fg, chip.bg)
          ok(c >= 4.5, background .. ' ' .. name .. ': chip text must clear 4.5, got ' .. c)
        end
      end)
    end
  end)
end)

describe('palette.groups', function()
  it('gives every chip a background so it reads as a badge', function()
    local groups = palette.groups(palette.resolve())
    for _, name in ipairs({ 'NvimeThreadDefend', 'NvimeThreadClear', 'NvimeThreadOpen', 'NvimeThreadAuto' }) do
      ok(groups[name].bg ~= nil, name .. ' needs a background')
    end
  end)

  it('defines every group the surfaces name', function()
    local groups = palette.groups(palette.resolve())
    for _, name in ipairs({
      'NvimeBar',
      'NvimeBarDim',
      'NvimeCursorLine',
      'NvimeUserBody',
      'NvimeAgentBody',
      'NvimeTool',
      'NvimeKey',
      'NvimeLabel',
      'NvimeOk',
      'NvimeWarn',
      'NvimeFile',
      'NvimeAdded',
      'NvimeChanged',
      'NvimeRemoved',
      'NvimeEditAdd',
      'NvimeEditDelete',
    }) do
      ok(groups[name] ~= nil, name .. ' is used by a surface but never defined')
    end
  end)

  it('gives the two speakers subtle but distinct theme-derived surfaces', function()
    local resolved = palette.resolve()
    local groups = palette.groups(resolved)
    ok(groups.NvimeUserBody.bg ~= resolved.bg, 'the user message must be visible against Normal')
    ok(groups.NvimeAgentBody.bg ~= resolved.bg, 'the agent message must be visible against Normal')
    ok(groups.NvimeUserBody.bg ~= groups.NvimeAgentBody.bg, 'speaker boundaries must remain distinguishable')
  end)
end)

--- The whole point of the role hierarchy: five foregrounds, each with one job,
--- and no way to add a sixth without this failing.
describe('palette role tiers', function()
  it('paints every conversation group in exactly its own tier', function()
    local p = palette.resolve()
    local groups, tiers = palette.groups(p), palette.tiers(p)
    for name, tier in pairs(palette.ROLE_GROUPS) do
      ok(groups[name] ~= nil, name .. ' is pinned to a tier but never defined')
      ok(tiers[tier] ~= nil, name .. ' names an unknown tier ' .. tier)
      eq(tiers[tier], groups[name].fg, name .. ' must be the ' .. tier .. ' foreground')
    end
  end)

  --- Code and inline code are set apart by their ground; emphasis by weight
  --- and slant. Neither may quietly become another colour to learn.
  it('sets code apart by ground and emphasis by weight, never by a new colour', function()
    local groups = palette.groups(palette.resolve())
    for _, name in ipairs({ 'NvimeCode', 'NvimeInlineCode' }) do
      ok(groups[name].bg ~= nil, name .. ' must carry a ground')
    end
    eq(nil, groups.NvimeBold.fg)
    eq(nil, groups.NvimeItalic.fg)
    eq(true, groups.NvimeBold.bold)
  end)

  --- Every group a text-bearing surface names has to be accounted for: either
  --- it is a reading tier, or it is one of the axes that are deliberately not
  --- (the diff colours, the chrome of a bar, a chip's ground).
  it('leaves no text group unaccounted for', function()
    local outside = {
      NvimeAdded = true,
      NvimeBar = true,
      NvimeBarDim = true,
      NvimeBarKey = true,
      NvimeBold = true,
      NvimeChanged = true,
      NvimeCursorLine = true,
      NvimeEditAdd = true,
      NvimeEditChange = true,
      NvimeEditDelete = true,
      NvimeEditFade = true,
      NvimeItalic = true,
      NvimeOk = true,
      NvimeRemoved = true,
      NvimeThreadAuto = true,
      NvimeThreadClear = true,
      NvimeThreadDefend = true,
      NvimeThreadOpen = true,
      NvimeUserBody = true,
      NvimeAgentBody = true,
    }
    for name in pairs(palette.groups(palette.resolve())) do
      ok(
        palette.ROLE_GROUPS[name] ~= nil or outside[name],
        name .. ' is neither a reading tier nor a declared exception'
      )
    end
  end)
end)

describe('palette.apply', function()
  it('installs the groups it defines', function()
    palette.apply()
    local hl = vim.api.nvim_get_hl(0, { name = 'NvimeEditAdd', link = false })
    ok(hl.bg ~= nil, 'the add band must be a real background after apply')
  end)
end)
