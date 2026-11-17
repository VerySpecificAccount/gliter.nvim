--- gliter.readme — a README for every project, and a list of them all.
---
--- WHAT IT DOES
---   * <Leader>rr / :GliterReadme — the project's readme: opened when it
---     exists, CREATED when it does not (a one-line skeleton: the
---     project's name as a heading), straight in the project's root.
---     The file's name is an option — README.md by default, README,
---     Readme.org, NOTES.md, whatever you like.
---   * <Leader>rl / :GliterReadmes — every readme you have ever touched,
---     most recent first, like a recent-files list:
---       <CR>   open it
---       <C-t>  open it in a new tab
---       <C-w>  open it in a horizontal split
---       <C-v>  open it in a vertical split
---       d      forget it — the list only, the file stays where it is
---       j/k    walk the list (a plain buffer: gg, G, / all work)
---       q      close
---   The list lives in stdpath('data')/gliter/readmes.json, capped at
---   max_entries; opening a readme again moves it back to the top.
---
--- USAGE (from your init.lua)
---   require('gliter.readme').setup()                  -- defaults
---   require('gliter.readme').setup { file_name = 'NOTES.md' }
---   require('gliter').setup { readme = true }         -- through gliter

local M = {}

M.did_setup = false

local ui = require('gliter.ui')

local defaults = {
  file_name = 'README.md', -- the readme's name in any project dir (an opt)
  keys = {
    open = '<Leader>rr', -- open (or create) the project's readme
    list = '<Leader>rl', -- every readme you have touched, most recent first
  },
  root_markers = { '.git' }, -- what makes a directory the project's root (cwd otherwise)
  max_entries = 50, -- the remembered list's size cap (the oldest fall off)
}
local cfg = vim.deepcopy(defaults)

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'gliter.readme' })
end

local function list_path()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'gliter', 'readmes.json')
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

--- The remembered readmes, most recent first, missing files flagged.
---@return table[]
local function the_list()
  local l = ui.json_read(list_path(), {})
  for i = #l, 1, -1 do
    local e = l[i]
    if type(e) ~= 'table' or type(e.path) ~= 'string' or e.path == '' then
      table.remove(l, i)
    else
      e.project = tostring(e.project or vim.fs.dirname(e.path))
      e.last = tonumber(e.last) or 0
    end
  end
  table.sort(l, function(a, b)
    return a.last > b.last
  end)
  return l
end

local function save_list(l)
  while #l > math.max(1, cfg.max_entries) do
    table.remove(l)
  end
  ui.json_write(list_path(), l)
end

--- Remember a readme: at the top, deduped, the file MRU-sorted.
local function remember(path, project)
  local l = the_list()
  for i = #l, 1, -1 do
    if l[i].path == path then
      table.remove(l, i)
    end
  end
  l[#l + 1] = { path = path, project = project, last = os.time() }
  table.sort(l, function(a, b)
    return a.last > b.last
  end)
  save_list(l)
end

--------------------------------------------------------------- actions --

--- <Leader>rr / :GliterReadme — the project's readme, opened or created.
function M.open()
  -- :drop needs a plain window under the cursor, not one of our floats
  local okc, c = pcall(vim.api.nvim_win_get_config, 0)
  if okc and c and c.relative and c.relative ~= '' then
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local okw, cc = pcall(vim.api.nvim_win_get_config, w)
      if not (okw and cc and cc.relative and cc.relative ~= '') then
        vim.api.nvim_set_current_win(w)
        break
      end
    end
  end
  local root = root_of()
  local file = vim.fs.joinpath(root, cfg.file_name)
  local existed = vim.uv.fs_stat(file) ~= nil
  if not existed then
    local f = io.open(file, 'w')
    if not f then
      return notify(('cannot create %s'):format(file), vim.log.levels.WARN)
    end
    f:write(('# %s\n\n'):format(vim.fs.basename(root)))
    f:close()
    notify(('readme created: %s'):format(file))
  end
  vim.cmd('drop ' .. vim.fn.fnameescape(file))
  remember(file, vim.fs.basename(root))
  if existed then
    notify(('readme: %s'):format(file))
  end
end

--- <Leader>rl / :GliterReadmes — the remembered readmes, in a float.
function M.list()
  local win, buf = ui.float { title = ' gliter.readmes ', width = 0.9, height = 0.6 }
  local entries = the_list()

  local function render()
    local home = vim.env.HOME
    local lines = { ('  %d readmes — <CR> open  <C-t> tab  <C-w> split  <C-v> vsplit  d forget  q close'):format(#entries) }
    local hls = { { 0, 0, -1, 'Directory' } }
    for i, e in ipairs(entries) do
      local dir = tostring(e.project)
      if home and home ~= '' and dir:sub(1, #home) == home then
        dir = '~' .. dir:sub(#home + 1)
      end
      local missing = vim.uv.fs_stat(e.path) == nil
      lines[#lines + 1] = ('  %-22s %-40s %s%s'):format(
        vim.fs.basename(e.path) ~= '' and vim.fs.basename(e.path) or cfg.file_name,
        dir,
        os.date('%Y-%m-%d %H:%M', e.last),
        missing and '  (file missing)' or ''
      )
      hls[#hls + 1] = { i, 2, 24, 'Tag' }
      hls[#hls + 1] = { i, 25, 65, 'Type' }
      hls[#hls + 1] = { i, 66, -1, missing and 'WarningMsg' or 'Comment' }
    end
    if #entries == 0 then
      lines[#lines + 1] = '  (nothing yet — <Leader>rr opens or creates the project readme)'
      hls[#hls + 1] = { 1, 0, -1, 'Comment' }
    end
    ui.render(buf, lines, hls)
  end
  render()

  local function entry_at_cursor()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    return entries[math.max(1, row - 1)]
  end

  -- open the entry under the cursor: 'drop' (the current window,
  -- or the window already showing it), 'tab', 'split' or 'vsplit'
  local function open_entry(e, how)
    if vim.uv.fs_stat(e.path) == nil then
      return notify(('the file is gone: %s — d forgets it'):format(e.path), vim.log.levels.WARN)
    end
    vim.api.nvim_win_close(win, true) -- :drop & friends want a real window
    local esc = vim.fn.fnameescape(e.path)
    if how == 'tab' then
      vim.cmd('tab drop ' .. esc)
    elseif how == 'split' then
      vim.cmd('split ' .. esc)
    elseif how == 'vsplit' then
      vim.cmd('vertical split ' .. esc)
    else
      vim.cmd('drop ' .. esc)
    end
    remember(e.path, e.project)
  end

  local function map_open(key, how, desc)
    vim.keymap.set('n', key, function()
      local e = entry_at_cursor()
      if e then
        open_entry(e, how)
      end
    end, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map_open('<CR>', 'drop', 'gliter.readme: open this readme')
  map_open('<C-t>', 'tab', 'gliter.readme: open this readme in a new tab')
  map_open('<C-w>', 'split', 'gliter.readme: open this readme in a horizontal split')
  map_open('<C-v>', 'vsplit', 'gliter.readme: open this readme in a vertical split')
  vim.keymap.set('n', 'd', function()
    local e = entry_at_cursor()
    if not e then
      return
    end
    for i = #entries, 1, -1 do
      if entries[i].path == e.path then
        table.remove(entries, i)
      end
    end
    save_list(entries) -- the list only: the file itself stays
    notify(('forgotten (the file stays): %s'):format(e.path))
    render()
  end, { buffer = buf, nowait = true, silent = true, desc = 'gliter.readme: forget this readme' })
end

---------------------------------------------------------------- setup --

---@param opts? table
function M.setup(opts)
  M.did_setup = true
  opts = (type(opts) == 'table') and opts or {}
  cfg = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)

  if cfg.keys then
    if cfg.keys.open then
      vim.keymap.set('n', cfg.keys.open, M.open, { desc = 'gliter.readme: the project readme, opened or created' })
    end
    if cfg.keys.list then
      vim.keymap.set('n', cfg.keys.list, M.list, { desc = 'gliter.readme: every readme you touched, most recent first' })
    end
  end

  vim.api.nvim_create_user_command('GliterReadme', M.open, { desc = 'gliter.readme: the project readme, opened or created' })
  vim.api.nvim_create_user_command('GliterReadmes', M.list, { desc = 'gliter.readme: the list of remembered readmes' })

  return M
end

return M
