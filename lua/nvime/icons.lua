--- The two glyph sets every nvime surface draws from.
---
--- The default set is deliberately plain Unicode — box drawing, braille,
--- arrows, a check mark — never a private-use Nerd Font codepoint, so it
--- renders in any font a terminal is likely to have. `ui.icons = 'ascii'`
--- swaps the whole set for pure ASCII for a terminal that has neither.
local M = {}

-- Deliberately narrow: braille (the usual spinner), U+2717 ✗ and U+2025 ‥ are
-- all absent from fonts as mainstream as Fira Code, and render as tofu. Every
-- glyph below is in the Latin-1, Arrows, Box Drawing, Block Elements or
-- Geometric Shapes ranges that a terminal font is expected to carry.
local SETS = {
  unicode = {
    spinner = { '◜', '◝', '◞', '◟' },
    ok = '✓',
    warn = '▲',
    fail = '×',
    info = '·',
    bar = '▏',
    dot = '·',
    busy = '●',
    arrow = '→',
    rule = '─',
    added = '+',
    changed = '~',
    removed = '-',
  },
  ascii = {
    spinner = { '|', '/', '-', '\\' },
    ok = 'v',
    warn = '!',
    fail = 'x',
    info = '.',
    bar = '|',
    dot = '.',
    busy = '*',
    arrow = '->',
    rule = '-',
    added = '+',
    changed = '~',
    removed = '-',
  },
}

--- The active set, per `config.ui.icons`. Read at draw time, so flipping the
--- option and redrawing is enough — nothing caches a glyph.
--- @return table
function M.get()
  local name = require('nvime.config').get().ui.icons
  local set = SETS[name]
  assert(set ~= nil, 'unknown icon set ' .. tostring(name))
  return set
end

--- @param level string one of ok, warn, error, info
--- @return string
function M.level(level)
  local set = M.get()
  local by_level = { ok = set.ok, warn = set.warn, error = set.fail, info = set.info }
  return by_level[level] or set.info
end

M.SETS = SETS

return M
