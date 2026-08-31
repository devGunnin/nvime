std = 'lua51+luajit'
globals = { 'vim' }
max_line_length = 120

files['tests/'] = {
  -- The harness deliberately exposes describe/it as locals per spec file.
  ignore = { '212' },
}

-- Neovim's Lua is LuaJIT; unused self in method stubs is not worth a warning.
ignore = { '212/self' }
