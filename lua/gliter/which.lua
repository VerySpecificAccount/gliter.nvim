--- gliter.which — a light which-key: press a prefix (a key that only makes
--- sense with what follows — `<Leader>`, `g`, `z`, ...) and, the moment you
--- pause, a popup lists every mapping that continues it, straight out of
--- `:map`: the key, and the description its mapping carries. Pick one and it
--- runs; keep typing fast and you never see the popup at all.
---
--- How the "the moment you pause" works: the module maps the prefix itself
--- (`n` and `x` only, and only when nothing else has mapped it). Vim already
--- waits `timeoutlen` after a prefix for the keys that might follow — when
--- they arrive in time the real mapping wins directly and gliter.which never
--- runs; when they don't, the prefix mapping fires instead. At that point
--- `getcharstr(0)` says whether a key is already waiting: one is (you are
--- typing fast) → the popup stays away and the keys are resolved silently;
--- none is (you paused) → the popup comes up, and every key read after that
--- first pauses for it or keeps typing through it.
---
--- What a picked key does — exactly what pressing it without gliter.which
--- would have done:
---   * the sequence so far completes to a mapping → the mapping's own keys
---     are fed back as typed input (counts included: `3<Leader>cj` works),
---     so callbacks, `<expr>` and buffer-local maps all run as themselves;
---   * it dead-ends (no mapping continues it) → the keys are fed unremapped,
---     which is precisely what Vim itself does when a pending sequence times
---     out: a builtin (`gJ`, `zn`, ...) runs, or the keys do their plain
---     thing;
---   * `<BS>` steps a level back up, `<Esc>` closes.
---
--- For groups, icons, presets, paging and everything beyond the popup, use
--- which-key.nvim — gliter.which is the popup and nothing more. The idea
--- came down a chain of rewrites: guide-key (Tsunenobu Kai, 2012) showed
--- the keys that follow a prefix in Emacs; which-key.el (Justin Burkett,
--- 2015) rewrote guide-key-mode into what Emacs 30 then took into core;
--- folke's which-key.nvim (2021) ported it to Neovim.
local M = {}

M.did_setup = false

--- defaults — `prefixes` are bound in every mode of `modes` where the prefix
--- is not already mapped; `max_height` rows per column before a second
--- column appears.
M.defaults = {
  prefixes = { '<Leader>', '<LocalLeader>', 'g', 'z', '[', ']' },
  modes = { 'n', 'x' },
  border = 'rounded',
  max_height = 18,
}

M.options = vim.deepcopy(M.defaults)

local ns = vim.api.nvim_create_namespace('gliter_which')
local win = nil
local buf = nil
local bound = {} ---@type table<string, boolean> ('mode:' .. raw prefix) -> mapped by us

--- The mappings under `seq` (raw bytes) in `mode`: buffer-local ones first
--- (they win in Vim, so they win in the list), globals deduped against them,
--- sorted by key. Exposed for tests.
---@param seq string raw bytes
---@param mode string 'n' | 'x'
---@return { key: string, display: string, desc: string, buflocal: boolean }[]
function M.children(seq, mode)
  local out, seen = {}, {}
  local function scan(maps, buflocal)
    for _, m in ipairs(maps or {}) do
      local lhs = m.lhsraw ~= '' and m.lhsraw or m.lhs
      if #lhs > #seq and lhs:sub(1, #seq) == seq and not seen[lhs] then
        seen[lhs] = true
        local rest = lhs:sub(#seq + 1)
        local desc = ''
        if m.desc and m.desc ~= '' then
          desc = m.desc
        elseif m.rhs and m.rhs ~= '' then
          desc = m.rhs
        else
          desc = '(lua)'
        end
        out[#out + 1] = { key = rest, display = vim.fn.keytrans(rest), desc = desc, buflocal = buflocal }
      end
    end
  end
  scan(vim.api.nvim_buf_get_keymap(0, mode), true)
  scan(vim.api.nvim_get_keymap(mode), false)
  table.sort(out, function(a, b)
    return a.display < b.display
  end)
  return out
end

--- True when at least one mapping continues `seq`.
local function has_children(seq, mode)
  return #M.children(seq, mode) > 0
end

--- The mapping exactly at `seq` — buffer-local or global — or nil. The
--- module's own trigger maps are not mappings for this purpose.
---@param seq string raw bytes
---@param mode string
---@return table? maparg dict
function M.exact(seq, mode)
  local m = vim.fn.maparg(seq, mode, false, true)
  -- not found: a number (no dict) or an empty dict
  if type(m) ~= 'table' or next(m) == nil or (m.desc and m.desc:find('^gliter%.which')) then
    return nil
  end
  return m
end

---------------------------------------------------------------------------
-- the popup
---------------------------------------------------------------------------

local function close_popup()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win = nil
end

--- (Re)render the popup for `seq`. Returns false when nothing continues it
--- (the popup is hidden then). Exposed for tests.
---@param seq string raw bytes
---@param mode string
---@return boolean shown
function M.open_popup(seq, mode)
  local entries = M.children(seq, mode)
  if #entries == 0 then
    close_popup()
    return false
  end
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
  end
  -- columns: max_height rows each, side by side
  local ncols = math.max(1, math.ceil(#entries / M.options.max_height))
  local rows = math.ceil(#entries / ncols)
  local keyw, descw = 4, 12
  for _, e in ipairs(entries) do
    keyw = math.max(keyw, vim.fn.strdisplaywidth(e.display))
    descw = math.max(descw, math.min(38, vim.fn.strdisplaywidth(e.desc)))
  end
  local lines = {}
  for i = 0, rows - 1 do
    local parts = {}
    for c = 0, ncols - 1 do
      local e = entries[c * rows + i + 1]
      if e then
        local desc = e.desc
        if vim.fn.strdisplaywidth(desc) > descw then
          desc = vim.fn.strcharpart(desc, 0, descw - 1) .. '…'
        end
        parts[#parts + 1] = e.display .. string.rep(' ', keyw - vim.fn.strdisplaywidth(e.display))
          .. '  ' .. desc
      end
    end
    lines[#lines + 1] = table.concat(vim.list_slice(parts), '   ')
  end
  local header = vim.fn.keytrans(seq) .. ':'
  table.insert(lines, 1, header)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, 'GliterWhichHeader', 0, 0, -1)
  local colw = keyw + 2 + descw + 3
  local width = math.min(vim.o.columns - 2, math.max(#header, colw * ncols - 3))
  for i = 0, rows - 1 do
    for c = 0, ncols - 1 do
      local base = c * colw
      vim.api.nvim_buf_add_highlight(buf, ns, 'GliterWhichKey', i + 1, base, base + keyw)
      vim.api.nvim_buf_add_highlight(buf, ns, 'GliterWhichDesc', i + 1, base + keyw + 2, -1)
    end
  end
  local height = #lines
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, {
      relative = 'editor',
      anchor = 'SW',
      row = math.max(1, vim.o.lines - 3),
      col = math.max(0, (vim.o.columns - width) / 2),
      width = width,
      height = height,
    })
  else
    win = vim.api.nvim_open_win(buf, false, {
      relative = 'editor',
      anchor = 'SW',
      row = math.max(1, vim.o.lines - 3),
      col = math.max(0, (vim.o.columns - width) / 2),
      width = width,
      height = height,
      focusable = false,
      style = 'minimal',
      border = M.options.border,
      noautocmd = true,
    })
  end
  pcall(vim.cmd, 'redraw')
  return true
end

M.close_popup = close_popup

---------------------------------------------------------------------------
-- the pick loop
---------------------------------------------------------------------------

--- The prefix mapping's body: show what continues the prefix, read keys,
--- dispatch. `prefix` is the prefix in raw bytes.
local function pick(prefix)
  local mode0 = vim.fn.mode()
  local mode = (mode0 == 'v' or mode0 == 'V' or mode0 == '\22') and 'x' or 'n'
  local count = vim.v.count
  local parts = { prefix }
  local seq = prefix
  -- a key already waiting = fast typing: no popup, resolve silently
  local pending = vim.fn.getcharstr(0)
  local visible = pending == ''
  if visible then
    M.open_popup(seq, mode)
  end
  while true do
    local k = pending
    pending = ''
    if k == '' then
      k = vim.fn.getcharstr(0) -- non-blocking: still fast typing
      if k == '' then
        -- nothing waiting: the user paused — the popup belongs on screen
        if not visible then
          visible = true
          M.open_popup(seq, mode)
        end
        k = vim.fn.getcharstr() -- blocks until the next key
      end
    end
    if k == '\27' or k == '\3' then
      break
    elseif k == '\b' or k == '\127' then -- <BS>: a level back up
      if #parts > 1 then
        table.remove(parts)
        seq = table.concat(parts)
        if visible then
          M.open_popup(seq, mode)
        end
      else
        break
      end
    else
      parts[#parts + 1] = k
      seq = table.concat(parts)
      if has_children(seq, mode) then
        if visible then
          M.open_popup(seq, mode)
        end
        -- more can follow: keep reading
      elseif M.exact(seq, mode) then
        close_popup()
        -- the picked sequence, as typed input: the real mapping runs — its
        -- own rhs, callback or <expr>, count in front, buffer-local or not
        vim.api.nvim_input((count > 0 and tostring(count) or '') .. seq)
        return
      else
        -- dead end. If the sequence minus this last key was a mapping, that
        -- mapping is what Vim would have run when its timeout expired — run
        -- it, and let the stray key act on its own afterwards.
        local prev = table.concat(vim.list_slice(parts, 1, #parts - 1))
        local leftover = parts[#parts]
        close_popup()
        if M.exact(prev, mode) then
          vim.api.nvim_input((count > 0 and tostring(count) or '') .. prev)
          vim.api.nvim_input(leftover)
        else
          -- nothing mapped: feed the keys unremapped, exactly what Vim does
          -- with a pending sequence that times out (a builtin runs, or the
          -- keys do their plain thing)
          vim.api.nvim_feedkeys((count > 0 and tostring(count) or '') .. seq, 'n', false)
        end
        return
      end
    end
  end
  close_popup()
end

---------------------------------------------------------------------------
-- setup
---------------------------------------------------------------------------

--- Is `lhs` (notation) mapped globally in `mode` by something else?
local function globally_mapped(lhs, mode)
  local raw = vim.keycode(lhs)
  for _, m in ipairs(vim.api.nvim_get_keymap(mode)) do
    if m.lhsraw == raw or m.lhs == lhs then
      return true
    end
  end
  return false
end

function M.setup(opts)
  M.did_setup = true
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  -- highlights (default-linked; a colorscheme can override)
  local function link(name, target)
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  link('GliterWhichKey', 'SpecialKey')
  link('GliterWhichDesc', 'Comment')
  link('GliterWhichHeader', 'Title')
  -- re-setup: drop the previous triggers first — but only the ones that are
  -- still ours (a user mapping may have taken a prefix over since)
  for id in pairs(bound) do
    local mmode = id:match('^(.-):')
    local raw = id:sub(#mmode + 2)
    local m = vim.fn.maparg(raw, mmode, false, true)
    if type(m) == 'table' and m.desc and m.desc:find('^gliter%.which') then
      pcall(vim.keymap.del, mmode, raw)
    end
    bound[id] = nil
  end
  for _, prefix in ipairs(M.options.prefixes) do
    for _, mmode in ipairs(M.options.modes) do
      if not globally_mapped(prefix, mmode) then
        local raw = vim.keycode(prefix)
        vim.keymap.set(mmode, prefix, function()
          pick(raw)
        end, {
          noremap = true,
          silent = true,
          desc = 'gliter.which: the key popup (pause after the prefix)',
        })
        bound[mmode .. ':' .. raw] = true
      end
    end
  end
  return M
end

return M
