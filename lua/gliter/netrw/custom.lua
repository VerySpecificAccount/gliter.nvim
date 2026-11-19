--- The custom listing: a shell command whose output replaces the listing
--- netrw drew — `setup { listing = 'ls -ltrhF' }`, or 'ls -d */' to list
--- nothing but the directories, or any command at all (it runs in the
--- listed directory, through the user's shell, and its stdout becomes the
--- listing). The banner above the listing stays netrw's own — the
--- directory's name, the quick help, `I`'s toggling — so the buffer still
--- says where it is.
---
--- The command runs when netrw lists: on opening a directory, on every
--- re-list (`i`, `s`, `r`, `<C-l>`, a focus change, the refresh after a
--- gliter operation). A failed command falls back to netrw's own listing
--- with a notice — a typo'd flag never blanks the buffer — and is retried
--- on the next re-list.
---
--- The text is read by listing.lua's custom parser (see there), so every
--- feature — marks, the one-key commands, the `/` search, edit mode —
--- works on it; and netrw's own keys that take the entry off the line
--- cannot read it (`ls -l`'s columns are not a file name), so on a
--- custom-listing buffer they are replaced by parser-driven versions or
--- removed (see keymaps.lua). netrw re-installs them with its next re-list
--- of a plain style. The custom text is flat, so the window's style is
--- pinned to thin: `i` re-lists, and the custom listing comes back.
local config = require('gliter.netrw.config')
local listing = require('gliter.netrw.listing')
local ui = require('gliter.netrw.ui')

local M = {}

local WARN = vim.log.levels.WARN

--- Run the listing command in `dir`, synchronously — the custom text must
--- be in place before anything reads the buffer after a refresh (a reveal,
--- say; see listing.refresh_win, which re-renders for exactly that).
--- Returns the output's lines, or nil and a message when it failed.
---@param cmd string
---@param dir string
---@return string[]? lines, string? err
local function run(cmd, dir)
  local ok, res = pcall(function()
    return vim.system({ vim.o.shell, vim.o.shellcmdflag, cmd }, { cwd = dir, text = true }):wait()
  end)
  if not ok then
    return nil, ': ' .. tostring(res):gsub('\n', ' ')
  end
  if res.code ~= 0 then
    local msg = vim.trim((res.stderr or '') .. ' ' .. (res.stdout or '')):gsub('%s+', ' ')
    return nil, msg ~= '' and (': ' .. msg) or (' (exit ' .. res.code .. ')')
  end
  local out = vim.split(res.stdout or '', '\n', { plain = true })
  for i, l in ipairs(out) do
    out[i] = l:gsub('\r$', '')
  end
  while #out > 0 and out[#out]:match('^%s*$') do
    out[#out] = nil
  end
  return out
end

--- Ask netrw to re-list `win`'s buffer (netrw's own <C-l>): netrw's own
--- listing text and keys come back — the starting point render() replaces.
---@param win integer
local function relist(win)
  pcall(vim.api.nvim_win_call, win, function()
    pcall(vim.cmd.normal, { args = { vim.keycode('<Plug>NetrwRefresh') }, mods = { silent = true } })
  end)
end

--- Render the custom listing into `buf`, synchronously: run the configured
--- command in the directory `buf` lists and replace everything below the
--- banner with its output. Called when netrw has (re-)listed — the text
--- below the banner is netrw's own then — and directly after a refresh
--- (listing.refresh_win). With no `listing` configured, a custom-listing
--- buffer is returned to netrw's own listing instead. Rendered listings
--- stamp the buffer's changedtick (b:gliter_netrw_custom_tick): netrw
--- re-announces its filetype several times per re-list, and only a
--- re-list — which rewrites the listing, moving the tick — runs the
--- command again.
---@param buf integer
---@return boolean rendered
function M.render(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= 'netrw' then
    return false
  end
  local cmd = config.options.listing
  if type(cmd) ~= 'string' or cmd:match('^%s*$') then
    M.clear(buf)
    return false
  end
  if vim.b[buf].gliter_netrw_custom_tick == vim.b[buf].changedtick then
    return true -- nobody re-listed since the last render (success or failure)
  end
  local ctx = listing.context(buf)
  if not ctx then
    return false
  end
  if ctx.style ~= listing.THIN then
    -- A custom listing is flat: pin the window's style to thin, and re-read
    -- the context — in tree style the root would otherwise be the treetop,
    -- not the directory the window is really listing.
    pcall(function()
      vim.w[ctx.win].netrw_liststyle = listing.THIN
    end)
    ctx = listing.context(buf)
    if not ctx then
      return false
    end
  end

  local out, err = run(cmd, ctx.root)
  if not out then
    -- netrw's own listing stays (the re-list drew it; a render only ever
    -- sees buffers netrw just listed), and the next re-list retries.
    vim.b[buf].gliter_netrw_custom = nil
    vim.b[buf].gliter_netrw_custom_tick = vim.b[buf].changedtick
    ui.notify(('custom listing "%s" failed%s — netrw\'s own is shown.'):format(cmd, err), WARN)
    return false
  end

  vim.b[buf].gliter_netrw_custom = true
  local mod, ro = vim.bo[buf].modifiable, vim.bo[buf].readonly
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  local ok, werr = pcall(vim.api.nvim_buf_set_lines, buf, ctx.first - 1, -1, false, out)
  vim.bo[buf].modifiable = mod
  vim.bo[buf].readonly = ro
  if not ok then
    vim.b[buf].gliter_netrw_custom = nil
    vim.b[buf].gliter_netrw_custom_tick = nil
    ui.notify(('custom listing: cannot write the buffer (%s).'):format(tostring(werr)), WARN)
    return false
  end
  pcall(function()
    vim.bo[buf].modified = false
  end)
  vim.b[buf].gliter_netrw_custom_tick = vim.b[buf].changedtick
  -- the listing may have shrunk: keep the cursor inside it
  if vim.api.nvim_win_is_valid(ctx.win) then
    local row = vim.api.nvim_win_get_cursor(ctx.win)[1]
    local max = math.max(1, ctx.first - 1 + #out)
    if row > max then
      pcall(vim.api.nvim_win_set_cursor, ctx.win, { max, 0 })
    end
  end
  return true
end

local scheduled = {} ---@type table<integer, boolean>

--- Render `buf` soon, once per burst: netrw re-announces its filetype
--- several times around a re-list, and one render after the burst reads
--- what they all announced.
---@param buf integer
function M.schedule_render(buf)
  if scheduled[buf] then
    return
  end
  scheduled[buf] = true
  vim.schedule(function()
    scheduled[buf] = nil
    if vim.api.nvim_buf_is_valid(buf) then
      M.render(buf)
    end
  end)
end

--- Return `buf` to netrw's own listing (the `listing` option is gone):
--- clear the custom flag and re-list, which redraws netrw's text and
--- re-fires FileType — the keys re-attach as a plain listing's.
---@param buf integer
function M.clear(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or not vim.b[buf].gliter_netrw_custom then
    return
  end
  vim.b[buf].gliter_netrw_custom = nil
  vim.b[buf].gliter_netrw_custom_tick = nil
  local ctx = listing.context(buf)
  if ctx then
    relist(ctx.win)
  end
end

return M
