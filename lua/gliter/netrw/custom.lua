--- A listing of your own: `setup { listing = 'ls -ltrhF' }` (or `'ls -d */'`,
--- `'ls -m'`, any command) has netrw render the directory the way it always
--- does — the banner, the buffer, every netrw key that works off the
--- directory — and then replaces the listing lines with the command's output,
--- run in that directory. gliter's marks, `%`-marks, `*`-families, `p`, `C`,
--- `R`, `D`, `!`, `x`, `F` and the rest keep working: the parser (see
--- listing.lua) finds the entries in the custom text, wherever the command
--- put them — one per line, comma-separated (`ls -m`), or in columns
--- (`ls -C`).
---
--- What the command prints decides what the listing shows, sorting included:
--- netrw's `s`/`r` and `i` re-render underneath and are replaced again (the
--- one exception is tree style, which turns the custom listing off — its
--- `| `-indented format belongs to netrw alone; `i` cycles back to thin and
--- the custom listing returns). What the command costs, the listing costs:
--- it runs on every re-list, synchronously — `ls` is instant, anything that
--- talks to the network will not be.
---
--- netrw's own keys that read the entry under the cursor off the line text
--- (Enter, `o`, `v`, `t`, `P`, the preview, `mf` and the rest) cannot read
--- `ls -l`'s columns, so gliter takes them over on custom-listing buffers
--- and runs them off its own parser (see keymaps.lua) — Enter still opens,
--- `o`/`v`/`t` still split, the preview key still previews. `E` (in-place
--- editing) needs the plain listing and says so instead. And `../` is
--- whatever the command makes of it: plain `ls` prints no dot entries at
--- all, so going up stays on netrw's own `-` (and `u`), which work off the
--- buffer's directory and never cared about the text.
local config = require('gliter.netrw.config')
local fs = require('gliter.netrw.fs')
local netrw = require('gliter.netrw.listing')
local ui = require('gliter.netrw.ui')

local M = {}

--- Is `buf` showing a custom listing?
---@param buf integer
---@return boolean
function M.active(buf)
  return vim.b[buf] and vim.b[buf].gliter_netrw_custom == true
end

--- Run the configured command in `ctx.root` and replace everything below the
--- banner with its output. Called after every netrw re-list (the FileType
--- hook in netrw.lua) and synchronously from listing.refresh_win(), so a
--- refresh_dirs() reveal lands on the custom text.
---
--- Deduplicated by b:changedtick: netrw re-announces its filetype several
--- times per re-list, and our own replacement bumps the tick itself — only
--- a tick we did not produce re-runs the command.
---@param buf integer
function M.render(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local cmd = config.options.listing
  if not cmd or cmd == '' then
    vim.b[buf].gliter_netrw_custom = nil
    return
  end
  if vim.b[buf].gliter_netrw_editing then
    return -- the listing is being edited; netrw's re-render already restored its text
  end
  local ctx = netrw.context(buf)
  if not ctx or ctx.style == netrw.TREE then
    vim.b[buf].gliter_netrw_custom = nil
    return
  end
  if M.active(buf) and vim.b[buf].gliter_netrw_custom_tick == vim.b[ctx.buf].changedtick then
    return -- our own render, or nothing changed since the last one
  end
  -- remember where the cursor is, so the replacement can put it back
  local entry = netrw.entry_at_cursor(ctx)
  local cur = vim.api.nvim_win_get_cursor(ctx.win)[1]
  local res
  local ok = pcall(function()
    res = vim.system({ vim.o.shell, vim.o.shellcmdflag, cmd }, { cwd = ctx.root, text = true }):wait()
  end)
  if not ok or not res or (res.code ~= 0 and (res.stdout or '') == '') then
    vim.b[buf].gliter_netrw_custom = nil
    return ui.notify(('listing: the command failed%s'):format(res and res.code ~= 0 and (' (exit ' .. res.code .. ')') or ''),
      vim.log.levels.ERROR)
  end
  local lines = vim.split(res.stdout or '', '\n', { plain = true })
  if lines[#lines] == '' then
    lines[#lines] = nil
  end
  -- Replace below the banner. netrw leaves its buffers nomodifiable,
  -- nomodified and readonly (the W10 a plain write would warn with); undo
  -- is turned off around the write so the replacement never becomes an undo
  -- step on top of netrw's own. The write itself is guarded: a render that
  -- lands while netrw is mid-re-list (it re-lists on every window re-entry,
  -- g:netrw_fastbrowse <= 1) finds the buffer locked and steps aside — the
  -- re-list's own FileType announce renders again.
  local modifiable = vim.bo[buf].modifiable
  local readonly = vim.bo[buf].readonly
  local undolevels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  local written = pcall(vim.api.nvim_buf_set_lines, buf, ctx.first - 1, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].readonly = readonly
  vim.bo[buf].undolevels = undolevels
  if not written then
    return
  end
  vim.bo[buf].modified = false
  vim.b[buf].gliter_netrw_custom = true
  vim.b[buf].gliter_netrw_custom_tick = vim.b[buf].changedtick
  -- cursor back where it was: on the same entry when it is still listed,
  -- on the same line (clamped) otherwise
  local count = vim.api.nvim_buf_line_count(buf)
  if not (entry and netrw.reveal(ctx.win, entry.path)) then
    vim.api.nvim_win_set_cursor(ctx.win, { math.min(cur, count), 0 })
  end
end

return M
