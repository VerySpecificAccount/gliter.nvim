--- Single-key commands layered on the mark system.
---
--- The marks themselves (`y` copy, `m` move, `d` delete, `z` archive, and their
--- select-all forms) are applied by `p` (see gliter.netrw.actions). On top of them:
---
---   C  copy       marked entries (or the entry under the cursor) to a directory you type
---   R  rename     marked entries (or the entry under the cursor): move them to a
---                 directory, or give a single entry a new path
---   D  delete     marked entries (or the entry under the cursor), after confirmation
---   X  chmod      toggle the executable bit on the marked entries (or the entry
---                 under the cursor, or each entry of a Visual selection);
---                 directories are skipped
---   S  symlink    marked entries (or the entry under the cursor) into a directory
---   !  shell      run a shell command once on the `!`-marked entries (or the entry
---                 under the cursor), in a terminal window — interactive
---                 commands (sudo's password) included; `*` in the command
---                 stands for the files, otherwise they are appended
---   x  shell      the same command run one entry at a time: it runs on the first marked
---                 entry in a terminal, and the next entry starts only when that command
---                 exits; close the terminal to stop the rest of the queue
---   +  create     a file, or a directory when the name ends in `/` (parents included)
---   <C-g> cd      make the directory listed here the current working directory
---   %y %m %d %z %! %x  mark by regexp (copy / move / delete / archive / shell /
---                 one-at-a-time run), matched against the name as the
---                 listing shows it (`dir/`, `link@`, ...), highlighted live
---                 while you type
---   *. */ *@ **   mark by extension / directories / symlinks / executables, with the
---                 default kind (`star_kind`); a mark key in between — `*y.`, `*m/`,
---                 `*d@`, `*z*`, `*!*`, `*x.` — picks the kind for that press and
---                 makes it the default
---
--- "Marked entries" for C is the copy-marked set, for R the move-marked set; with no such
--- marks the command acts on the entry under the cursor. `!` prefers the shell-marked
--- set, `x` the run-marked one (set with `%x` or the `*x` family); both fall back to
--- every marked entry, then to the entry under the cursor. (The key letters, and most
--- of the ideas, are stolen from Emacs; every Neovim plugin ends up there eventually.)
local bit = require('bit')
local config = require('gliter.netrw.config')
local fs = require('gliter.netrw.fs')
local marks = require('gliter.netrw.marks')
local netrw = require('gliter.netrw.listing')
local paste = require('gliter.netrw.paste')
local ui = require('gliter.netrw.ui')

local M = {}

local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

--- The entry under the cursor, with the usual message when there is none.
---@param ctx GliterNetrwCtx
---@return GliterNetrwEntry?
local function at_cursor(ctx)
  local e = netrw.entry_at_cursor(ctx)
  if not e then
    ui.notify('No file or directory here.', WARN)
  end
  return e
end

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

--- Marked paths of `kind` (any kind when nil), else the entry under the cursor.
---@param ctx GliterNetrwCtx
---@param kind? GliterNetrwMarkKind
---@return string[]
local function targets(ctx, kind)
  local list = {}
  if kind then
    list = marks.list(kind)
  else
    list = marks.all()
  end
  if #list > 0 then
    return list
  end
  local e = netrw.entry_at_cursor(ctx)
  if e then
    return { e.path }
  end
  ui.notify('No file or directory here.', WARN)
  return {}
end

---@param ctx GliterNetrwCtx
---@param input string
---@return string
local function absolute(ctx, input)
  input = vim.fs.normalize(input) -- expands ~ and $VAR
  if input:sub(1, 1) == '/' or input:match('^%a:[/\\]') then
    return fs.normalize(input)
  end
  return fs.normalize(fs.join(ctx.root, input))
end

---@param ctx GliterNetrwCtx
---@param verb string
---@param n integer
---@return string?
local function ask_target(ctx, verb, n)
  local default = netrw.target_dir(ctx)
  if default:sub(-1) ~= '/' then
    default = default .. '/'
  end
  local input = ui.input(('%s %s to: '):format(verb, items(n)), default, 'dir')
  return input and absolute(ctx, input) or nil
end

---@param res { done: table[], skipped: table[], failed: table[], cancelled: boolean }
---@param summary string
---@param ctx GliterNetrwCtx
---@param dirs string[]
local function finish(res, summary, ctx, dirs)
  marks.remove(vim.tbl_map(function(d)
    return d.src
  end, res.done))
  local first = res.done[1]
  netrw.refresh_dirs(dirs, first and { win = ctx.win, path = first.dst } or nil)
  if #res.done > 0 then
    ui.notify(summary)
  end
  if #res.skipped > 0 then
    ui.notify(('Skipped %s (%s).'):format(items(#res.skipped), res.skipped[1].reason), WARN)
  end
  for i, f in ipairs(res.failed) do
    if i > 3 then
      ui.notify(('…and %d more errors.'):format(#res.failed - 3), ERROR)
      break
    end
    ui.notify(('%s: %s'):format(fs.basename(f.src), f.err), ERROR)
  end
  if res.cancelled then
    ui.notify('Cancelled.', WARN)
  end
end

--- Copy or move `srcs` to `target`: into it when it is a directory, otherwise (single
--- source only) to that new path, a "rename to a new name".
---@param ctx GliterNetrwCtx
---@param mode 'copy'|'move'
---@param srcs string[]
---@param target string
local function place(ctx, mode, srcs, target)
  local res
  local dest_dir = target
  if fs.is_dir(target) then
    res = paste.run(mode, srcs, target)
  elseif #srcs == 1 then
    local src = srcs[1]
    res = { done = {}, skipped = {}, failed = {}, cancelled = false }
    if fs.exists(target) then
      res.failed[1] = { src = src, err = target .. ' already exists and is not a directory' }
    else
      dest_dir = fs.dirname(target)
      local ok, err = fs.mkdirp(dest_dir)
      if ok then
        if mode == 'copy' then
          ok, err = fs.copy(src, target)
        else
          ok, err = fs.rename(src, target)
          if not ok then
            ok, err = fs.copy(src, target) -- other filesystem: copy, then drop the source
            if ok then
              ok, err = fs.remove(src)
            end
          end
        end
      end
      if ok then
        res.done[1] = { src = src, dst = target }
      else
        res.failed[1] = { src = src, err = tostring(err) }
      end
    end
  else
    if not ui.yes_no(('"%s" does not exist. Create it?'):format(target)) then
      return
    end
    local ok, err = fs.mkdirp(target)
    if not ok then
      return ui.notify(('%s: %s'):format(target, tostring(err)), ERROR)
    end
    res = paste.run(mode, srcs, target)
  end

  local dirs = { dest_dir, ctx.root }
  if mode == 'move' then
    for _, d in ipairs(res.done) do
      dirs[#dirs + 1] = fs.dirname(d.src)
    end
  end
  local verb = mode == 'copy' and 'copied' or 'moved'
  finish(res, ('%s %s into %s.'):format(verb, items(#res.done), dest_dir), ctx, dirs)
end

--- C: copy marked entries (or the entry under the cursor) to a typed directory.
function M.copy()
  local ctx = context()
  if not ctx then
    return
  end
  local srcs = targets(ctx, 'copy')
  if #srcs == 0 then
    return
  end
  local target = ask_target(ctx, 'Copy', #srcs)
  if target then
    place(ctx, 'copy', srcs, target)
  end
end

--- R: move marked entries (or the entry under the cursor) to a typed directory / new name.
function M.rename()
  local ctx = context()
  if not ctx then
    return
  end
  local srcs = targets(ctx, 'move')
  if #srcs == 0 then
    return
  end
  local target = ask_target(ctx, 'Move', #srcs)
  if target then
    place(ctx, 'move', srcs, target)
  end
end

---@param ctx GliterNetrwCtx
---@param paths string[]
local function delete_paths(ctx, paths)
  local names = vim.tbl_map(function(p)
    return fs.basename(p) .. (fs.is_dir(p) and '/' or '')
  end, paths)
  local msg = ('Permanently delete %s?\n\n%s%s'):format(
    items(#paths),
    table.concat(vim.list_slice(names, 1, 10), '\n'),
    #names > 10 and '\n…' or ''
  )
  if not ui.yes_no(msg) then
    return ui.notify('Nothing deleted.', WARN)
  end
  local res = { done = {}, skipped = {}, failed = {}, cancelled = false }
  local dirs = { ctx.root }
  for _, p in ipairs(paths) do
    local ok, err = fs.remove(p)
    if ok then
      res.done[#res.done + 1] = { src = p, dst = p }
      dirs[#dirs + 1] = fs.dirname(p)
    else
      res.failed[#res.failed + 1] = { src = p, err = tostring(err) }
    end
  end
  res.done[1] = nil -- nothing to reveal after a delete
  local removed = #paths - #res.failed
  marks.remove(paths)
  netrw.refresh_dirs(dirs, nil)
  if removed > 0 then
    ui.notify(('deleted %d.'):format(removed))
  end
  for i, f in ipairs(res.failed) do
    if i > 3 then
      ui.notify(('…and %d more errors.'):format(#res.failed - 3), ERROR)
      break
    end
    ui.notify(('%s: %s'):format(fs.basename(f.src), f.err), ERROR)
  end
end

--- D: delete marked entries (or the entry under the cursor) now.
function M.delete()
  local ctx = context()
  if not ctx then
    return
  end
  local paths = targets(ctx, 'delete')
  if #paths > 0 then
    delete_paths(ctx, paths)
  end
end

--- X: toggle the executable bit on every marked entry (or the entry under the
--- cursor, or — from Visual mode — each entry of the selection). Files only
--- (symlinks act on their target, like chmod): clearing the bit on a directory
--- would make it impossible to enter, so directories are skipped.
---@param range? integer[] {first, last} line range (Visual); nil = marks or cursor
function M.chmod(range)
  local ctx = context()
  if not ctx then
    return
  end
  local paths
  if range then
    paths = vim.tbl_map(function(e)
      return e.path
    end, netrw.parse(ctx, range[1], range[2]))
  else
    paths = targets(ctx)
  end
  if #paths == 0 then
    return
  end
  local made, cleared, dirs, failed, first_err = 0, 0, 0, 0, nil
  for _, p in ipairs(paths) do
    local st = vim.uv.fs_stat(p) -- follows symlinks, like chmod(1)
    if not st then
      failed, first_err = failed + 1, 'no longer exists: ' .. p
    elseif st.type == 'directory' then
      dirs = dirs + 1
    else
      local perm = bit.band(st.mode, 4095) -- 0o7777
      local new = bit.band(perm, 73) ~= 0 and bit.band(perm, bit.bnot(73)) or bit.bor(perm, 73) -- 0o111
      local ok, err = vim.uv.fs_chmod(p, new)
      if ok then
        if bit.band(new, 73) ~= 0 then
          made = made + 1
        else
          cleared = cleared + 1
        end
      else
        failed, first_err = failed + 1, ('%s: %s'):format(fs.basename(p), tostring(err))
      end
    end
  end
  netrw.refresh_dirs({ ctx.root }, nil)
  local parts = {}
  if made > 0 then
    parts[#parts + 1] = ('made executable: %d'):format(made)
  end
  if cleared > 0 then
    parts[#parts + 1] = ('made non-executable: %d'):format(cleared)
  end
  if dirs > 0 then
    parts[#parts + 1] = ('skipped %d director%s'):format(dirs, dirs == 1 and 'y' or 'ies')
  end
  if #parts > 0 then
    ui.notify(table.concat(parts, ', ') .. '.')
  end
  if failed > 0 then
    local msg = first_err or 'chmod failed'
    if failed > 1 then
      msg = msg .. (' (and %d more)'):format(failed - 1)
    end
    ui.notify(msg, ERROR)
  end
end

--- S: symlink marked entries (or the entry under the cursor) into a directory.
function M.symlink()
  local ctx = context()
  if not ctx then
    return
  end
  local srcs = targets(ctx)
  if #srcs == 0 then
    return
  end
  local target = ask_target(ctx, 'Symlink', #srcs)
  if not target then
    return
  end
  local single_name = #srcs == 1 and not fs.is_dir(target)
  local made, errs = 0, {}
  for _, src in ipairs(srcs) do
    local dst = single_name and target or fs.join(target, fs.basename(src))
    if fs.exists(dst) then
      errs[#errs + 1] = fs.basename(dst) .. ': already exists'
    else
      local ok = fs.mkdirp(fs.dirname(dst))
      local ok2, err = vim.uv.fs_symlink(src, dst)
      if ok and ok2 then
        made = made + 1
      else
        errs[#errs + 1] = ('%s: %s'):format(fs.basename(dst), tostring(err))
      end
    end
  end
  netrw.refresh_dirs({ ctx.root, single_name and fs.dirname(target) or target }, nil)
  if made > 0 then
    ui.notify(('linked %s.'):format(items(made)))
  end
  for i, e in ipairs(errs) do
    if i > 3 then
      break
    end
    ui.notify(e, ERROR)
  end
end

--- +: create a file, or a directory when the name ends in `/` (relative to this
--- listing, parents included) — the same convention as edit mode.
function M.create()
  local ctx = context()
  if not ctx then
    return
  end
  local input = ui.input('Create file, or directory ending in /: ')
  if not input then
    return
  end
  local path = fs.normalize(absolute({ root = netrw.target_dir(ctx) }, input))
  if fs.exists(path) then
    return ui.notify(path .. ' already exists.', WARN)
  end
  local ok, err
  if input:sub(-1) == '/' then
    ok, err = fs.mkdirp(path)
  else
    ok, err = fs.mkdirp(fs.dirname(path))
    if ok then
      ok, err = fs.touch(path)
    end
  end
  if not ok then
    return ui.notify(('%s: %s'):format(path, tostring(err)), ERROR)
  end
  netrw.refresh_dirs({ ctx.root }, { win = ctx.win, path = path })
  ui.notify('created ' .. input .. '.')
end

--- <C-g>: make the directory this netrw buffer lists the current working directory, with
--- a global `:cd` (netrw's own `c` is `:lcd`, and only changes the netrw window).
function M.cd_here()
  local ctx = context()
  if not ctx then
    return
  end
  vim.cmd('cd ' .. vim.fn.fnameescape(ctx.root))
  ui.notify('cwd: ' .. ctx.root)
end

---------------------------------------------------------------------------
-- opening entries from a custom listing (see custom.lua): netrw's own
-- <CR>/o/v/t/P/mouse/preview keys cannot read the custom text, so the
-- parser reads the entry and these open it.
---------------------------------------------------------------------------

--- <CR>/o/v/t on a custom listing: open the entry under the cursor — a
--- directory is browsed, a file edited — with `how` ('edit', 'split',
--- 'vsplit', 'tabedit'), the way netrw's own keys do on its listings.
---@param how 'edit'|'split'|'vsplit'|'tabedit'
function M.open(how)
  local ctx = context()
  if not ctx then
    return
  end
  local e = at_cursor(ctx)
  if not e then
    return
  end
  local ok, err = pcall(vim.cmd, how .. ' ' .. vim.fn.fnameescape(e.path))
  if not ok then
    ui.notify(err, ERROR)
  end
end

--- P (and the middle mouse) on a custom listing: open the entry under the
--- cursor in the previous window — the one the netrw window was entered
--- from. With no previous window (or when it is this one), a split is
--- opened instead; a directory is browsed in that window.
function M.open_prevwin()
  local ctx = context()
  if not ctx then
    return
  end
  local e = at_cursor(ctx)
  if not e then
    return
  end
  local prev = vim.fn.win_getid(vim.fn.winnr('#'))
  if not prev or prev == 0 or prev == ctx.win or not vim.api.nvim_win_is_valid(prev) then
    return M.open('split')
  end
  local ok, err = pcall(vim.api.nvim_win_call, prev, function()
    vim.cmd('edit ' .. vim.fn.fnameescape(e.path))
  end)
  if not ok then
    ui.notify(err, ERROR)
  end
end

--- The preview key on a custom listing (netrw's own `p`, relocated when
--- `paste` is `p`): preview the entry under the cursor in the preview
--- window — a file with :pedit, a directory as its listing.
function M.preview()
  local ctx = context()
  if not ctx then
    return
  end
  local e = at_cursor(ctx)
  if not e then
    return
  end
  pcall(vim.cmd, 'pclose')
  local ok, err = pcall(vim.cmd, 'pedit ' .. vim.fn.fnameescape(e.path))
  if not ok then
    ui.notify(err, ERROR)
  end
end

---------------------------------------------------------------------------
-- F: the file(1) report on the entry under the cursor
---------------------------------------------------------------------------

--- The float F's report lives in; q, <Esc> or <CR> closes it.
local file_win = nil ---@type integer?

local function file_close()
  if file_win and vim.api.nvim_win_is_valid(file_win) then
    pcall(vim.api.nvim_win_close, file_win, true)
  end
  file_win = nil
end

--- F: run the file command on the entry under the cursor and show its
--- report in a floating window — what the thing is, and the details file
--- has to tell about it (the magic behind the name, the mime type). On a
--- custom listing `qf` — netrw's own file-info key, which cannot read the
--- custom text — does the same.
function M.file()
  local ctx = context()
  if not ctx then
    return
  end
  local e = at_cursor(ctx)
  if not e then
    return
  end
  local ok, res = pcall(function()
    return vim.system({ 'file', '--', e.path }, { text = true }):wait()
  end)
  if not ok then
    return ui.notify('The file command is not available here.', ERROR)
  end
  local out = vim.trim((res.stdout or '') .. (res.stderr or ''))
  if out == '' then
    out = res.code == 0 and (e.path .. ': (no report)') or (e.path .. ': file exited with ' .. res.code)
  end
  local lines = vim.split(out, '\n', { plain = true })

  file_close()
  local width = 1
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, math.max(24, vim.o.columns - 6))
  local height = math.max(1, math.min(#lines, math.floor(vim.o.lines * 0.6)))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local okwin, win = pcall(vim.api.nvim_open_win, buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    border = 'rounded',
    title = ' file ',
    title_pos = 'center',
    style = 'minimal',
    zindex = 300,
  })
  if not okwin then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return ui.notify('Cannot open a floating window for the report.', ERROR)
  end
  file_win = win
  for _, k in ipairs({ 'q', '<Esc>', '<CR>' }) do
    vim.keymap.set('n', k, file_close, {
      buffer = buf,
      silent = true,
      desc = 'gliter.netrw: close the file report',
    })
  end
end

---------------------------------------------------------------------------
-- shell commands: `!` runs the command once on everything, `x` one entry at a time
---------------------------------------------------------------------------

--- The command line for `paths`: a `*` in `cmd` is replaced with them, otherwise they
--- are appended. Paths inside `root` are passed as plain names.
---@param cmd string
---@param root string
---@param paths string[]
---@return string
local function build_cmd(cmd, root, paths)
  local quoted = vim.tbl_map(function(p)
    return vim.fn.shellescape(fs.dirname(p) == root and fs.basename(p) or p)
  end, paths)
  local files = table.concat(quoted, ' ')
  if cmd:find('*', 1, true) then
    return (cmd:gsub('%*', (files:gsub('%%', '%%%%'))))
  end
  return cmd .. ' ' .. files
end

--- Paths `!` and `x` act on: the `!`-marked entries, else every marked entry, else the
--- entry under the cursor.
---@param ctx GliterNetrwCtx
---@return string[]
local function shell_paths(ctx)
  local paths = marks.list('shell')
  if #paths == 0 then
    paths = targets(ctx)
  end
  return paths
end

--- Paths `x` acts on: the `x`-marked (run) entries, else the same fallbacks as `!`.
---@param ctx GliterNetrwCtx
---@return string[]
local function run_paths(ctx)
  local paths = marks.list('run')
  if #paths == 0 then
    paths = shell_paths(ctx)
  end
  return paths
end

--- The last command typed for `!` or `x`; both prompts offer it as the default.
local last_cmd = nil

--- State of a running `!` command: its terminal window, and whether the
--- command is still running (the window stays after it exits — its output
--- is there to read; close it, or run another `!`, when done with it).
local bang = nil ---@type { win: integer, running: boolean }?

--- !: run a shell command once on every `!`-marked entry; with none so marked, on any
--- marked entries; with nothing marked, on the entry under the cursor. The
--- command runs in a terminal window — a bottom split, like `x`'s — so
--- interactive commands work: sudo's password prompt, read, less. `*` in
--- the command stands for the files, otherwise they are appended. The
--- window stays up when the command is done; the listing refreshes when
--- the command exits.
function M.shell()
  local ctx = context()
  if not ctx then
    return
  end
  if bang and bang.running and vim.api.nvim_win_is_valid(bang.win) then
    return ui.notify('A ! command is still running; close its terminal to stop it.', WARN)
  end
  local paths = shell_paths(ctx)
  if #paths == 0 then
    return
  end
  local cmd = ui.input(('! on %s: '):format(items(#paths)), last_cmd)
  if not cmd then
    return
  end
  last_cmd = cmd
  local full = build_cmd(cmd, ctx.root, paths)
  -- the window it runs in: a finished ! terminal is reused (its buffer is
  -- wiped by this very reuse) — unless the window was since given
  -- something else to show — else a new bottom split is opened
  local win
  if bang and vim.api.nvim_win_is_valid(bang.win) then
    local old = vim.api.nvim_win_get_buf(bang.win)
    if vim.bo[old].buftype == 'terminal' then
      win = bang.win
    end
  end
  if not win then
    local height = math.max(4, math.min(12, math.floor(vim.o.lines * 0.4)))
    if not pcall(vim.cmd, 'botright ' .. height .. 'split') then
      return ui.notify('Not enough room for a terminal window; make the netrw window taller.', ERROR)
    end
    win = vim.api.nvim_get_current_win()
  end
  local root = ctx.root
  bang = { win = win, running = true }
  -- focus the terminal before starting the job: an interactive command
  -- reads from the keyboard right away (startinsert puts the line through
  -- to the terminal itself)
  pcall(vim.api.nvim_set_current_win, win)
  vim.api.nvim_win_call(win, function()
    local oknew = pcall(vim.cmd, 'enew')
    if not oknew then
      if bang and bang.win == win then
        bang = nil
      end
      return ui.notify('Cannot make room for the command\'s terminal.', ERROR)
    end
    local ok = pcall(vim.fn.termopen, { vim.o.shell, vim.o.shellcmdflag, full }, {
      cwd = root,
      on_exit = function()
        vim.schedule(function()
          if bang and bang.win == win then
            bang.running = false
          end
          netrw.refresh_dirs({ root }, nil)
        end)
      end,
    })
    if not ok then
      if bang and bang.win == win then
        bang = nil
      end
      return ui.notify('Cannot open a terminal for the command.', ERROR)
    end
    -- wiping on hide keeps the buffer count down; closing the window kills
    -- the job and the state above lets the next ! open a fresh one
    vim.bo.bufhidden = 'wipe'
  end)
  pcall(vim.cmd, 'startinsert')
end

--- State of a running `x` chain: the queue of entries, the command, and the terminal
--- window each command runs in.
local seq = nil

--- Start the next entry of an `x` chain, or finish/cancel the chain.
local function seq_next()
  if not seq then
    return
  end
  seq.i = seq.i + 1
  if seq.i > #seq.queue then
    local s = seq
    seq = nil
    ui.notify(('ran the command on all %d.'):format(#s.queue))
    netrw.refresh_dirs({ s.root }, nil)
    return
  end
  if not vim.api.nvim_win_is_valid(seq.win) then
    seq = nil
    return ui.notify('One-at-a-time run stopped: the terminal was closed.', WARN)
  end
  local path = seq.queue[seq.i]
  local full = build_cmd(seq.cmd, seq.root, { path })
  ui.notify(('[%d/%d] %s'):format(seq.i, #seq.queue, full))
  vim.api.nvim_win_call(seq.win, function()
    -- The previous terminal buffer has `bufhidden=wipe` and disappears with this enew.
    vim.cmd('enew')
    local ok = pcall(vim.fn.termopen, { vim.o.shell, vim.o.shellcmdflag, full }, {
      cwd = seq.root,
      on_exit = function()
        vim.schedule(function()
          if seq then
            seq_next()
          end
        end)
      end,
    })
    if not ok then
      seq = nil
      return ui.notify('Cannot open a terminal for the one-at-a-time run.', ERROR)
    end
    -- Wiping on hide keeps only the current (and, when finished, the last) terminal
    -- buffer around; closing the window kills the job and stops the queue.
    vim.bo.bufhidden = 'wipe'
  end)
end

--- x: apply, one at a time. Runs a command on the first of the `x`-marked
--- entries (else `!`-marked, else any marked, else the entry under the cursor)
--- in a terminal window; when that command exits, the next entry runs, until
--- the queue is empty. `*` in the command stands for the single entry being
--- run. Close the terminal window to stop the queue.
function M.run_each()
  if seq then
    return ui.notify('A one-at-a-time run is still going; close its terminal to stop it.', WARN)
  end
  local ctx = context()
  if not ctx then
    return
  end
  local paths = run_paths(ctx)
  if #paths == 0 then
    return
  end
  local cmd = ui.input(('x on each of %s (command; * = the entry): '):format(items(#paths)), last_cmd)
  if not cmd then
    return
  end
  last_cmd = cmd
  local height = math.max(4, math.min(12, math.floor(vim.o.lines * 0.4)))
  if not pcall(vim.cmd, 'botright ' .. height .. 'split') then
    return ui.notify('Not enough room for a terminal window; make the netrw window taller.', ERROR)
  end
  seq = { queue = paths, i = 0, cmd = cmd, root = ctx.root, win = vim.api.nvim_get_current_win() }
  ui.notify(('Running on %d, one at a time; close the terminal to stop.'):format(#paths))
  seq_next()
end

---------------------------------------------------------------------------
-- bulk marking by pattern
---------------------------------------------------------------------------

---@param ctx GliterNetrwCtx
---@param kind GliterNetrwMarkKind
---@param pred fun(e: GliterNetrwEntry): boolean
---@param what string
local function mark_where(ctx, kind, pred, what)
  local paths = {}
  for _, e in ipairs(netrw.all(ctx)) do
    if pred(e) then
      paths[#paths + 1] = e.path
    end
  end
  if #paths == 0 then
    return ui.notify(('No entries match %s.'):format(what), WARN)
  end
  marks.set(kind, paths)
  ui.notify(('%s for %s: %s.'):format(items(#paths), kind, what))
end

--- %y / %m / %d / %z / %! / %x: mark every entry matching a Vim regexp —
--- the same regexp, and the same text, a `/` search in the listing would
--- match (directories carry their trailing `/`, symlinks their `@`,
--- executables their `*`, so `.\+\/` marks exactly the directories). While
--- you type, the matches are highlighted live and the prompt counts them.
---@param kind GliterNetrwMarkKind
function M.mark_regexp(kind)
  local ctx = context()
  if not ctx then
    return
  end
  local search = require('gliter.netrw.search')
  local entries, pat = search.prompt(ctx, ('Mark %s by regexp: '):format(kind))
  if not entries then
    if pat then
      ui.notify('Invalid regexp: ' .. pat, ERROR)
    end
    return
  end
  if #entries == 0 then
    return ui.notify(('No entries match /%s/.'):format(pat), WARN)
  end
  marks.set(kind, vim.tbl_map(function(e)
    return e.path
  end, entries))
  ui.notify(('%s for %s: /%s/.'):format(items(#entries), kind, pat))
end

--- `*` family: mark every entry matching a family — `*.` by extension, `*/`
--- directories, `*@` symlinks, `**` executables — with the default kind (`star_kind`).
--- A kind letter in between (`*y.`, `*m/`, `*d@`, `*z*`, `*!*`, `*x.`) marks with that
--- kind instead and makes it the family's new default, all in one sequence.
---@param what 'dirs'|'links'|'exec'|'ext'
---@param kind? GliterNetrwMarkKind
function M.mark_star(what, kind)
  local ctx = context()
  if not ctx then
    return
  end
  if kind then
    config.options.star_kind = kind
  else
    kind = config.options.star_kind or 'copy'
  end
  if what == 'dirs' then
    mark_where(ctx, kind, function(e)
      return e.is_dir
    end, 'directories')
  elseif what == 'links' then
    mark_where(ctx, kind, function(e)
      local st = fs.lstat(e.path)
      return st ~= nil and st.type == 'link'
    end, 'symlinks')
  elseif what == 'exec' then
    mark_where(ctx, kind, function(e)
      local st = vim.uv.fs_stat(e.path)
      return st ~= nil and st.type == 'file' and bit.band(st.mode, 73) ~= 0
    end, 'executables')
  elseif what == 'ext' then
    local ext = ui.input('Mark extension: .')
    if not ext then
      return
    end
    ext = ext:gsub('^%.', ''):lower()
    mark_where(ctx, kind, function(e)
      return not e.is_dir and (e.name:lower():match('%.([^.]+)$') or '') == ext
    end, '.' .. ext)
  end
end

return M
