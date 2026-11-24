--- Buffer-local mappings added to native netrw buffers.
---
--- Every key the plugin binds comes from `config.options.keys`. The multi-key
--- sequences are built from the same table: `%<mark>` is the regexp prefix plus the
--- mark key, `*<family>` the star prefix plus a family key, and `*<mark><family>` a
--- mark key in between — so remapping a mark key remaps its sequences with it.
local actions = require('gliter.netrw.actions')
local config = require('gliter.netrw.config')

local M = {}

--- Visual range as {first, last}; leaves Visual mode.
---@return integer[]
local function visual_range()
  local a, b = vim.fn.line('v'), vim.fn.line('.')
  if a > b then
    a, b = b, a
  end
  vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
  return { a, b }
end

--- Move netrw's own mapping for `from` to `to`, so taking over a key does not lose a feature.
---@param from string
---@param to string|false
local function relocate(from, to)
  if not to then
    return
  end
  local m = vim.fn.maparg(from, 'n', false, true)
  if type(m) ~= 'table' or m.buffer ~= 1 or (m.desc and m.desc:find('^gliter%.netrw')) then
    return
  end
  local existing = vim.fn.maparg(to, 'n', false, true)
  if type(existing) == 'table' and existing.buffer == 1 then
    return -- never clobber something the user already put there
  end
  local copy = vim.deepcopy(m)
  copy.lhs, copy.lhsraw, copy.lhsrawalt = to, vim.keycode(to), nil
  pcall(vim.fn.mapset, 'n', false, copy)
end

--- gliter's replacements for netrw's read-the-line keys, on custom-listing
--- buffers (see custom.lua): Enter/`<2-LeftMouse>`/`<LeftMouse>` open,
--- `o`/`v`/`t` split, `P` and the middle mouse open in the previous window,
--- the preview key previews, and `qf` — netrw's own file-info key — shows
--- the `F` float instead (same report, and it reads the line correctly).
--- (Defined before M.attach, which calls them — they are locals.)
local CUSTOM_NAV = { '<CR>', '<2-LeftMouse>', '<LeftMouse>', '<MiddleMouse>', 'o', 'v', 't', 'P', 'qf' }

--- netrw's own keys that read the entry under the cursor off the line and
--- have no gliter equivalent: removed on custom-listing buffers, where they
--- would act on `ls -l`'s columns as if they were a file name. netrw
--- re-installs them with its next re-list of a plain style.
local CUSTOM_DROP = {
  'gd', 'gf', 'gn', 'gb', 'qb', 'qF', 'qL', 'O', '<C-R>', '<C-LeftMouse>',
  '<S-LeftMouse>', '<S-LeftDrag>', '<Del>', '<RightMouse>',
  'mf', 'mu', 'mr', 'mt', 'mx', 'mX', 'ma', 'mb', 'mc', 'md', 'me', 'mg',
  'mh', 'mm', 'ms', 'mv', 'mz', 'mT',
}

---@param buf integer
---@param km GliterNetrwKeymaps
local function attach_custom(buf, km)
  local ops = require('gliter.netrw.ops')
  local function nmap(lhs, fn, desc)
    -- The preview key can carry netrw's own preview, relocated onto it by
    -- mapset() (see `relocate`): a map that mapset() installed is stored
    -- under the key's raw bytes, and a later keymap.set() on the same key
    -- does not replace it — the two live side by side and the raw one wins
    -- the keypress. Deleting the raw form first leaves one map, ours.
    pcall(vim.api.nvim_buf_del_keymap, buf, 'n', vim.keycode(lhs))
    vim.keymap.set('n', lhs, fn, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = 'gliter.netrw: ' .. desc,
    })
  end
  -- A mouse click that runs a mapping does not move the cursor by itself
  -- (the mapping swallowed the key), so the click's position is read and
  -- the cursor put there first — the entry under the CLICK is the one
  -- that opens, the way netrw's own mouse keys behave.
  local function click(open)
    return function()
      local ok, pos = pcall(vim.fn.getmousepos)
      if ok and type(pos) == 'table' and pos.winid ~= 0 and pos.line > 0 then
        pcall(vim.api.nvim_win_set_cursor, pos.winid, { pos.line, math.max(0, pos.column - 1) })
      end
      open()
    end
  end
  nmap('<CR>', function()
    ops.open('edit')
  end, 'open the entry under the cursor')
  nmap('<2-LeftMouse>', click(function()
    ops.open('edit')
  end), 'open the entry under the cursor')
  nmap('<LeftMouse>', click(function()
    ops.open('edit')
  end), 'open the entry under the cursor')
  nmap('<MiddleMouse>', click(ops.open_prevwin), 'open the entry under the cursor in the previous window')
  nmap('o', function()
    ops.open('split')
  end, 'open the entry under the cursor in a split')
  nmap('v', function()
    ops.open('vsplit')
  end, 'open the entry under the cursor in a vertical split')
  nmap('t', function()
    ops.open('tabedit')
  end, 'open the entry under the cursor in a new tab')
  nmap('P', ops.open_prevwin, 'open the entry under the cursor in the previous window')
  nmap('qf', ops.file, "show the file command's report on the entry under the cursor")
  if km.preview then
    nmap(km.preview, ops.preview, 'preview the entry under the cursor')
  end
  -- Inside nvim_buf_call: the deletions below must see buffer-local maps of
  -- `buf`, and maparg()/keymap.del resolve those through the current buffer.
  vim.api.nvim_buf_call(buf, function()
    for _, lhs in ipairs(CUSTOM_DROP) do
      pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
    end
  end)
end

--- Remove the custom-listing replacements (only gliter's own maps — netrw's
--- originals, re-installed by its re-list, are left alone). maparg() finds
--- buffer-local maps only in the current buffer, hence the nvim_buf_call.
---@param buf integer
---@param km GliterNetrwKeymaps
local function detach_custom(buf, km)
  local mine = { unpack(CUSTOM_NAV) }
  if km.preview then
    mine[#mine + 1] = km.preview
  end
  vim.api.nvim_buf_call(buf, function()
    for _, lhs in ipairs(mine) do
      local m = vim.fn.maparg(lhs, 'n', false, true)
      if type(m) == 'table' and m.buffer == 1 and m.desc and m.desc:find('^gliter%.netrw') then
        pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
      end
    end
  end)
end

---@param buf integer
function M.attach(buf)
  local km = config.options.keys
  if not km then
    return
  end
  -- A buffer in edit mode has its own maps (see edit.lua). netrw re-announces its
  -- filetype while it re-lists, which re-runs this function; it must not put the
  -- normal-mode y/p/Y/Esc maps back over the edit-mode ones.
  if vim.b[buf].gliter_netrw_editing then
    return
  end

  local function map(mode, lhs, rhs, desc, extra)
    if not lhs then
      return
    end
    vim.keymap.set(
      mode,
      lhs,
      rhs,
      -- nowait: act on the key immediately. Without it Vim waits for a second key whenever a
      -- longer mapping starts with the same key (netrw's `mf`, `mt`, ... start with `m`).
      vim.tbl_extend('force', { buffer = buf, silent = true, nowait = true, desc = 'gliter.netrw: ' .. desc }, extra or {})
    )
  end

  -- Remove netrw's own buffer-local keys that we replace (e.g. native `d` = make dir,
  -- `D` = delete), so they no longer shadow or contradict the gliter.netrw bindings.
  -- Inside nvim_buf_call: maparg() only finds buffer-local maps of the
  -- current buffer, and attach() also runs from a schedule where the current
  -- buffer is not necessarily `buf`.
  vim.api.nvim_buf_call(buf, function()
    for _, lhs in ipairs(config.options.native_unmap or {}) do
      local m = vim.fn.maparg(lhs, 'n', false, true)
      if type(m) == 'table' and m.buffer == 1 and not (m.desc and m.desc:find('^gliter%.netrw')) then
        pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
      end
    end
  end)

  -- The single-key marks and their select-all forms.
  local mark_keys = {
    { key = km.yank, kind = 'copy', name = 'copy' },
    { key = km.move, kind = 'move', name = 'move' },
    { key = km.delete, kind = 'delete', name = 'delete' },
    { key = km.archive, kind = 'archive', name = 'archive' },
  }
  local all_keys = {
    { key = km.yank_all, kind = 'copy', name = 'copy' },
    { key = km.move_all, kind = 'move', name = 'move' },
    { key = km.delete_all, kind = 'delete', name = 'delete' },
    { key = km.archive_all, kind = 'archive', name = 'archive' },
  }

  vim.api.nvim_buf_call(buf, function()
    if km.paste == 'p' then
      relocate('p', km.preview)
    end

    for _, mk in ipairs(mark_keys) do
      if mk.key then
        map('n', mk.key, function()
          actions.mark(mk.kind)
        end, 'toggle ' .. mk.name .. ' mark')
        map('x', mk.key, function()
          actions.mark(mk.kind, visual_range())
        end, 'toggle ' .. mk.name .. ' mark on selection')
      end
    end
    for _, ak in ipairs(all_keys) do
      if ak.key then
        map('n', ak.key, function()
          actions.mark_all(ak.kind)
        end, 'toggle ' .. ak.name .. ' mark on every entry')
      end
    end

    local ops = require('gliter.netrw.ops')
    if km.copy_to then
      map('n', km.copy_to, ops.copy, 'copy marked entries (or the one under the cursor) to a directory')
    end
    if km.rename_to then
      map('n', km.rename_to, ops.rename, 'move/rename marked entries (or the one under the cursor)')
    end
    if km.delete_now then
      map('n', km.delete_now, ops.delete, 'delete marked entries (or the one under the cursor)')
    end
    if km.execute then
      map('n', km.execute, ops.chmod, 'toggle the executable bit on marked entries (or the one under the cursor)')
      map('x', km.execute, function()
        ops.chmod(visual_range())
      end, 'toggle the executable bit on the selection')
    end
    if km.symlink then
      map('n', km.symlink, ops.symlink, 'symlink marked entries (or the one under the cursor)')
    end
    if km.shell then
      map('n', km.shell, ops.shell, 'run a shell command on !-marked entries (or any marked, or the one under the cursor)')
    end
    if km.run_each then
      map('n', km.run_each, ops.run_each, 'run a shell command on each marked entry, one at a time')
    end
    if km.mkdir then
      map('n', km.mkdir, ops.create, 'create a file, or a directory when the name ends in /')
    end
    if km.cd then
      map('n', km.cd, ops.cd_here, 'cd to the directory listed here')
    end
    if km.file then
      map('n', km.file, ops.file, "show the file command's report on the entry under the cursor")
    end

    -- Bookmarks: <C-1>..<C-9> jump to their slot (an unset slot is pointed
    -- here first); <C-b>1..9 point a slot here, <C-b>0 clears them, <C-b>l lists them.
    local bookmarks = require('gliter.netrw.bookmarks')
    if km.bookmark then
      for i = 1, 9 do
        map('n', km.bookmark .. tostring(i), function()
          bookmarks.set(i)
        end, ('point bookmark %d at this directory'):format(i))
      end
      map('n', km.bookmark .. '0', function()
        bookmarks.clear_all()
      end, 'clear all nine bookmarks')
      map('n', km.bookmark .. 'l', function()
        bookmarks.list()
      end, 'list the bookmarks')
    end
    if km.bookmark_jump then
      for i, lhs in ipairs(km.bookmark_jump) do
        if lhs then
          map('n', lhs, function()
            bookmarks.jump(i)
          end, ('jump to bookmark %d (an unset slot is pointed here first)'):format(i))
        end
      end
    end

    -- `%<mark key>`: mark by regexp. The letter is the mark key itself — `%y` copy,
    -- `%m` move, `%d` delete, `%z` archive — plus `%!` shell and `%x` run (the
    -- `!` and `x` command keys).
    if km.regex_prefix then
      for _, mk in ipairs(mark_keys) do
        if mk.key then
          map('n', km.regex_prefix .. mk.key, function()
            ops.mark_regexp(mk.kind)
          end, 'mark by regexp for ' .. mk.name)
        end
      end
      if km.shell then
        map('n', km.regex_prefix .. km.shell, function()
          ops.mark_regexp('shell')
        end, 'mark by regexp for shell')
      end
      if km.run_each then
        map('n', km.regex_prefix .. km.run_each, function()
          ops.mark_regexp('run')
        end, 'mark by regexp for the one-at-a-time run')
      end
    end

    -- `*<family>`: mark a family — `*.` by extension, `*/` every directory, `*@` every
    -- symlink, `**` every executable — with the default kind (`star_kind`). A mark key
    -- in between (`*y.`, `*m/`, `*d@`, `*z*`, `*!*`, `*x.`) marks with that kind instead
    -- and makes it the family's new default, all in one sequence.
    if km.star_prefix then
      local kinds = {}
      for _, mk in ipairs(mark_keys) do
        if mk.key then
          kinds[#kinds + 1] = { key = mk.key, kind = mk.kind, name = mk.name }
        end
      end
      if km.shell then
        kinds[#kinds + 1] = { key = km.shell, kind = 'shell', name = 'shell' }
      end
      if km.run_each then
        kinds[#kinds + 1] = { key = km.run_each, kind = 'run', name = 'run' }
      end
      local families = {
        { key = km.star_ext, what = 'ext' },
        { key = km.star_dirs, what = 'dirs' },
        { key = km.star_links, what = 'links' },
        { key = km.star_exec, what = 'exec' },
      }
      for _, fam in ipairs(families) do
        if fam.key then
          map('n', km.star_prefix .. fam.key, function()
            ops.mark_star(fam.what)
          end, 'mark ' .. fam.what .. ' (default kind)')
          for _, k in ipairs(kinds) do
            map('n', km.star_prefix .. k.key .. fam.key, function()
              ops.mark_star(fam.what, k.kind)
            end, ('mark %s for %s (and make it the default)'):format(fam.what, k.name))
          end
        end
      end
    end

    map('n', km.paste, actions.paste, 'apply the marks: paste, delete, archive')
    map('n', km.clear, actions.clear, 'clear all marks')
    map('n', km.edit, actions.edit_toggle, 'toggle in-place editing of the listing')

  end)

  -- A custom listing (see custom.lua) is text netrw's own keys cannot read:
  -- the ones that take the entry off the line — Enter, the splits, the
  -- preview, netrw's own marks — are replaced by parser-driven versions,
  -- and the ones whose job gliter already has a key for are simply removed
  -- (netrw puts its own back on the next re-list when no listing is
  -- configured).
  if vim.b[buf].gliter_netrw_custom then
    attach_custom(buf, km)
  else
    detach_custom(buf, km)
  end
end

--- While the listing is directly editable (see edit.lua) every buffer-local normal, visual,
--- select and operator-pending mapping that netrw or gliter.netrw defines is removed, so Vim's
--- own keys work: `o` is not netrw's open-in-split, `i` is not "cycle listing style", `u` is
--- Vim's undo. Only the edit key itself stays, so pressing it again cancels the edit.
--- Returns a snapshot that `restore` puts back exactly.
---@param buf integer
---@return table[] saved
function M.suspend(buf)
  local km = config.options.keys or {}
  local saved, dels = {}, {}
  vim.api.nvim_buf_call(buf, function()
    for _, mode in ipairs({ 'n', 'x', 's', 'o' }) do
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        local info = vim.fn.maparg(m.lhs, mode, false, true)
        if type(info) == 'table' and info.buffer == 1 and info.lhs ~= km.edit then
          saved[#saved + 1] = info
          dels[#dels + 1] = { mode = mode, lhs = m.lhs }
        end
      end
    end
  end)
  -- Delete by the mode we looped over: maparg reports `:map` (all modes) as ' ', which
  -- nvim_buf_del_keymap would not accept.
  for _, d in ipairs(dels) do
    pcall(vim.api.nvim_buf_del_keymap, buf, d.mode, d.lhs)
  end
  return saved
end

--- Put back what `suspend` removed, then re-attach gliter.netrw's own keys (which also
--- re-applies the native_unmap and preview relocations).
---@param buf integer
---@param saved table[]|nil
function M.restore(buf, saved)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_call(buf, function()
    for _, info in ipairs(saved or {}) do
      -- gliter.netrw's own maps are recreated by attach below; never put them back twice.
      if not (info.desc and info.desc:find('^gliter%.netrw')) then
        pcall(vim.fn.mapset, info.mode, false, info)
      end
    end
  end)
  M.attach(buf)
end

return M
