--- User-level actions. Every action starts from the current native netrw buffer.
local edit = require('gliter.netrw.edit')
local fs = require('gliter.netrw.fs')
local marks = require('gliter.netrw.marks')
local netrw = require('gliter.netrw.listing')
local paste = require('gliter.netrw.paste')
local ui = require('gliter.netrw.ui')

local M = {}

local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

---@return GliterNetrwCtx?
local function context()
  local ctx, err = netrw.context()
  if not ctx then
    ui.notify(err --[[@as string]], WARN)
  end
  return ctx
end

local function items(n)
  return ('%d item%s'):format(n, n == 1 and '' or 's')
end

---------------------------------------------------------------------------
-- mark (y = copy mark, m = move mark)
---------------------------------------------------------------------------

--- Toggle a copy/move mark on the entry under the cursor, or on each line of `range`.
--- The cursor moves down one line after a single-entry toggle, like fff.nvim.
---@param kind GliterNetrwMarkKind
---@param range? integer[]  {first, last} line range (Visual); nil = cursor line
function M.mark(kind, range)
  local ctx = context()
  if not ctx then
    return
  end

  local entries
  if range then
    entries = netrw.parse(ctx, range[1], range[2])
  else
    local e = netrw.entry_at_cursor(ctx)
    entries = e and { e } or {}
  end
  entries = vim.tbl_filter(function(e)
    return e.name ~= '.' and e.name ~= '..'
  end, entries)
  if #entries == 0 then
    return ui.notify('No file or directory here.', WARN)
  end

  local paths = vim.tbl_map(function(e)
    return e.path
  end, entries)
  marks.toggle(kind, paths)

  if not range then
    local line = vim.api.nvim_win_get_cursor(ctx.win)[1]
    if line < vim.api.nvim_buf_line_count(ctx.buf) then
      vim.api.nvim_win_set_cursor(ctx.win, { line + 1, 0 })
    end
  end

  local status = marks.status()
  ui.notify(status ~= '' and ('Marked: ' .. status) or 'No marks.')
end

---------------------------------------------------------------------------
-- paste
---------------------------------------------------------------------------

--- Apply the marks into the current directory: copy marks are copied and move marks
--- moved here; delete marks are deleted after confirmation; archive marks are packed
--- into an archive whose name you type — or extracted into a typed directory, when the
--- marked entry is itself an archive (see gliter.netrw.archive). Marks for entries that
--- completed are cleared.
function M.paste()
  local ctx = context()
  if not ctx then
    return
  end
  if marks.is_empty() then
    return ui.notify('Nothing marked. Mark with y (copy), m (move), d (delete) or z (archive), then p.', WARN)
  end
  -- `p` does not run shell commands: `!`- and `x`-marked entries stay for `!` and `x`.
  if #marks.list('copy') + #marks.list('move') + #marks.list('delete') + #marks.list('archive') == 0 then
    return ui.notify('Only shell/run marks here: press ! or x to run a command on them.', WARN)
  end

  local dest = netrw.target_dir(ctx)
  local total = { done = {}, skipped = {}, failed = {}, cancelled = false }
  local dirs = { dest }

  -- Deletions are irreversible, so they are confirmed before anything is touched.
  local doomed = marks.list('delete')
  if #doomed > 0 then
    local names = vim.tbl_map(fs.basename, doomed)
    local msg = ('Permanently delete %s?\n\n%s'):format(
      items(#doomed), table.concat(vim.list_slice(names, 1, 10), '\n'))
    if not ui.yes_no(msg) then
      return ui.notify('Nothing deleted. Marks kept.', WARN)
    end
  end

  for _, kind in ipairs({ 'copy', 'move' }) do
    local sources = marks.list(kind)
    if #sources > 0 then
      local res = paste.run(kind, sources, dest)
      for _, d in ipairs(res.done) do
        total.done[#total.done + 1] = { kind = kind, src = d.src, dst = d.dst }
        if kind == 'move' then
          dirs[#dirs + 1] = fs.dirname(d.src)
        end
      end
      vim.list_extend(total.skipped, res.skipped)
      vim.list_extend(total.failed, res.failed)
      total.cancelled = total.cancelled or res.cancelled
    end
  end

  -- Archive marks: entries that are themselves netrw-browsable archives are extracted
  -- (you type the directory), the rest are packed (you type the archive name; the
  -- extension picks the format). A mix does both, extraction first. Each half prompts,
  -- runs on its own and reports when it is done.
  local archived = marks.list('archive')
  if #archived > 0 then
    local archive = require('gliter.netrw.archive')
    local extract, pack = {}, {}
    for _, path in ipairs(archived) do
      if archive.is_archive(path) then
        extract[#extract + 1] = path
      else
        pack[#pack + 1] = path
      end
    end
    if #extract > 0 then
      archive.extract(ctx, extract)
    end
    if #pack > 0 then
      archive.create(ctx, pack)
    end
  end

  for _, path in ipairs(doomed) do
    local ok, err = fs.remove(path)
    if ok then
      total.done[#total.done + 1] = { kind = 'delete', src = path, dst = path }
      dirs[#dirs + 1] = fs.dirname(path)
    else
      total.failed[#total.failed + 1] = { src = path, err = tostring(err) }
    end
  end

  local consumed = vim.tbl_map(function(d)
    return d.src
  end, total.done)
  marks.remove(consumed)

  local first = total.done[1]
  netrw.refresh_dirs(dirs, first and { win = ctx.win, path = first.dst } or nil)

  local counts = { copy = 0, move = 0, delete = 0 }
  for _, d in ipairs(total.done) do
    counts[d.kind] = counts[d.kind] + 1
  end
  local parts = {}
  if counts.copy > 0 then
    parts[#parts + 1] = ('copied %d into %s'):format(counts.copy, dest)
  end
  if counts.move > 0 then
    parts[#parts + 1] = ('moved %d into %s'):format(counts.move, dest)
  end
  if counts.delete > 0 then
    parts[#parts + 1] = ('deleted %d'):format(counts.delete)
  end
  if #parts > 0 then
    ui.notify(table.concat(parts, '; ') .. '.')
  end
  if #total.skipped > 0 then
    ui.notify(('Skipped %s (%s).'):format(items(#total.skipped), total.skipped[1].reason), WARN)
  end
  for i, f in ipairs(total.failed) do
    if i > 3 then
      ui.notify(('…and %d more errors.'):format(#total.failed - 3), ERROR)
      break
    end
    ui.notify(('%s: %s'):format(fs.basename(f.src), f.err), ERROR)
  end
  if total.cancelled then
    ui.notify('Paste cancelled.', WARN)
  end
end

--- Toggle the mark on every entry in the listing (select all): Y copy, M move, gD
--- delete, Z archive. If all entries already carry that mark they are unmarked;
--- otherwise all get marked.
---@param kind GliterNetrwMarkKind
function M.mark_all(kind)
  local ctx = context()
  if not ctx then
    return
  end
  local paths = vim.tbl_map(function(e)
    return e.path
  end, netrw.all(ctx))
  if #paths == 0 then
    return ui.notify('Nothing to mark: the listing is empty.', WARN)
  end
  marks.toggle_all(kind, paths)
  local status = marks.status()
  ui.notify(status ~= '' and ('Marked: ' .. status) or 'No marks.')
end

function M.clear()
  marks.clear()
  ui.notify('Marks cleared.')
end

---------------------------------------------------------------------------
-- In-place edit (add / remove / rename)
---------------------------------------------------------------------------

--- Toggle in-place editing of the current netrw listing. See `gliter.netrw.edit`.
function M.edit_toggle()
  local ctx = context()
  if not ctx then
    return
  end
  edit.toggle(ctx)
end

return M
