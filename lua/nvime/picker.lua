--- A small floating list. Deliberately not `vim.fn.inputlist`/`confirm`: nvime
--- never opens a modal prompt, so every choice is a float with keybinds that
--- the user can dismiss without answering.
local M = {}

local MAX_HEIGHT = 12
local NS = vim.api.nvim_create_namespace('nvime.picker')

local function close(win, buf)
  if vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

--- A small y/n float — never `vim.fn.confirm`, which blocks the editor.
--- Dismissible with q/Esc/n like everything else here, answered with y.
--- @param prompt string
--- @param on_answer fun(yes: boolean)
local function confirm(prompt, on_answer)
  local width = math.min(math.max(vim.fn.strdisplaywidth(prompt) + 4, 24), math.max(vim.o.columns - 4, 20))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ' ' .. prompt, ' y  yes    n  no' })
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = 2,
    row = math.max(math.floor((vim.o.lines - 2) / 2), 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = 'rounded',
    title = ' confirm ',
    title_pos = 'center',
  })
  -- Explicit, not inherited: a new float otherwise copies window-local
  -- 'wrap'/'breakindent' from whatever window was current, which once
  -- corrupted an unrelated strdisplaywidth() measurement made from this one.
  vim.wo[win].wrap = true
  vim.wo[win].breakindent = false
  local answered = false
  local function finish(yes)
    -- A key mapped twice (y and q both bound, say) must answer once, not
    -- twice, and never touch a window this already closed.
    if answered then
      return
    end
    answered = true
    close(win, buf)
    on_answer(yes)
  end
  for _, entry in ipairs({ { 'y', true }, { 'n', false }, { 'q', false }, { '<Esc>', false } }) do
    vim.keymap.set('n', entry[1], function()
      -- `nowait` cannot consume a count, so `3y` would otherwise reach here
      -- and confirm. A count means the key was not meant as this answer.
      if entry[2] and vim.v.count > 0 then
        return
      end
      finish(entry[2])
    end, { buffer = buf, nowait = true, silent = true })
  end
  -- Walking out of the float with an unmapped window command must not leave a
  -- stuck-looking modal over the editor; leaving is declining.
  vim.api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
    buffer = buf,
    callback = function()
      -- Not inline: closing a window from inside WinLeave hits textlock. The
      -- `answered` latch makes the deferred call a no-op after a real answer.
      vim.schedule(function()
        finish(false)
      end)
    end,
  })
end

--- @param items table[] each with `label` (string) and `value` (any); an
---   optional `lead` (integer) is how many cells of the label are the dim
---   metadata column ahead of the name; `deletable = false` opts an entry
---   (a synthetic "new" row, say) out of `d`.
--- @param opts table title, on_choice(value), on_delete(value, done)|nil —
---   `done(ok)` reports whether the deletion actually happened, so a failed
---   one leaves the row in place.
function M.open(items, opts)
  assert(type(items) == 'table', 'picker.open needs an items list')
  assert(type(opts.on_choice) == 'function', 'picker.open needs an on_choice callback')
  if #items == 0 then
    vim.notify('nvime: no sessions yet for this project', vim.log.levels.INFO)
    return nil
  end

  local labels = vim.tbl_map(function(item)
    return ' ' .. item.label
  end, items)
  local width = 0
  for _, label in ipairs(labels) do
    width = math.max(width, vim.fn.strdisplaywidth(label))
  end
  -- Clamp to the terminal: a float taller or wider than the screen would place
  -- at a negative row/col and `nvim_open_win` throws out of an RPC callback.
  width = math.min(math.max(width + 2, 30), math.max(math.floor(vim.o.columns * 0.8), 1))
  local height = math.max(math.min(#items, MAX_HEIGHT, vim.o.lines - 2), 1)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, labels)
  for row, item in ipairs(items) do
    local lead = math.min((item.lead or 0) + 1, #labels[row])
    if lead > 1 then
      vim.api.nvim_buf_set_extmark(buf, NS, row - 1, 0, {
        end_col = lead,
        hl_group = 'NvimeDim',
        strict = false,
      })
    end
    if item.current then
      vim.api.nvim_buf_set_extmark(buf, NS, row - 1, lead, {
        end_col = #labels[row],
        hl_group = 'NvimeSelected',
        strict = false,
      })
    end
  end
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = 'wipe'

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2), 0),
    col = math.max(math.floor((vim.o.columns - width) / 2), 0),
    style = 'minimal',
    border = 'rounded',
    title = opts.title or 'nvime',
    title_pos = 'center',
    footer = opts.on_delete ~= nil and ' <CR> open · d delete · q close ' or ' <CR> open · q close ',
    footer_pos = 'right',
  })
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight = 'CursorLine:NvimeCursorLine'
  -- Explicit, not inherited: each row is one item, sized to fit — a picker
  -- row must never wrap, whatever window-local 'wrap' this float would
  -- otherwise copy from whatever window happened to be current.
  vim.wo[win].wrap = false
  vim.wo[win].breakindent = false

  -- Items whose deletion the sidecar has not answered yet, keyed by identity:
  -- rows move as earlier deletes land, so a row number would not survive.
  local deleting = {}

  local function dismiss()
    close(win, buf)
  end
  local function choose()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local item = items[row]
    if item ~= nil and deleting[item] then
      vim.notify('nvime: that one is being deleted', vim.log.levels.WARN)
      return
    end
    dismiss()
    if item ~= nil then
      opts.on_choice(item.value)
    end
  end

  --- Drops one row after a confirmed delete — no re-list round trip, and the
  --- picker stays open for another. Closes instead once nothing is left.
  local function remove_row(row)
    if #items <= 1 then
      dismiss()
      return
    end
    table.remove(items, row)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, row - 1, row, false, {})
    vim.bo[buf].modifiable = false
  end

  --- Where `item` sits now, or nil if an earlier delete already took it out.
  local function row_of(item)
    for row, entry in ipairs(items) do
      if entry == item then
        return row
      end
    end
    return nil
  end

  --- Dims a row for as long as its delete is outstanding. The extmark rides
  --- the line, so it stays on the right row when rows above it disappear.
  local function mark_deleting(item)
    local row = row_of(item)
    if row == nil then
      deleting[item] = true
      return
    end
    deleting[item] = vim.api.nvim_buf_set_extmark(buf, NS, row - 1, 0, {
      end_col = #(' ' .. item.label),
      hl_group = 'NvimeDim',
      strict = false,
    })
  end

  local function unmark_deleting(item)
    local mark = deleting[item]
    deleting[item] = nil
    if type(mark) == 'number' and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_del_extmark, buf, NS, mark)
    end
  end

  -- True while this picker's own confirm float holds focus: leaving for our
  -- own child is not the user walking away, so dismissal is muted for it.
  local confirming = false

  --- The muted WinLeave never fired for the confirm float, so re-check on the
  --- way back: answering it from some other window dismisses the picker too.
  local function dismiss_if_left()
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() ~= win then
      dismiss()
    end
  end

  local function delete_current()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local item = items[row]
    if item == nil or item.deletable == false or deleting[item] then
      return
    end
    confirming = true
    confirm('delete ' .. vim.trim(item.label) .. '?', function(yes)
      confirming = false
      if yes and vim.api.nvim_buf_is_valid(buf) then
        mark_deleting(item)
        opts.on_delete(item.value, function(ok)
          unmark_deleting(item)
          if not ok or not vim.api.nvim_buf_is_valid(buf) then
            return
          end
          -- By identity, not the captured row: a delete that landed first may
          -- already have shifted this item up the list.
          local now = row_of(item)
          if now ~= nil then
            remove_row(now)
          end
        end)
      end
      dismiss_if_left()
    end)
  end

  local map = function(lhs, fn)
    vim.keymap.set('n', lhs, fn, { buffer = buf, nowait = true, silent = true })
  end
  map('<CR>', choose)
  if opts.on_delete ~= nil then
    map('d', delete_current)
  end
  map('q', dismiss)
  map('<Esc>', dismiss)
  -- Same contract as the confirm float: an unmapped window command must not
  -- leave this floating over the user's code. Leaving is closing it.
  vim.api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
    buffer = buf,
    callback = function()
      -- Not inline: closing a window from inside WinLeave hits textlock.
      vim.schedule(function()
        if not confirming then
          dismiss()
        end
      end)
    end,
  })
  return win
end

return M
