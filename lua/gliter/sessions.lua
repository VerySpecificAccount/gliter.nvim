--- gliter.sessions — :mksession with a memory.
---
--- WHAT IT DOES
---   * :GliterSessionSave [name] — <Leader>ss. The session file is
---     written where :mksession writes it, only by name: into the
---     project's root (the directory you were editing) — Session.vim
---     by default, <name>.vim for a named one — and the session is
---     REMEMBERED: its name, its file, its directory, and when. Saving
---     again under the same name UPDATES that session (mksession!).
---   * :GliterSessions — <Leader>sl. Every session gliter knows about,
---     most recently used first, in a floating window:
---       <CR>   activate it — :source the session file, whose own cd,
---              windows, buffers and folds come with it
---       d      delete it — it asks first, then drops the registry
---              entry AND the session file
---       j/k    walk the list (it is a plain buffer: gg, G, / all work)
---       q      close
---   * :GliterSessionLoad [name] and :GliterSessionDelete [name] — the
---     same two things without the window. A name picks the session of
---     that name in the current directory first, then anywhere.
---   The registry lives in stdpath('data')/gliter/sessions.json. The
---   session files are plain :mksession output — `:source Session.vim`
---   works with or without gliter.
---
--- USAGE (from your init.lua)
---   require('gliter.sessions').setup()               -- defaults
---   require('gliter.sessions').setup { file_name = 'Session.lua' }
---   require('gliter').setup { sessions = true }      -- through gliter

local M = {}

M.did_setup = false

local ui = require('gliter.ui')

local defaults = {
  file_name = 'Session.vim', -- the session file's name inside the project root
  keys = {
    save = '<Leader>ss', -- mksession into the project + remember it
    list = '<Leader>sl', -- the floating list of every known session
  },
  root_markers = { '.git' }, -- what makes a directory the project's root (cwd otherwise)
  max_entries = 100, -- the registry's size cap (the oldest fall off)
}
local cfg = vim.deepcopy(defaults)

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'gliter.sessions' })
end

local function registry_path()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'gliter', 'sessions.json')
end

--- The project root of the moment: the nearest ancestor with a root
--- marker above the current buffer (or the cwd), else the cwd.
---@return string
local function root_of()
  local ok, r = pcall(vim.fs.root, 0, cfg.root_markers)
  if ok and type(r) == 'string' and r ~= '' then
    return r
  end
  return vim.fn.getcwd()
end

--- The registry, sorted most-recently-used first, its missing files
--- flagged.
---@return table[]
local function registry()
  local reg = ui.json_read(registry_path(), {})
  for i = #reg, 1, -1 do
    local e = reg[i]
    if type(e) ~= 'table' or type(e.file) ~= 'string' or e.file == '' then
      table.remove(reg, i)
    else
      e.name = tostring(e.name or vim.fs.basename(e.file))
      e.last = tonumber(e.last) or 0
    end
  end
  table.sort(reg, function(a, b)
    return a.last > b.last
  end)
  return reg
end

local function save_registry(reg)
  while #reg > math.max(1, cfg.max_entries) do
    table.remove(reg) -- the oldest fall off the end
  end
  ui.json_write(registry_path(), reg)
end

-- the floating list's state (declared early: load_entry closes it)
local S = { win = nil, buf = nil, entries = {} }

--- The file a session of `name` lives in, inside `root`.
---@param name string
---@return string
local function session_file(root, name)
  local fname = name:find('%.', 1, true) and name or (name .. '.vim')
  fname = (fname:gsub('[%s/]+', '-'))
  return vim.fs.joinpath(root, fname)
end

--------------------------------------------------------------- actions --

--- :GliterSessionSave [name] / <Leader>ss — mksession! into the project
--- root (the plain :mksession place, only named), and remember the
--- session. Saving again under the same name updates it.
---@param name? string
function M.save(name)
  local root = root_of()
  name = (type(name) == 'string' and name ~= '') and name or nil
  local file = name and session_file(root, name) or vim.fs.joinpath(root, cfg.file_name)
  local display = name or vim.fs.basename(root)

  local ok, err = pcall(vim.cmd, ('mksession! %s'):format(vim.fn.fnameescape(file)))
  if not ok then
    return notify(('cannot save the session: %s'):format(vim.trim(tostring(err):gsub('^Vim:', ''))), vim.log.levels.WARN)
  end

  local reg = registry()
  local entry
  for _, r in ipairs(reg) do
    if r.file == file then
      entry = r
      break
    end
  end
  if not entry then
    entry = { file = file }
    reg[#reg + 1] = entry
  end
  entry.name = display
  entry.dir = root
  entry.last = os.time()
  save_registry(reg)
  notify(('session saved: %s (%s)'):format(display, file))
end

--- If the cursor sits in a floating window, move it to the last plain
--- one (or open one): sourcing a session or :drop-ing a file needs real
--- windows under it.
local function leave_floats()
  local ok, c = pcall(vim.api.nvim_win_get_config, 0)
  if not (ok and c and c.relative and c.relative ~= '') then
    return
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local okw, cc = pcall(vim.api.nvim_win_get_config, w)
    if not (okw and cc and cc.relative and cc.relative ~= '') then
      return vim.api.nvim_set_current_win(w)
    end
  end
  vim.cmd('new')
end

--- Bring one registry entry to life.
---@param e table
local function load_entry(e)
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    vim.api.nvim_win_close(S.win, true) -- a session cannot source into a float
  end
  leave_floats()
  if vim.uv.fs_stat(e.file) == nil then
    return notify(('the session file is gone: %s — d in the list forgets it'):format(e.file), vim.log.levels.WARN)
  end
  local ok, err = pcall(vim.cmd, 'source ' .. vim.fn.fnameescape(e.file))
  if not ok then
    return notify(('cannot load the session: %s'):format(vim.trim(tostring(err):gsub('^Vim:', ''))), vim.log.levels.WARN)
  end
  e.last = os.time()
  local reg = registry()
  for _, r in ipairs(reg) do
    if r.file == e.file then
      r.last = e.last
    end
  end
  save_registry(reg)
  notify(('session loaded: %s'):format(e.name))
end

--- Find a session by name: an exact file path, then the name in the
--- current directory, then the name anywhere.
---@param name? string
---@return table? entry
local function find(name)
  local reg = registry()
  if not name or name == '' then
    return reg[1] -- the most recently used
  end
  for _, e in ipairs(reg) do
    if e.file == name then
      return e
    end
  end
  local cwd = root_of()
  for _, e in ipairs(reg) do
    if e.name == name and e.dir == cwd then
      return e
    end
  end
  for _, e in ipairs(reg) do
    if e.name == name then
      return e
    end
  end
  return nil
end

--- :GliterSessionLoad [name] / <CR> in the list — activate a session.
---@param name? string
function M.load(name)
  local e = find(name)
  if not e then
    return notify(name and name ~= '' and ('no session called %s'):format(name) or 'no session saved yet', vim.log.levels.WARN)
  end
  load_entry(e)
end

--- :GliterSessionDelete [name] / d in the list — forget a session and
--- remove its file (it asks first).
---@param name? string
function M.delete(name)
  local e = find(name)
  if not e then
    return notify(name and name ~= '' and ('no session called %s'):format(name) or 'no session saved yet', vim.log.levels.WARN)
  end
  if not ui.confirm(('Delete the session %s — %s?'):format(e.name, e.file)) then
    return notify('delete cancelled')
  end
  if vim.uv.fs_stat(e.file) then
    os.remove(e.file)
  end
  local reg = registry()
  for i = #reg, 1, -1 do
    if reg[i].file == e.file then
      table.remove(reg, i)
    end
  end
  save_registry(reg)
  notify(('session deleted: %s'):format(e.name))
end

----------------------------------------------------------- the window --

local function shorten(path)
  local home = vim.env.HOME
  if home and home ~= '' and path:sub(1, #home) == home then
    return '~' .. path:sub(#home + 1)
  end
  return path
end

local function row_of(e, i)
  local when = os.date('%Y-%m-%d %H:%M', e.last)
  local missing = vim.uv.fs_stat(e.file) == nil
  return ('  %s%-24s %-34s %s%s'):format(
    e.dir == root_of() and '* ' or '  ',
    e.name,
    shorten(e.dir),
    when,
    missing and '  (file missing)' or ''
  ), missing
end

local function render()
  local lines = { ('  %d sessions — <CR> activate  d delete  q close'):format(#S.entries) }
  local hls = { { 0, 0, -1, 'Directory' } }
  for i, e in ipairs(S.entries) do
    local text, missing = row_of(e, i)
    lines[#lines + 1] = text
    hls[#hls + 1] = { i, 2, 4, 'Title' }
    hls[#hls + 1] = { i, 4, 28, 'Tag' }
    hls[#hls + 1] = { i, 29, 63, 'Type' }
    hls[#hls + 1] = { i, 64, -1, missing and 'WarningMsg' or 'Comment' }
  end
  if #S.entries == 0 then
    lines[#lines + 1] = '  (nothing yet — <Leader>ss saves the current session)'
    hls[#hls + 1] = { 1, 0, -1, 'Comment' }
  end
  ui.render(S.buf, lines, hls)
end

--- The entry the cursor is on.
local function entry_at_cursor()
  local row = (S.win and vim.api.nvim_win_is_valid(S.win)) and vim.api.nvim_win_get_cursor(S.win)[1] or 2
  return S.entries[math.max(1, row - 1)]
end

--- :GliterSessions / <Leader>sl — the floating list of every session.
function M.list()
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    vim.api.nvim_set_current_win(S.win)
  else
    S.win, S.buf = ui.float { title = ' gliter.sessions ', width = 0.9, height = 0.6 }
  end
  S.entries = registry()
  render()

  local function map(key, fn, desc)
    vim.keymap.set('n', key, fn, { buffer = S.buf, nowait = true, silent = true, desc = 'gliter.sessions: ' .. desc })
  end
  map('<CR>', function()
    local e = entry_at_cursor()
    if not e then
      return
    end
    if S.win and vim.api.nvim_win_is_valid(S.win) then
      vim.api.nvim_win_close(S.win, true)
    end
    load_entry(e)
    S.entries = registry()
  end, 'activate this session')
  map('d', function()
    local e = entry_at_cursor()
    if not e then
      return
    end
    if not ui.confirm(('Delete the session %s — %s?'):format(e.name, e.file)) then
      return notify('delete cancelled')
    end
    if vim.uv.fs_stat(e.file) then
      os.remove(e.file)
    end
    for i = #S.entries, 1, -1 do
      if S.entries[i].file == e.file then
        table.remove(S.entries, i)
      end
    end
    save_registry(S.entries)
    notify(('session deleted: %s'):format(e.name))
    render()
  end, 'delete this session (asks first)')
end

---------------------------------------------------------------- setup --

---@param opts? table
function M.setup(opts)
  M.did_setup = true
  opts = (type(opts) == 'table') and opts or {}
  cfg = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)

  if cfg.keys then
    if cfg.keys.save then
      vim.keymap.set('n', cfg.keys.save, function()
        M.save()
      end, { desc = 'gliter.sessions: save the current session (again)' })
    end
    if cfg.keys.list then
      vim.keymap.set('n', cfg.keys.list, M.list, { desc = 'gliter.sessions: every known session, in a float' })
    end
  end

  vim.api.nvim_create_user_command('GliterSessionSave', function(a)
    M.save(a.args ~= '' and a.args or nil)
  end, { nargs = '?', desc = 'gliter.sessions: mksession! into the project, and remember it' })
  vim.api.nvim_create_user_command('GliterSessions', M.list, { desc = 'gliter.sessions: the list of every known session' })
  vim.api.nvim_create_user_command('GliterSessionLoad', function(a)
    M.load(a.args ~= '' and a.args or nil)
  end, { nargs = '?', desc = 'gliter.sessions: activate a session (no argument: the last one)' })
  vim.api.nvim_create_user_command('GliterSessionDelete', function(a)
    M.delete(a.args ~= '' and a.args or nil)
  end, { nargs = '?', desc = 'gliter.sessions: delete a session and its file (asks first)' })

  return M
end

return M
