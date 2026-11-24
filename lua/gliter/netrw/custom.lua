--- The custom listing: a shell command whose output becomes the listing —
--- `setup { listing = 'ls -ltrhF' }`, 'ls -d */' to list nothing but the
--- directories, `tree -CF --dirsfirst` for an outline, or any command at
--- all (it runs in the listed directory, through the user's shell, and
--- its stdout becomes the listing). The banner above the listing stays
--- netrw's own — the directory's name, the quick help — so the buffer
--- still says where it is.
---
--- The custom listing lives on netrw's own `i` cycle: netrw steps its
--- listing styles thin > long > wide > tree, and this module adds its
--- slot after tree — `i` steps into the custom listing, `i` again
--- steps back to thin (the key is installed through g:Netrw_UserMaps,
--- so netrw itself re-installs it on every browse; see netrw.lua), and
--- `listing_default` starts every new window already in the slot. A
--- failed command falls back to netrw's own listing with a notice and
--- is retried on the next re-list.
---
--- Colors: a known command is asked for its colored output (`ls
--- --color=always`, `tree -C`) when the listing carries no color flag of
--- its own, and any command's ANSI escape sequences are stripped from
--- the text and laid back as highlights (see color.lua) — the listing
--- shows its colors the way a terminal, or Emacs' dired, shows them.
--- netrw's own listing colors (netrwDir, netrwExe, ...) are fitted to
--- the shapes netrw itself draws — on another command's text they
--- misfire — so while the custom listing is on they are stood down, and
--- a re-list of netrw's own (when no `listing` is configured) brings
--- them back.
---
--- The text is read by listing.lua's custom parser (see there), so every
--- feature — marks, the one-key commands, the `/` search, edit mode —
--- works on it; and netrw's own keys that take the entry off the line
--- cannot read it (`ls -l`'s columns are not a file name), so on a
--- custom-listing buffer they are replaced by parser-driven versions or
--- removed (see keymaps.lua). The custom text is flat, so the window's
--- style is pinned to thin: `i` re-lists, and the custom listing comes
--- back.
local config = require('gliter.netrw.config')
local listing = require('gliter.netrw.listing')
local ui = require('gliter.netrw.ui')

local M = {}

local WARN = vim.log.levels.WARN

-- The last failure notice shown, per listing command: netrw re-lists its
-- buffers often (every focus change, every buffer switch back), and a
-- listing command that is broken on this machine fails on every one of
-- them — a notice each time reads as an error loop. It is said once per
-- message; the silent retry on every re-list stays (the command may heal
-- — an eza update, a PATH fix — and the listing comes back on its own).
local last_failure = nil ---@type string?

-- The flag that asks a known command for its colored output, by first
-- word: appended when the user's command carries no color flag of its
-- own (and `listing_color` is on). Anything not here runs verbatim —
-- its ANSI output, should it send any, is read all the same.
local COLOR_FLAG = {
  ls = ' --color=always', vdir = ' --color=always', dir = ' --color=always',
  fd = ' --color=always', fdfind = ' --color=always',
  eza = ' --color=always', exa = ' --color=always', lsd = ' --color=always',
  rg = ' --color=always', ripgrep = ' --color=always',
  grep = ' --color=always', egrep = ' --color=always', fgrep = ' --color=always',
  tree = ' -C',
}

--- The listing command with its color flag added, when one is known for
--- it, none sits in the command already, and colors are on: `ls -ltrhF`
--- runs as `ls -ltrhF --color=always`, `tree --dirsfirst` as
--- `tree --dirsfirst -C`. A command that names its own color intent —
--- `--color=never` included — is obeyed as written.
---@param cmd string
---@return string
local function with_color(cmd)
  if config.options.listing_color == false then
    return cmd
  end
  local first = cmd:match('^%s*(%S+)') or ''
  local flag = COLOR_FLAG[first]
  if not flag then
    return cmd
  end
  if cmd:find('%-%-col') then -- --color / --colour, any value
    return cmd
  end
  if first == 'tree' and cmd:match('%s%-[a-zA-Z]*C') then -- -C, or a cluster with it
    return cmd
  end
  return cmd .. flag
end

-- netrw's own listing syntax: the groups that paint entries. Stood down
-- while the custom listing is on (their patterns are fitted to the
-- shapes netrw draws, and misfire on another command's text); a re-list
-- of netrw's own brings them back — and the toggle-off makes sure of it.
local ENTRY_SYNTAX =
  'netrwPlain netrwSpecial netrwDir netrwSizeDate netrwSymLink netrwExe '
  .. 'netrwTreeBar netrwTreeBarSpace netrwClassify netrwDateSep netrwTime '
  .. 'netrwTimeSep netrwSlash netrwLink netrwSpecFile netrwBak netrwCompress '
  .. 'netrwCoreDump netrwLex netrwYacc netrwData netrwDoc netrwHdr netrwLib '
  .. 'netrwMakeFile netrwObj netrwPix netrwTags netrwTilde netrwTmp'

---@param buf integer
local function clear_syntax(buf)
  vim.api.nvim_buf_call(buf, function()
    pcall(vim.cmd, 'silent! syntax clear ' .. ENTRY_SYNTAX)
  end)
end

--- Bring netrw's own listing colors back (the custom listing is off
--- again): netrw re-fires its filetype around a re-list, and the syntax
--- rides back with it — this makes sure of it whatever the ordering.
---@param buf integer
local function restore_syntax(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= 'netrw' then
    return
  end
  vim.api.nvim_buf_call(buf, function()
    pcall(function()
      vim.b.current_syntax = nil
      vim.cmd('silent! runtime syntax/netrw.vim')
    end)
  end)
end

--- eza/exa print NOTHING when their output is a pipe and they were
--- given no path to list (v0.23's behavior: stdout not a terminal and no
--- operand means nothing to do) — and this plugin's shell is always a
--- pipe. A command of that family that carries no path operand gets ` .`
--- appended, so it lists the listed directory explicitly and its output
--- survives the pipe. An operand that names a path (absolute, `.`/`..`,
--- or an entry of `dir`) means the command lists it already — nothing
--- is appended.
---@param cmd string
---@param dir string
---@return string
local function eza_dot(cmd, dir)
  local first = cmd:match('^%s*(%S+)') or ''
  local base = first:match('[^/]+$') or first
  if base ~= 'eza' and base ~= 'exa' then
    return cmd
  end
  local saw_path = false
  local n = 0
  for arg in cmd:gmatch('%S+') do
    n = n + 1
    if n > 1 and arg ~= '' then
      if arg == '.' or arg == '..' or arg:sub(1, 1) == '/' or arg:sub(1, 2) == './' or arg:sub(1, 3) == '../' then
        saw_path = true
      elseif not arg:match('^%-') and not arg:match('[%*%?%[%]~$]') then
        -- a plain word: a flag's value (--sort name) or a path — the
        -- filesystem decides, the same way the shell's word would
        if vim.uv.fs_stat(dir .. '/' .. arg) then
          saw_path = true
        end
      end
    end
  end
  if saw_path then
    return cmd
  end
  return cmd .. ' .'
end

--- Run the listing command in `dir`, synchronously — the custom text must
--- be in place before anything reads the buffer after a refresh (a reveal,
--- say; see listing.refresh_win, which re-renders for exactly that).
--- `TERM` is set to a color terminal when the session has none (headless,
--- `TERM=dumb`): GNU ls and its kin refuse to colorize — `--color=always`
--- included — for a terminal they cannot know, and a listing asked for
--- its colors should get them. Returns the output's lines, or nil and a
--- message when it failed.
---@param cmd string
---@param dir string
---@return string[]? lines, string? err
local function run(cmd, dir)
  local env = nil
  if config.options.listing_color ~= false then
    local term = vim.env.TERM or ''
    if term == '' or term == 'dumb' then
      env = { TERM = 'xterm-256color' }
    end
  end
  local ok, res = pcall(function()
    return vim.system({ vim.o.shell, vim.o.shellcmdflag, cmd }, { cwd = dir, text = true, env = env }):wait()
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
--- banner with its output. Called from settle when the window's
--- gliter_netrw_liststyle sentinel (== 4) is set, meaning the user has
--- cycled `i` into the custom slot. Rendered listings stamp the buffer's
--- changedtick (b:gliter_netrw_custom_tick): netrw re-announces its
--- filetype several times per re-list, and only a re-list — which
--- rewrites the listing, moving the tick — runs the command again.
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
  local ctx = listing.context(buf)
  if not ctx then
    return false
  end
  -- Only render when the window is in the custom style slot (set by `i`)
  if not vim.w[ctx.win].gliter_netrw_liststyle then
    return false
  end
  if vim.b[buf].gliter_netrw_custom_tick == vim.b[buf].changedtick then
    return true -- nobody re-listed since the last render (success or failure)
  end
  -- Custom listing is flat text; force netrw to thin so its root tracking
  -- stays correct (tree style would use the treetop, not the listed dir).
  if ctx.style ~= listing.THIN then
    pcall(function() vim.w[ctx.win].netrw_liststyle = listing.THIN end)
    ctx = listing.context(buf)
    if not ctx then
      return false
    end
  end

  local out, err = run(eza_dot(with_color(cmd), ctx.root), ctx.root)
  if not out then
    -- netrw's own listing stays (the re-list drew it; a render only ever
    -- sees buffers netrw just listed), and the next re-list retries.
    vim.b[buf].gliter_netrw_custom = nil
    vim.b[buf].gliter_netrw_custom_tick = vim.b[buf].changedtick
    require('gliter.netrw.color').clear(buf)
    local msg = ('custom listing "%s" failed%s — netrw\'s own is shown.'):format(cmd, err)
    if msg ~= last_failure then
      last_failure = msg
      ui.notify(msg, WARN)
    end
    return false
  end
  last_failure = nil

  -- ANSI escapes out of the text, their colors back as highlights
  local color = require('gliter.netrw.color')
  local plain, runs = {}, {}
  for i, l in ipairs(out) do
    local p, r = color.strip(l)
    plain[i], runs[i] = p, r
  end

  vim.b[buf].gliter_netrw_custom = true
  local mod, ro = vim.bo[buf].modifiable, vim.bo[buf].readonly
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false
  local ok, werr = pcall(vim.api.nvim_buf_set_lines, buf, ctx.first - 1, -1, false, plain)
  vim.bo[buf].modifiable = mod
  vim.bo[buf].readonly = ro
  if not ok then
    vim.b[buf].gliter_netrw_custom = nil
    vim.b[buf].gliter_netrw_custom_tick = nil
    ui.notify(('custom listing: cannot write the buffer (%s).'):format(tostring(werr)), WARN)
    return false
  end
  -- A command that succeeds but prints nothing this plugin can read
  -- (a different column layout, a broken flag, output on stderr only)
  -- would leave a buffer of text with no entries in it — every key a
  -- no-op and nothing to open. The parser is the judge: when it finds
  -- no entries in what was written while the directory itself is not
  -- empty, the whole render is rolled back and netrw's own listing is
  -- put back, with the reason said once.
  local fs = require('gliter.netrw.fs')
  local after = listing.context(buf)
  local n = after and #listing.parse(after, after.first, vim.api.nvim_buf_line_count(buf)) or 0
  if n == 0 and #fs.list(ctx.root) > 0 then
    -- the command succeeded but printed nothing the parser can read:
    -- fall back to netrw's own listing for this re-list; the next
    -- re-list will retry the command.
    vim.b[buf].gliter_netrw_custom = nil
    vim.b[buf].gliter_netrw_custom_tick = vim.b[buf].changedtick
    require('gliter.netrw.color').clear(buf)
    relist(ctx.win)
    local now = vim.api.nvim_win_is_valid(ctx.win) and vim.api.nvim_win_get_buf(ctx.win) or buf
    restore_syntax(now)
    ui.notify(('custom listing "%s" printed nothing readable — netrw\'s own is shown.'):format(cmd), WARN)
    return false
  end
  color.clear(buf)
  color.apply(buf, ctx.first, runs)
  -- netrw's own entry colors are stood down: their patterns read
  -- netrw's shapes, not this command's, and misfire on them
  clear_syntax(buf)
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
  require('gliter.netrw.color').clear(buf)
  local ctx = listing.context(buf)
  if ctx then
    relist(ctx.win)
    local now = vim.api.nvim_win_is_valid(ctx.win) and vim.api.nvim_win_get_buf(ctx.win) or buf
    restore_syntax(now)
  end
end

return M
