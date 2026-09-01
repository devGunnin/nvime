local t = require('harness')
local markdown = require('nvime.markdown')

local describe, it, eq, ok = t.describe, t.it, t.eq, t.ok

describe('markdown.scan', function()
  it('marks a heading line whole', function()
    local info = markdown.scan('## Findings', markdown.new_state())
    eq('heading', info.kind)
    eq({ { 0, 2, 'NvimeDim' }, { 2, 11, 'NvimeHeading' } }, info.spans)
  end)

  it('ignores a run of hashes that is not a heading', function()
    eq('text', markdown.scan('####### too deep', markdown.new_state()).kind)
    eq('text', markdown.scan('#nospace', markdown.new_state()).kind)
  end)

  it('spans inline code including its backticks', function()
    local info = markdown.scan('a `code` b', markdown.new_state())
    eq({ { 2, 8, 'NvimeInlineCode' } }, info.spans)
  end)

  it('prefers bold over italic on the same run', function()
    eq({ { 0, 8, 'NvimeBold' } }, markdown.scan('**bold** x', markdown.new_state()).spans)
    eq({ { 0, 7, 'NvimeItalic' } }, markdown.scan('*slant* x', markdown.new_state()).spans)
  end)

  it('does not italicise snake_case identifiers', function()
    eq({}, markdown.scan('call snake_case_name now', markdown.new_state()).spans)
    eq({ { 0, 4, 'NvimeItalic' } }, markdown.scan('_em_ text', markdown.new_state()).spans)
  end)

  --- The reviewer's own repro: `boundary` alone still passes `* 3 *` — both
  --- its outer edges sit next to a space, indistinguishable from real
  --- emphasis between two words. Content starting or ending with a space
  --- (never true emphasis) is what actually gives arithmetic away.
  it('does not italicise arithmetic across a bare *, only a real code span', function()
    local info = markdown.scan('run with 2 * 3 * 4 workers, glob *.py, and `a * b`', markdown.new_state())
    eq({ { 43, 50, 'NvimeInlineCode' } }, info.spans)
  end)

  it('does not italicise a lone bullet asterisk paired with unrelated text', function()
    eq({}, markdown.scan('* not a pair * still just a bullet', markdown.new_state()).spans)
  end)

  it('does not decorate markers inside inline code', function()
    local info = markdown.scan('`**not bold**` after', markdown.new_state())
    eq({ { 0, 14, 'NvimeInlineCode' } }, info.spans)
  end)

  it('carries fence state across lines and captures the language', function()
    local state = markdown.new_state()
    local open = markdown.scan('```lua', state)
    eq('fence_open', open.kind)
    eq('lua', open.lang)
    ok(state.in_fence)

    local body = markdown.scan('local x = 1 -- **not bold**', state)
    eq('code', body.kind)
    -- The block's colour is a line highlight, so the fence grammar keeps
    -- its own foregrounds on top of it.
    eq({}, body.spans)
    eq('NvimeCode', body.line_hl)

    local close = markdown.scan('```', state)
    eq('fence_close', close.kind)
    ok(not state.in_fence)
  end)

  it('treats a tilde fence like a backtick fence', function()
    local state = markdown.new_state()
    eq('fence_open', markdown.scan('~~~python', state).kind)
    eq('code', markdown.scan('x = 1', state).kind)
    eq('fence_close', markdown.scan('~~~', state).kind)
  end)

  it('leaves an unterminated fence open, so the tail stays code', function()
    local state = markdown.new_state()
    markdown.scan('```', state)
    eq('code', markdown.scan('# not a heading', state).kind)
  end)
end)

describe('markdown.render', function()
  it('classifies a whole message line by line', function()
    local infos = markdown.render('# Title\n\ntext `x`\n```lua\nlocal a = 1\n```')
    eq(
      { 'heading', 'text', 'text', 'fence_open', 'code', 'fence_close' },
      vim.tbl_map(function(info)
        return info.kind
      end, infos)
    )
  end)

  it('rejects a non-string message', function()
    t.throws(function()
      markdown.render(nil)
    end, 'needs a string')
  end)
end)

describe('markdown.scan — the calm surface', function()
  it('classifies a thematic break rather than letting it read as a rule', function()
    for _, line in ipairs({ '---', '***', '___', '- - -', '  ----------' }) do
      eq('rule', markdown.scan(line, markdown.new_state()).kind, line)
    end
  end)

  it('does not mistake bold, a list marker or a table for a break', function()
    for _, line in ipairs({ '***bold***', '- a', '--', '-|-|-', 'a---b' }) do
      eq('text', markdown.scan(line, markdown.new_state()).kind, line)
    end
  end)

  it('leaves a break inside a fence as the code it is', function()
    local state = markdown.new_state()
    markdown.scan('```make', state)
    eq('code', markdown.scan('---', state).kind)
  end)

  --- `~~x~~` reads as struck, not merely dim: concealing the markers must
  --- not also erase that the text was struck through in the first place.
  it('renders struck-through text with the strikethrough attribute', function()
    local info = markdown.scan('the ~~simplest~~ option', markdown.new_state())
    eq({ { 4, 16, 'NvimeStrike' } }, info.spans)
    eq({ { 4, 6 }, { 14, 16 } }, info.conceal)
  end)

  it('conceals every inline marker, so the text reads without its markup', function()
    eq({ { 0, 2 }, { 6, 8 } }, markdown.scan('**bold** x', markdown.new_state()).conceal)
    eq({ { 2, 3 }, { 7, 8 } }, markdown.scan('a `code` b', markdown.new_state()).conceal)
    eq({ { 0, 1 }, { 6, 7 } }, markdown.scan('*slant* x', markdown.new_state()).conceal)
    eq({ { 0, 3 } }, markdown.scan('## Findings', markdown.new_state()).conceal)
  end)

  --- The block's ground says where it starts; the ticks say it twice.
  it('conceals a fence’s ticks and keeps its language tag', function()
    local state = markdown.new_state()
    eq({ { 0, 3 } }, markdown.scan('```lua', state).conceal)
    markdown.scan('local x = 1', state)
    eq({ { 2, 5 } }, markdown.scan('  ```', state).conceal)
  end)

  --- The body colour is a SPAN, under the inline spans on the same line. As a
  --- `line_hl_group` it sat over them and flattened every heading and marker.
  it('gives every prose line one explicit body colour, under its markup', function()
    eq('NvimeBody', markdown.scan('plain text', markdown.new_state()).body_hl)
    eq('NvimeBody', markdown.scan('# Title', markdown.new_state()).body_hl)
    eq('NvimeDim', markdown.scan('---', markdown.new_state()).body_hl)
    for _, line in ipairs({ 'plain text', '# Title', '---' }) do
      eq(nil, markdown.scan(line, markdown.new_state()).line_hl, line .. ' must not paint a ground')
    end
  end)

  it('names the fence a choice block arrives in', function()
    local open = markdown.scan('```' .. markdown.OPTIONS_LANG, markdown.new_state())
    eq('fence_open', open.kind)
    eq(markdown.OPTIONS_LANG, open.lang)
  end)
end)
