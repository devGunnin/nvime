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
