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
end)

describe('palette.apply', function()
  it('installs the groups it defines', function()
    palette.apply()
    local hl = vim.api.nvim_get_hl(0, { name = 'NvimeEditAdd', link = false })
    ok(hl.bg ~= nil, 'the add band must be a real background after apply')
  end)
end)
