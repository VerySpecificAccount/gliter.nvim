--- Numbered bookmarks for netrw listings: nine directory slots that survive
--- restarts.
---
---   <C-1>..<C-9>   jump to their slot — or, when the slot is still empty,
---                  point it at this directory first, so the first press on
---                  a fresh slot plants it; a slot already pointing at this
---                  directory just stays here
---   <C-b>1..<C-b>9 point bookmark 1..9 at this directory (overwrites)
---   <C-b>0         clear all nine slots
---   <C-b>l         list the slots
---
--- "This directory" is the directory the listing acts on — the directory
--- under the cursor in tree style, the listed directory otherwise — the same
--- target `+` and `p` use. The slots live in
--- stdpath('data')/gliter/netrw-bookmarks.json, so they persist across
--- sessions; :GliterNetrwBookmarks lists them from anywhere.
---
--- The keys are Emacs' registers with the two-key prefix amputated: C-x r SPC
--- and C-x r j there, one C-<digit> here.

local fs = require('gliter.netrw.fs')
local listing = require('gliter.netrw.listing')
local ui = require('gliter.netrw.ui')

local M = {}

local WARN = vim.log.levels.WARN

local PATH = vim.fs.joinpath(vim.fn.stdpath('data'), 'gliter', 'netrw-bookmarks.json')

local slots = nil -- [1..9] = absolute path, loaded on first use

local function load()
  if slots then
    return slots
  end
  slots = {}
  local ok, lines = pcall(vim.fn.readfile, PATH)
  if ok and type(lines) == 'table' and lines[1] then
    local ok2, decoded = pcall(vim.json.decode, table.concat(lines, '\n'))
    if ok2 and type(decoded) == 'table' then
      for i = 1, 9 do
        if type(decoded[tostring(i)]) == 'string' then
          slots[i] = decoded[tostring(i)]
        end
      end
    end
  end
  return slots
end

local function save()
  local enc = {}
  for i = 1, 9 do
    if slots[i] then
      enc[tostring(i)] = slots[i]
    end
  end
  vim.fn.mkdir(vim.fs.dirname(PATH), 'p')
  pcall(vim.fn.writefile, vim.split(vim.json.encode(enc), '\n'), PATH)
end

--- The directory the listing acts on, in a netrw buffer.
---@return string? dir
local function here()
  local ctx, err = listing.context()
  if not ctx then
    ui.notify(err --[[@as string]], WARN)
    return nil
  end
  return listing.target_dir(ctx), ctx.win
end

--- Point bookmark `i` (1..9) at this directory.
---@param i integer
---@param planted? boolean notify that the next press jumps (set by `jump`)
function M.set(i, planted)
  local dir = here()
  if not dir then
    return
  end
  load()[i] = fs.normalize(dir)
  save()
  ui.notify(('Bookmark %d -> %s%s'):format(i, dir, planted and ' (press the key again to jump)' or ''))
end

--- Jump to bookmark `i`; an empty slot is pointed here first.
---
--- The jump is a plain `:edit <dir>` — the canonical way to open a directory:
--- Vim itself finds (and reuses) the buffer named after the directory, and
--- netrw renders the listing through its BufEnter machinery. NetrwBrowse is
--- deliberately NOT called directly: it juggles buffers itself (`enew!`, then
--- renaming the fresh buffer to the directory name) and that rename fails
--- whenever some other buffer already carries the name — buffers created by
--- `nvim <dir>`, `:e <dir>` or a previous jump are not in netrw's internal
--- reuse dictionary — leaving the window on an empty unnamed buffer.
---
--- Whatever buffer `:edit` lands on, gliter is re-attached to it right after:
--- FileType does not re-fire when a loaded netrw buffer is reused, so the
--- keys and decorations are (re-)installed explicitly. If `:edit` somehow
--- did not produce a netrw buffer, netrw's public LocalBrowseCheck — the
--- same entry its own `<CR>` uses — renders it as a second chance.
---@param i integer
function M.jump(i)
  local dir = load()[i]
  if not dir then
    M.set(i, true)
    return
  end
  local target, win = here()
  if not win then
    return
  end
  if not fs.is_dir(dir) then
    ui.notify(('Bookmark %d is gone: %s'):format(i, dir), WARN)
    return
  end
  if target and fs.same_file(dir, target) then
    return ui.notify(('Bookmark %d: already in %s.'):format(i, dir))
  end
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd.edit(vim.fn.fnameescape(dir))
  end)
  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    local function buf()
      return vim.api.nvim_win_get_buf(win)
    end
    -- `:edit` renders the listing through netrw's BufEnter machinery; if
    -- that hiccuped, ask netrw directly — the public entries its own keys
    -- use — before giving up.
    if vim.bo[buf()].filetype ~= 'netrw' then
      pcall(vim.fn['netrw#LocalBrowseCheck'], dir)
    end
    if vim.api.nvim_win_is_valid(win) and vim.bo[buf()].filetype ~= 'netrw' then
      pcall(vim.fn['netrw#Explore'], 0, 0, 0, dir)
    end
    if not vim.api.nvim_win_is_valid(win) then
      return
    end
    if vim.bo[buf()].filetype == 'netrw' then
      require('gliter.netrw.keymaps').attach(buf()) -- idempotent
      require('gliter.netrw.decor').watch(buf()) -- idempotent
    end
  end)
end

--- Clear all nine bookmarks.
function M.clear_all()
  load()
  for i = 1, 9 do
    slots[i] = nil
  end
  save()
  ui.notify('Bookmarks 1-9 cleared.')
end

--- List the nine slots.
function M.list()
  load()
  local out = {}
  for i = 1, 9 do
    out[#out + 1] = ('%d: %s'):format(i, slots[i] or '-')
  end
  ui.notify(table.concat(out, '\n'))
end

return M
