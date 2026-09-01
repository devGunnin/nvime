local t = require('harness')
local config = require('nvime.config')
local icons = require('nvime.icons')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

--- Runs `fn` with `ui.icons` set to `name`, restoring the config afterwards.
local function with_set(name, fn)
  config.setup({ ui = { icons = name } })
  local finished, err = pcall(fn)
  config.setup({})
  if not finished then
    error(err, 0)
  end
end

describe('icons.get', function()
  it('answers the configured set', function()
    with_set('ascii', function()
      eq('v', icons.get().ok)
    end)
    with_set('unicode', function()
      eq('✓', icons.get().ok)
    end)
  end)

  it('defines the same keys in both sets, so no surface loses a glyph on ascii', function()
    local unicode, ascii = icons.SETS.unicode, icons.SETS.ascii
    for key in pairs(unicode) do
      ok(ascii[key] ~= nil, key .. ' is missing from the ascii set')
    end
    for key in pairs(ascii) do
      ok(unicode[key] ~= nil, key .. ' is missing from the unicode set')
    end
    eq(#unicode.spinner > 0, true)
    eq(#ascii.spinner > 0, true)
  end)

  it('stays inside ASCII in the ascii set', function()
    for key, value in pairs(icons.SETS.ascii) do
      local glyphs = type(value) == 'table' and value or { value }
      for _, glyph in ipairs(glyphs) do
        ok(#glyph == vim.fn.strchars(glyph), key .. ' must be pure ASCII, got ' .. glyph)
      end
    end
  end)

  it('avoids the codepoints mainstream terminal fonts do not carry', function()
    -- Braille, U+2717 and U+2025 are absent from fonts as common as Fira Code
    -- and render as tofu; the whole point of this set is that they do not.
    local banned = { ['⠋'] = true, ['✗'] = true, ['‥'] = true }
    for key, value in pairs(icons.SETS.unicode) do
      local glyphs = type(value) == 'table' and value or { value }
      for _, glyph in ipairs(glyphs) do
        ok(not banned[glyph], key .. ' uses a glyph known to be missing from common fonts')
      end
    end
  end)
end)

describe('icons.level', function()
  it('gives each diagnostic level its own glyph', function()
    with_set('unicode', function()
      local seen = {}
      for _, level in ipairs({ 'ok', 'warn', 'error', 'info' }) do
        local glyph = icons.level(level)
        ok(seen[glyph] == nil, 'two levels share a glyph at ' .. level)
        seen[glyph] = true
      end
    end)
  end)

  it('falls back to the info glyph for a level it does not know', function()
    with_set('unicode', function()
      eq(icons.get().info, icons.level('something-else'))
    end)
  end)
end)

describe('config.ui.icons', function()
  it('refuses a set that does not exist', function()
    t.throws(function()
      config.setup({ ui = { icons = 'emoji' } })
    end, 'ui.icons')
    config.setup({})
  end)
end)
