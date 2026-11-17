--- gliter.pack — MELPA's browsing for Neovim: search, inspect and
--- install plugins from inside the editor, in a floating window
--- (Neovim 0.10+).
---
--- DEPRECATED — this module is on its way out. A locally cached
--- awesome-neovim list was the only thing it offered over a real
--- package browser, and a cache is not much of a feature. Until the
--- removal, everything below keeps working; nothing else depends on
--- it.
---
--- WHAT IT DOES
---   * Keeps a local index of the ecosystem's plugins — awesome-neovim's
---     directory by default, fetched with curl (through a list of MIRRORS
---     per source: raw.githubusercontent.com first, cdn.jsdelivr.net
---     second — whichever answers) and cached under stdpath('data')
---     (cache_days of freshness; :GliterPackUpdate refetches).
---   * :GliterPack opens the FLOATING package menu — no argument lists
---     EVERYTHING, Emacs `list-packages` style; an argument
---     (`:GliterPack telescope`) opens it pre-filtered. The window opens
---     in TYPE mode: every printable character filters the query live
---     (every word must appear, case-insensitive; names outrank
---     descriptions); <Esc> goes to NORMAL mode, where j/k and the rest
---     of vim are yours and q closes; i or a return to TYPE mode.
---   * The keys act on the entry under the cursor (the header shows
---     them all; ? toggles the full list at the top of the window):
---       i     (TYPE) add to the query; (NORMAL) back to TYPE mode
---       I     MARK the entry for install (I again unmarks) — Emacs' i
---       X     INSTALL: every marked entry, else the one under the
---             cursor — it ASKS FIRST, then writes the plugin spec
---             where your manager looks (lazy.nvim's lua/plugins/,
---             0.12+ vim.pack's plugin/, or a git clone into the
---             packpath), the README's recommended setup alongside,
---             commented, ready to uncomment
---       D     DELETE the installed entry under the cursor (it asks
---             first): the spec file or the clone gliter.pack made.
---             A `+` before the name marks what is installed
---       <CR>  open the repository in the browser
---       <C-y>  yank the repository URL
---       <C-e>  yank a lazy.nvim spec line: { "owner/repo" }
---       <C-r>  fetch the README and pull its RECOMMENDED SETUP — the
---              first lua block that configures the plugin — into a
---              review buffer to adapt and save
---       <C-a>  the same review buffer, but as an INSTALL sheet: the
---              spec ready to :w, the setup snippet commented below
---       R      refetch the index;  q / Q  close;  <Esc>  NORMAL mode
---       j/k, <C-n>/<C-p>, arrows, gg/G walk the matches
---   * No file of yours is touched without a yes: X and D confirm
---     first, and <C-r>/<C-a> open REVIEW buffers; where an install
---     lands is written in the notice.
---
--- USAGE (from your init.lua)
---   require('gliter.pack').setup()                  -- defaults
---   require('gliter').setup { pack = true }         -- through gliter
---
---   :GliterPack [query]    the package menu (no query: everything)
---   :GliterPackUpdate      refetch the index now

local M = {}

M.did_setup = false

if vim.fn.has('nvim-0.10') == 0 then
  function M.setup()
    vim.notify('[gliter] pack needs Neovim 0.10+ (vim.system, vim.ui.open)', vim.log.levels.WARN)
  end
  return M
end

local defaults = {
  -- where the index comes from: each source's mirrors are tried in
  -- order until one answers — the raw GitHub URL first, jsDelivr's CDN
  -- mirror second (it serves the same file when GitHub is the side that
  -- is unreachable)
  sources = {
    {
      name = 'awesome-neovim',
      -- the mirrors, tried in order until one answers — jsDelivr's
      -- endpoints first (raw.githubusercontent is the one most often
      -- unreachable), then GitHub itself, master and main both
      mirrors = {
        'https://fastly.jsdelivr.net/gh/rockerBOO/awesome-neovim@master/README.md',
        'https://cdn.jsdelivr.net/gh/rockerBOO/awesome-neovim@master/README.md',
        'https://raw.githubusercontent.com/rockerBOO/awesome-neovim/master/README.md',
        'https://gcore.jsdelivr.net/gh/rockerBOO/awesome-neovim@master/README.md',
        'https://raw.githubusercontent.com/rockerBOO/awesome-neovim/main/README.md',
      },
    },
  },
  cache_days = 7, -- a cached index older than this is refetched
  timeout = 10, -- seconds a mirror gets before the next one is tried
  max_results = 300, -- matches shown at most (a filtered query)
  browse_max = 3000, -- entries listed when browsing with no query
  width = 0.9, -- the float's width: <= 1 is a fraction of the editor
  height = 0.8, -- the float's height: <= 1 is a fraction
  curl = 'curl', -- the fetch binary ('curl -fsSL --max-time 20' is used)
  -- how an install lands: 'auto' picks lazy.nvim when it is around
  -- (require("lazy") loads, or lua/plugins/ exists), else 0.12+'s
  -- vim.pack (a plugin/ file that adds the repo at startup), else a
  -- git clone into the packpath; or name one: 'lazy' | 'native' | 'clone'
  manager = 'auto',
  keys = {
    close = 'q',
  },
}
local cfg = vim.deepcopy(defaults)

local BUFNAME = 'gliter://pack'
local index = {} -- the plugins: { name, url, desc, cat }
local loaded = false -- the index is parsed and non-empty
local fetching = false
local pending_cbs = {} -- ensure_index callers waiting on a running fetch

local S = { buf = nil, win = nil, query = '', rows = {}, marked = {}, show_help = false, insert = true }

-- forward declarations (render needs installed_state, which needs
-- repo_of, which is defined further down)
local installed_state

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'gliter.pack' })
end

------------------------------------------------------------------ index --

---@param name string
---@return string
local function cache_path(name)
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'gliter', 'pack', name .. '.md')
end

--- Parse an awesome-list style page into plugin entries. The Contents
--- links (`- [LSP](#lsp)`) are directory, not plugins: every url that
--- is not absolute http(s) is skipped, and urls are deduped — a plugin
--- listed under two categories appears once.
---@param text string
---@return table[]
local function parse(text)
  local out, cat, seen = {}, 'Misc', {}
  for line in text:gmatch('[^\r\n]+') do
    local h = line:match('^#+%s+(.-)%s*$')
    if h then
      cat = h
    else
      local name, url, desc = line:match('^%s*[-*]%s*%[([^%]]+)%]%s*%(([^)]+)%)%s*(.*)$')
      if name and url and url:match('^https?://') and not seen[url] then
        seen[url] = true
        desc = desc:gsub('^[%s:%-–—]+%s*', '')
          :gsub('%[([^%]]*)%]%([^)]*%)', '%1')
          :gsub('`', '')
        out[#out + 1] = {
          name = name,
          url = url:gsub('[#?].*$', ''),
          desc = vim.trim(desc),
          cat = cat,
        }
      end
    end
  end
  return out
end

--- Read the cached index files (fresh ones only).
---@return table[] the sources that need fetching
local function read_cache()
  local stale = {}
  index = {}
  for _, src in ipairs(cfg.sources) do
    local path = cache_path(src.name)
    local st = vim.uv.fs_stat(path)
    local fresh = st and (os.time() - st.mtime.sec) < math.max(1, cfg.cache_days) * 86400
    if fresh then
      local f = io.open(path, 'r')
      if f then
        local text = f:read('*a')
        f:close()
        local parsed = parse(text)
        for _, e in ipairs(parsed) do
          index[#index + 1] = e
        end
        if #parsed > 0 then
          goto continue
        end
      end
    end
    stale[#stale + 1] = src
    ::continue::
  end
  return stale
end

--- Fetch one URL with curl, asynchronously; cb(text) / cb(nil, err).
---@param url string
---@param cb function
local function fetch(url, cb)
  if vim.fn.executable(cfg.curl) ~= 1 then
    return cb(nil, ("'%s' not found"):format(cfg.curl))
  end
  local ok, sys = pcall(vim.system, { cfg.curl, '-fsSL', '--max-time', tostring(cfg.timeout or 10), url }, { text = true }, function(r)
    vim.schedule(function()
      if r.code == 0 and r.stdout and #r.stdout > 0 then
        cb(r.stdout, nil)
      else
        cb(nil, r.code ~= 0 and ('curl exit ' .. r.code) or 'empty')
      end
    end)
  end)
  if not ok then
    cb(nil, tostring(sys))
  end
end

--- A source through its mirrors, in order, until one answers.
---@param src table
---@param cb function cb(text | nil, errors)
local function fetch_source(src, cb)
  local mirrors = src.mirrors or (src.url and { src.url } or {})
  local errors = {}
  local function try(i)
    if i > #mirrors then
      return cb(nil, errors)
    end
    fetch(mirrors[i], function(text, err)
      if text then
        return cb(text)
      end
      errors[#errors + 1] = mirrors[i]:match('^https?://([^/]+)') .. ': ' .. tostring(err)
      try(i + 1)
    end)
  end
  try(1)
end

--- Make sure the index is there: read the fresh cache, fetch the stale
--- parts (mirrors in tow), then `cb()`.
---@param force? boolean refetch everything
---@param cb? function
local function ensure_index(force, cb)
  cb = cb or function() end
  if fetching then
    pending_cbs[#pending_cbs + 1] = cb -- a fetch is already running: ride along
    return
  end
  local stale = force and cfg.sources or read_cache()
  if force then
    index = {}
  end
  loaded = #index > 0
  if #stale == 0 then
    return cb()
  end
  if vim.fn.executable(cfg.curl) ~= 1 then
    notify(("'%s' not found — install it, or fill %s manually"):format(cfg.curl, cache_path(stale[1].name)), vim.log.levels.ERROR)
    return cb()
  end
  fetching = true
  local pending = #stale
  local function done()
    pending = pending - 1
    if pending <= 0 then
      fetching = false
      loaded = #index > 0
      if not loaded then
        notify('the index came back empty — check the network (R retries, mirrors included)', vim.log.levels.WARN)
      end
      local cbs = pending_cbs
      pending_cbs = {}
      for _, f in ipairs(cbs) do
        f()
      end
      cb()
    end
  end
  for _, src in ipairs(stale) do
    fetch_source(src, function(text, errors)
      if text then
        vim.fn.mkdir(vim.fs.dirname(cache_path(src.name)), 'p')
        local f = io.open(cache_path(src.name), 'w')
        if f then
          f:write(text)
          f:close()
        end
        for _, e in ipairs(parse(text)) do
          index[#index + 1] = e
        end
      else
        -- every mirror failed: a stale cached copy still beats nothing
        local f = io.open(cache_path(src.name), 'r')
        if f then
          local cached = f:read('*a')
          f:close()
          for _, e in ipairs(parse(cached)) do
            index[#index + 1] = e
          end
          notify(('fetching %s failed (%s) — using the cached copy'):format(
            src.name, table.concat(errors or {}, '; ')), vim.log.levels.WARN)
        else
          notify(('fetching %s failed (%s) — no cached copy either'):format(
            src.name, table.concat(errors or {}, '; ')), vim.log.levels.WARN)
        end
      end
      done()
    end)
  end
end

------------------------------------------------------------------ search --

--- The matches for `query`: every word must appear (case-insensitive, in
--- the name, the category or the description); name hits score higher.
--- An empty query matches everything (the browse-all case).
---@param query string
---@return table[]
local function matches_of(query)
  local words = vim.split(vim.trim(query):lower(), '%s+', { trimempty = true })
  local cap = (#words == 0) and math.max(cfg.max_results, cfg.browse_max) or cfg.max_results
  local scored = {}
  for _, e in ipairs(index) do
    local hay = (e.name .. ' ' .. e.cat .. ' ' .. e.desc):lower()
    local ok, score = true, 0
    for _, w in ipairs(words) do
      if not hay:find(w, 1, true) then
        ok = false
        break
      end
      if e.name:lower():find(w, 1, true) then
        score = score + 2
      end
    end
    if ok then
      scored[#scored + 1] = { e, score }
    end
  end
  table.sort(scored, function(a, b)
    if a[2] ~= b[2] then
      return a[2] > b[2]
    end
    return a[1].name:lower() < b[1].name:lower()
  end)
  local out = {}
  for i, s in ipairs(scored) do
    if i > cap then
      break
    end
    out[i] = s[1]
  end
  return out
end

-------------------------------------------------------------- the window --

local HELP = {
  'gliter.pack — keys',
  '  [TYPE] mode (the one the window opens in): every printable character',
  '  filters the query (every word, case-insensitive). <BS> erases one',
  '  char, <C-u> clears, <C-n>/<C-p> and <C-j>/<C-k> walk the entries.',
  '',
  '  <Esc>  back to NORMAL mode — j/k, gg/G, the rest of vim is yours',
  '  i / a  back to TYPE mode (query editing)',
  '  q / Q  close (q types a q in TYPE mode)',
  '',
  '  I      mark for install (I again unmarks) — Emacs\' package-menu',
  '  X      install: every marked entry, else the one under the cursor —',
  '         it asks first, then writes the spec where the manager looks',
  '  D      delete the installed entry under the cursor (asks first)',
  '  <CR>   open the repository in the browser',
  '  <C-y>  yank the url          <C-e>  yank a lazy spec line',
  '  <C-r>  README recommended setup      <C-a>  install sheet',
  '  R      refetch the index     gg  first     G  last',
  '',
  '  a + before a name marks an installed plugin',
}

--- Rewrite the pack buffer from S.query and the matches. The help (when
--- on) sits directly under the header, the entries under it; the
--- cursor stays on the entry it was on (`keep_idx` forces which one —
--- the ? toggle passes it, because the layout it must be read from is
--- the one being replaced).
local function render(keep_idx)
  local buf = S.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  -- the entry under the cursor, to keep it under the cursor
  local cur_idx = keep_idx
  if not cur_idx and S.win and vim.api.nvim_win_is_valid(S.win) then
    local row = vim.api.nvim_win_get_cursor(S.win)[1]
    local first = S.show_help and (#HELP + 2) or 2
    cur_idx = row - first + 1
  end
  S.rows = matches_of(S.query)
  local nmarked = 0
  for _ in pairs(S.marked) do
    nmarked = nmarked + 1
  end
  local status = fetching and '  (index loading...)'
    or ('  %d of %d%s'):format(#S.rows, #index, nmarked > 0 and ('  [%d marked]'):format(nmarked) or '')
  local lines = {
    ('  [%s] query: %s%s  —  I mark  X install  D delete  ? keys'):format(
      S.insert and 'TYPE' or 'NORMAL', S.query, status),
  }
  if S.show_help then
    for _, l in ipairs(HELP) do
      lines[#lines + 1] = '  ' .. l
    end
  end
  for _, e in ipairs(S.rows) do
    local mark = S.marked[e.url] and '*' or ' '
    local inst = installed_state(e) and '+' or ' '
    local name = #e.name < 28 and e.name .. (' '):rep(28 - #e.name) or e.name:sub(1, 27) .. '~'
    lines[#lines + 1] = ('%s%s %s  %-24s %s'):format(mark, inst, name, e.cat, e.desc)
  end
  if not S.show_help then
    if #S.rows == 0 and #index > 0 then
      lines[#lines + 1] = '  (no matches — <C-u> clears the query)'
    elseif #index == 0 then
      lines[#lines + 1] = '  (index empty — R refetches it through the mirrors)'
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, -1, 'Directory', 0, 0, -1)
  local data_from = S.show_help and (#HELP + 2) or 2
  for i = 1, #S.rows do
    local lnum = data_from + i - 1
    if S.marked[S.rows[i].url] then
      vim.api.nvim_buf_add_highlight(buf, -1, 'Title', lnum, 0, 2)
    end
    if installed_state(S.rows[i]) then
      vim.api.nvim_buf_add_highlight(buf, -1, 'Special', lnum, 1, 2)
    end
    vim.api.nvim_buf_add_highlight(buf, -1, 'Tag', lnum, 3, 31)
    vim.api.nvim_buf_add_highlight(buf, -1, 'Type', lnum, 33, 58)
    vim.api.nvim_buf_add_highlight(buf, -1, 'Comment', lnum, 58, -1)
  end
  if S.show_help then
    for i = 1, #HELP do
      vim.api.nvim_buf_add_highlight(buf, -1, 'Comment', i + 1, 0, -1)
    end
  end
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    local row
    if cur_idx and S.rows[cur_idx] then
      row = data_from + cur_idx - 1 -- stay on the same entry
    else
      row = vim.api.nvim_win_get_cursor(S.win)[1]
    end
    -- in range always: never past the last line, never before the data
    -- area — unless the buffer is SHORTER than the data area itself
    -- (help on, zero matches), where any valid row beats an error
    local last = math.max(1, #lines)
    local first_ok = math.min(data_from, last)
    vim.api.nvim_win_set_cursor(S.win, { math.min(last, math.max(row, first_ok)), 0 })
  end
end

--- The entry the cursor is on (the first one when it sits on the header).
---@return table?
local function entry_at_cursor()
  local win = S.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local first = S.show_help and (#HELP + 2) or 2
  return S.rows[math.max(1, row - first + 1)]
end

--- `owner/repo` of an entry, when it lives on github.
---@param e table
---@return string? repo
local function repo_of(e)
  local owner, repo = e.url:match('^https?://github%.com/([%w%.%-_]+)/([%w%.%-_]+)')
  if owner and repo then
    repo = repo:gsub('%.git$', ''):gsub('/.*$', '')
    return ('%s/%s'):format(owner, repo)
  end
  return nil
end

--- The lazy.nvim spec line of an entry.
---@param e table
---@return string
local function spec_of(e)
  local repo = repo_of(e)
  return repo and ('{ "%s" }'):format(repo) or ('{ "%s" }'):format(e.url)
end

--- The file/dir name an entry installs under: the repository's name,
--- or the entry's name made path-safe (names like `owner/repo.nvim`
--- must not turn into directories).
---@param e table
---@return string
local function short_name(e)
  local repo = repo_of(e)
  local s = (repo and repo:match('[^/]+$')) or e.name
  return (s:gsub('[%s/]+', '-'))
end

---------------------------------------------------------------- installed --

local installed_cache = {} -- [url] = { kind, path } or false; reset on X/D/R

--- Where an install of `e` lives right now: the spec gliter.pack wrote
--- (lazy.nvim's lua/plugins/, or vim.pack's plugin/), or the git clone
--- it made into the packpath — nil when the plugin is not around. Only
--- files that carry the plugin's own url count: a same-named spec of
--- yours is yours.
---@param e table
---@return table? { kind = 'lazy'|'native'|'clone', path = string }
function installed_state(e)
  if installed_cache[e.url] ~= nil then
    return installed_cache[e.url] or nil
  end
  installed_cache[e.url] = false -- pessimistic until proven otherwise
  local repo = repo_of(e)
  local short = short_name(e)
  local function spec_at(dir, fname, kind)
    local p = vim.fs.joinpath(dir, fname)
    local f = io.open(p, 'r')
    if not f then
      return nil
    end
    local text = f:read('*a') or ''
    f:close()
    if text:find(e.url, 1, true) or (repo and text:find(repo, 1, true)) then
      installed_cache[e.url] = { kind = kind, path = p }
      return installed_cache[e.url]
    end
    return nil
  end
  local s = spec_at(vim.fs.joinpath(vim.fn.stdpath('config'), 'lua', 'plugins'), short .. '.lua', 'lazy')
  if not s then
    s = spec_at(vim.fs.joinpath(vim.fn.stdpath('config'), 'plugin'), 'gliter-pack-' .. short .. '.lua', 'native')
  end
  if not s then
    local clone = vim.fs.joinpath(vim.fn.stdpath('data'), 'site', 'pack', 'gliter', 'start', short)
    if vim.uv.fs_stat(clone) then
      installed_cache[e.url] = { kind = 'clone', path = clone }
      s = installed_cache[e.url]
    end
  end
  return s
end

--- Ask first, then run — what gliter.pack puts before anything that
--- writes or deletes. Headless (no UI) never confirms: scripts get the
--- safe no.
---@param prompt string
---@return boolean
local function confirm_or_not(prompt)
  if #vim.api.nvim_list_uis() == 0 then
    return false
  end
  return vim.fn.confirm(prompt, '&Yes\n&No', 2) == 1
end

--- The README's recommended setup: the first lua block that configures
--- the plugin (mentions require + setup/config/opts), else the first lua
--- block of all.
---@param readme string
---@return string?
local function setup_snippet(readme)
  local blocks = {}
  for block in readme:gmatch('```[Ll][Uu][Aa]%s*\n(.-)```') do
    blocks[#blocks + 1] = block
  end
  for _, b in ipairs(blocks) do
    if b:find('require%s*%(') and (b:find('setup') or b:find('config') or b:find('opts')) then
      return b
    end
  end
  for _, b in ipairs(blocks) do
    if b:find('require%s*%(') then
      return b
    end
  end
  return blocks[1]
end

--- Open a review float above the pack window: `header` lines, then the
--- snippet, then `footer` lines. Editable; q or <Esc> closes it.
---@param title string
---@param header string[]
---@param snippet string?
---@param footer string[]
local function review_buffer(title, header, snippet, footer)
  local function lines_of(snip)
    local out = {}
    if snip then
      for l in snip:gmatch('[^\r\n]+') do
        out[#out + 1] = l
      end
    end
    return out
  end
  local lines = {}
  for _, l in ipairs(header) do
    lines[#lines + 1] = l
  end
  if snippet then
    for _, l in ipairs(lines_of(snippet)) do
      lines[#lines + 1] = l
    end
  else
    lines[#lines + 1] = '-- (no lua block found in the README)'
  end
  for _, l in ipairs(footer) do
    lines[#lines + 1] = l
  end
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, title)
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'lua'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  local columns, rows = vim.o.columns, (vim.o.lines - vim.o.cmdheight - 2)
  local w = math.floor(columns * 0.8)
  local h = math.floor(rows * 0.8)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = w,
    height = h,
    col = math.floor((columns - w) / 2),
    row = math.floor((rows - h) / 2),
    border = 'rounded',
    style = 'minimal',
    title = title,
    title_pos = 'center',
  })
  vim.wo[win].number = false
  for _, k in ipairs({ 'q', '<Esc>' }) do
    vim.keymap.set('n', k, function()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true, silent = true, desc = 'gliter.pack: close the review' })
  end
  return win
end

--- <C-r> — the recommended setup of the entry under the cursor.
local function show_setup()
  local e = entry_at_cursor()
  if not e then
    return
  end
  local repo = repo_of(e)
  if not repo then
    return notify('only github repositories have a README to read here')
  end
  notify(('fetching the README of %s...'):format(repo))
  fetch(('https://raw.githubusercontent.com/%s/HEAD/README.md'):format(repo), function(text, err)
    if not text then
      return notify(('README of %s: %s'):format(repo, err), vim.log.levels.WARN)
    end
    local snippet = setup_snippet(text)
    local path = vim.fs.joinpath(vim.fn.stdpath('config'), 'lua', 'plugins', (repo:match('[^/]+$') or 'plugin') .. '.lua')
    review_buffer('gliter://pack/setup/' .. repo, {
      ('-- gliter.pack — recommended setup for %s'):format(e.name),
      ('-- %s'):format(e.url),
      '-- the first lua block in the README that configures the plugin.',
      '-- Review it, adapt it, then save it where your plugins live:',
      ('--   :w %s'):format(path),
      '',
    }, snippet, {})
    notify(('save it with :w %s (lazy.nvim) — see :h gliter.pack'):format(path))
  end)
end

--- <C-a> — the install sheet: the spec ready to save, the README's
--- setup snippet alongside, commented, for when you want it.
local function show_install()
  local e = entry_at_cursor()
  if not e then
    return
  end
  local repo = repo_of(e)
  local path = vim.fs.joinpath(vim.fn.stdpath('config'), 'lua', 'plugins', ((repo and repo:match('[^/]+$')) or 'gliter-pack') .. '.lua')
  local header = {
    '-- gliter.pack — install ' .. e.name,
    '-- ' .. e.url,
    '-- Review, then save this file where your plugin manager looks:',
    ('--   lazy.nvim:        :w %s   (then restart, :Lazy sync)'):format(path),
    '--   vim.pack (0.12+): see doc/gliter.pack.md for the shape',
    '',
    'return ' .. spec_of(e),
    '',
    '-- The README recommended setup, for when you want it (uncomment and',
    '-- move it into the spec as config = function() ... end):',
  }
  local function build(snippet)
    local footer = {}
    if snippet then
      for l in snippet:gmatch('[^\r\n]+') do
        footer[#footer + 1] = '-- ' .. l
      end
    else
      footer[#footer + 1] = '-- (fetch it later with <C-r> in the pack window)'
    end
    review_buffer('gliter://pack/install/' .. (repo or e.name), header, nil, footer)
    notify(('review, then :w %s to install (lazy.nvim)'):format(path))
  end
  if repo then
    fetch(('https://raw.githubusercontent.com/%s/HEAD/README.md'):format(repo), function(text)
      build(text and setup_snippet(text) or nil)
    end)
  else
    build(nil)
  end
end

----------------------------------------------------------------- install --

--- 'lazy' | 'native' | 'clone', per opts.manager and what is around.
---@return string
local function detect_manager()
  if cfg.manager ~= 'auto' then
    return cfg.manager
  end
  if pcall(require, 'lazy') then
    return 'lazy'
  end
  if vim.uv.fs_stat(vim.fs.joinpath(vim.fn.stdpath('config'), 'lua', 'plugins')) then
    return 'lazy'
  end
  if type(vim.pack) == 'table' and type(vim.pack.add) == 'function' then
    return 'native' -- Neovim 0.12+
  end
  return 'clone'
end

--- Install one entry: write the spec where the manager looks (the
--- README's recommended setup commented below), or git clone it. The
--- snippet fetch is best-effort — the spec is written either way.
---@param e table
---@param manager string
---@param cb function called when done (with a message)
local function install_one(e, manager, cb)
  local repo = repo_of(e)
  local short = short_name(e)

  local function write_spec(header_extra, body)
    if manager == 'lazy' then
      local dir = vim.fs.joinpath(vim.fn.stdpath('config'), 'lua', 'plugins')
      vim.fn.mkdir(dir, 'p')
      local path = vim.fs.joinpath(dir, short .. '.lua')
      local f = io.open(path, 'w')
      if not f then
        return cb(('cannot write %s'):format(path))
      end
      f:write(table.concat(body, '\n') .. '\n')
      f:close()
      cb(('lazy.nvim spec: %s  (restart, :Lazy sync)'):format(path))
    elseif manager == 'native' then
      local dir = vim.fs.joinpath(vim.fn.stdpath('config'), 'plugin')
      vim.fn.mkdir(dir, 'p')
      local path = vim.fs.joinpath(dir, 'gliter-pack-' .. short .. '.lua')
      local f = io.open(path, 'w')
      if not f then
        return cb(('cannot write %s'):format(path))
      end
      f:write(table.concat(body, '\n') .. '\n')
      f:close()
      cb(('vim.pack spec: %s  (restarts fetch it)'):format(path))
    else -- clone
      local dir = vim.fs.joinpath(vim.fn.stdpath('data'), 'site', 'pack', 'gliter', 'start')
      vim.fn.mkdir(dir, 'p')
      local dest = vim.fs.joinpath(dir, short)
      vim.system({ 'git', 'clone', '--depth=1', e.url, dest }, { text = true }, function(r)
        vim.schedule(function()
          if r.code == 0 then
            cb(('cloned into %s  (restart, or :packadd %s)'):format(dest, short))
          else
            cb(('clone failed: %s'):format(vim.trim(r.stderr or '')))
          end
        end)
      end)
    end
  end

  local function spec_body(snippet)
    local body = {
      ('-- installed by gliter.pack (%s)'):format(e.name),
      ('-- %s'):format(e.url),
    }
    if manager == 'native' then
      body[#body + 1] = ('vim.pack.add({ "%s" })'):format(e.url)
    else
      body[#body + 1] = 'return ' .. spec_of(e)
    end
    if snippet then
      body[#body + 1] = ''
      body[#body + 1] = '-- The README recommended setup, commented for review:'
      for l in snippet:gmatch('[^\r\n]+') do
        body[#body + 1] = '-- ' .. l
      end
    end
    return body
  end

  if repo then
    fetch(('https://raw.githubusercontent.com/%s/HEAD/README.md'):format(repo), function(text)
      write_spec({}, spec_body(text and setup_snippet(text) or nil))
    end)
  else
    write_spec({}, spec_body(nil))
  end
end

--- X — install every marked entry, else the one under the cursor.
--- It asks first (what, where, how), then it just does it.
local function install_marked()
  local list = {}
  for _, e in ipairs(S.rows) do
    if S.marked[e.url] then
      list[#list + 1] = e
    end
  end
  if #list == 0 then
    local e = entry_at_cursor()
    if e then
      list[#list + 1] = e
    end
  end
  if #list == 0 then
    return notify('nothing under the cursor to install')
  end
  local manager = detect_manager()
  local where = (manager == 'lazy' and vim.fs.joinpath(vim.fn.stdpath('config'), 'lua', 'plugins'))
    or (manager == 'native' and vim.fs.joinpath(vim.fn.stdpath('config'), 'plugin'))
    or vim.fs.joinpath(vim.fn.stdpath('data'), 'site', 'pack', 'gliter', 'start')
  local names = {}
  for i, e in ipairs(list) do
    if i <= 3 then
      names[#names + 1] = e.name
    elseif i == 4 then
      names[#names + 1] = ('+%d more'):format(#list - 3)
    end
  end
  if not confirm_or_not(('Install %s — %s in %s?'):format(table.concat(names, ', '), manager, where)) then
    return notify('install cancelled')
  end
  notify(('installing %d plugin%s as %s specs...'):format(#list, #list == 1 and '' or 's', manager))
  local done = 0
  for _, e in ipairs(list) do
    install_one(e, manager, function(msg)
      notify(('%s: %s'):format(e.name, msg))
      S.marked[e.url] = nil
      done = done + 1
      if done == #list then
        installed_cache = {}
        render()
      end
    end)
  end
end

--- D — delete the installed entry under the cursor (it asks first):
--- the spec file or the clone gliter.pack made. What gliter.pack did
--- not install is pointed at, not touched.
local function delete_one()
  local e = entry_at_cursor()
  if not e then
    return
  end
  local st = installed_state(e)
  if not st then
    if vim.uv.fs_stat(vim.fs.joinpath(vim.fn.stdpath('data'), 'lazy', short_name(e))) then
      return notify(('%s was installed by lazy.nvim itself — remove its spec from your config, then :Lazy clean'):format(e.name), vim.log.levels.WARN)
    end
    return notify(('%s is not installed (or not by gliter.pack)'):format(e.name))
  end
  local what = st.kind == 'clone'
    and ('the clone in %s'):format(vim.fs.basename(st.path))
    or st.path
  if not confirm_or_not(('Delete %s — %s?'):format(e.name, what)) then
    return notify('delete cancelled')
  end
  local ok
  if st.kind == 'clone' then
    ok = vim.fn.delete(st.path, 'rf') == 0
  else
    ok = os.remove(st.path)
  end
  installed_cache = {}
  if ok then
    notify(('%s removed — restart nvim for it to fully disappear'):format(e.name))
  else
    notify(('could not remove %s'):format(st.path), vim.log.levels.WARN)
  end
  render()
end

--- The pack buffer with its keys — created once, reused after.
local function ensure_buf()
  if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
    return S.buf
  end
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == BUFNAME then
      S.buf = b
      return b
    end
  end
  local buf = vim.api.nvim_create_buf(true, false)
  pcall(vim.api.nvim_buf_set_name, buf, BUFNAME)
  local bo = vim.bo[buf]
  bo.buftype = 'nofile'
  bo.bufhidden = 'hide'
  bo.swapfile = false
  bo.modifiable = false
  S.buf = buf

  local function map(key, fn, desc)
    vim.keymap.set('n', key, fn, { buffer = buf, nowait = true, silent = true, desc = 'gliter.pack: ' .. desc })
  end

  local function close()
    if S.win and vim.api.nvim_win_is_valid(S.win) then
      vim.api.nvim_win_close(S.win, false)
    end
  end

  -- TYPE mode (the one the window opens in): every printable character
  -- filters the query. In NORMAL mode the key goes to the buffer
  -- untouched — j/k, gg, G and the rest of vim stay vim.
  local function type_key(c)
    return function()
      if not S.insert then
        return vim.api.nvim_feedkeys(c, 'n', false) -- no remap: the raw key
      end
      S.query = S.query .. c
      render()
    end
  end
  local printable = {}
  for c = ('a'):byte(), ('z'):byte() do
    printable[#printable + 1] = string.char(c)
  end
  for c = ('0'):byte(), ('9'):byte() do
    printable[#printable + 1] = string.char(c)
  end
  for _, c in ipairs({ '-', '_', '.', '/', '#', '+', ':', '@', '!', '$', '%', '&', '*' }) do
    printable[#printable + 1] = c
  end
  for _, c in ipairs(printable) do
    map(c, type_key(c), 'add to the query')
  end
  map('<Space>', function()
    if not S.insert then
      return vim.api.nvim_feedkeys(' ', 'n', false)
    end
    S.query = S.query .. ' '
    render()
  end, 'add a space to the query')
  map('<BS>', function()
    if not S.insert then
      return vim.api.nvim_feedkeys('\b', 'n', false)
    end
    -- drop one utf-8 sequence head and its continuation bytes
    S.query = S.query:gsub('.[\128-\191]*$', '')
    render()
  end, 'erase from the query')
  map('<C-u>', function()
    if not S.insert then
      return vim.api.nvim_feedkeys('\21', 'n', false)
    end
    S.query = ''
    render()
  end, 'clear the query')

  local function step(d)
    if not (S.win and vim.api.nvim_win_is_valid(S.win) and vim.api.nvim_buf_is_valid(S.buf or -1)) then
      return
    end
    local first = S.show_help and (#HELP + 2) or 2
    local last = math.max(1, vim.api.nvim_buf_line_count(S.buf))
    -- a buffer shorter than the data area (help on, zero matches) is
    -- steppable too: never ask for a row the buffer does not have
    local first_ok = math.min(first, last)
    local to = vim.api.nvim_win_get_cursor(S.win)[1] + d
    if to < first_ok then
      to = first_ok
    end
    if to > last then
      to = last
    end
    vim.api.nvim_win_set_cursor(S.win, { to, 0 })
  end
  map('<C-n>', function() step(1) end, 'next match')
  map('<C-p>', function() step(-1) end, 'previous match')
  map('<C-j>', function() step(1) end, 'next match')
  map('<C-k>', function() step(-1) end, 'previous match')
  map('<Down>', function() step(1) end, 'next match')
  map('<Up>', function() step(-1) end, 'previous match')
  map('G', function()
    if S.win and vim.api.nvim_win_is_valid(S.win) then
      vim.api.nvim_win_set_cursor(S.win, { vim.api.nvim_buf_line_count(S.buf), 0 })
    end
  end, 'last match')

  -- the marks (Emacs' package-menu: I marks, X executes — uppercase, so
  -- the lowercase alphabet stays free for the query)
  map('I', function()
    local e = entry_at_cursor()
    if not e then
      return
    end
    if S.marked[e.url] then
      S.marked[e.url] = nil
    else
      S.marked[e.url] = true
    end
    render()
    step(1)
  end, 'mark for install (I again unmarks)')
  map('X', install_marked, 'install marked entries, else the one under the cursor (asks first)')
  map('D', delete_one, 'delete the installed entry under the cursor (asks first)')
  map('R', function()
    notify('refetching the index...')
    installed_cache = {}
    ensure_index(true, function()
      notify(('index: %d plugins'):format(#index))
      render()
    end)
  end, 'refetch the index')

  map('?', function()
    -- read the entry from the layout that is about to disappear
    local keep = nil
    if S.win and vim.api.nvim_win_is_valid(S.win) then
      local first = S.show_help and (#HELP + 2) or 2
      keep = vim.api.nvim_win_get_cursor(S.win)[1] - first + 1
    end
    S.show_help = not S.show_help
    render(keep)
  end, 'toggle the key help')

  map(cfg.keys.open or '<CR>', function()
    local e = entry_at_cursor()
    if not e then
      return
    end
    local ok = pcall(vim.ui.open, e.url)
    if not ok then
      notify(e.url)
    end
  end, 'open the repository in the browser')
  map(cfg.keys.yank or '<C-y>', function()
    local e = entry_at_cursor()
    if e then
      vim.fn.setreg('+', e.url)
      notify('yanked ' .. e.url)
    end
  end, 'yank the URL')
  map(cfg.keys.spec or '<C-e>', function()
    local e = entry_at_cursor()
    if e then
      vim.fn.setreg('+', spec_of(e))
      notify('yanked ' .. spec_of(e))
    end
  end, 'yank a lazy.nvim spec line')
  map(cfg.keys.setup or '<C-r>', show_setup, 'the README recommended setup, in a buffer')
  map(cfg.keys.install or '<C-a>', show_install, 'the install sheet: the spec, ready to :w')

  -- the two modes: <Esc> is a mode key, not a close key — NORMAL mode
  -- is where q closes and vim's own keys work; i/a go back to TYPE
  map('<Esc>', function()
    if S.insert then
      S.insert = false
      render()
    end
    -- in NORMAL mode <Esc> just beeps, like in any buffer
  end, 'back to NORMAL mode')
  map('i', function()
    if S.insert then
      S.query = S.query .. 'i'
    else
      S.insert = true -- NORMAL -> TYPE
    end
    render()
  end, 'back to TYPE mode (from NORMAL)')
  map('a', function()
    if S.insert then
      S.query = S.query .. 'a'
    else
      S.insert = true -- NORMAL -> TYPE
    end
    render()
  end, 'back to TYPE mode (from NORMAL)')
  map('q', function()
    if S.insert then
      S.query = S.query .. 'q'
      return render()
    end
    close()
  end, 'close (in NORMAL mode)')
  map('Q', close, 'close')
  if cfg.keys.close and cfg.keys.close ~= 'q' and cfg.keys.close ~= '<Esc>' then
    map(cfg.keys.close, close, 'close')
  end

  return buf
end

--- Open (or reopen) the pack float.
local function open_win()
  local buf = ensure_buf()
  if S.win and vim.api.nvim_win_is_valid(S.win) and vim.api.nvim_win_get_buf(S.win) == buf then
    return S.win
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then
      vim.api.nvim_win_close(w, true)
    end
  end
  local columns, rows = vim.o.columns, (vim.o.lines - vim.o.cmdheight - 2)
  local w = math.floor(columns * (tonumber(cfg.width) or 0.9) + 0.5)
  local h = math.floor(rows * (tonumber(cfg.height) or 0.8) + 0.5)
  w = math.min(w, columns)
  h = math.min(h, rows)
  S.win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = w,
    height = h,
    col = math.floor((columns - w) / 2),
    row = math.floor((rows - h) / 2),
    border = 'rounded',
    title = ' gliter.pack ',
    title_pos = 'center',
  })
  vim.wo[S.win].number = false
  vim.wo[S.win].relativenumber = false
  vim.wo[S.win].cursorline = true
  vim.wo[S.win].wrap = false
  return S.win
end

-------------------------------------------------------------------- api --

--- :GliterPack [query] — open the floating package menu on `query`; no
--- query at all lists every plugin in the index, list-packages style.
---@param query? string
function M.search(query)
  if vim.fn.has('nvim-0.10') == 0 then
    return notify('needs Neovim 0.10+', vim.log.levels.WARN)
  end
  open_win()
  S.insert = true -- every fresh open starts in TYPE mode
  installed_cache = {} -- what is installed may have changed since the last look
  if query == nil then
    S.query = '' -- browse everything
  elseif query ~= '' then
    S.query = query
  end
  ensure_index(false, render)
  render() -- shows the '(index loading...)' state too, if any
end

--- :GliterPackUpdate — refetch every source, whatever the cache says.
function M.update()
  if vim.fn.has('nvim-0.10') == 0 then
    return notify('needs Neovim 0.10+', vim.log.levels.WARN)
  end
  ensure_index(true, function()
    notify(('index: %d plugins'):format(#index))
    render()
  end)
end

--- The parsed index, for tests and the curious.
---@return table[]
function M.index()
  return index
end

------------------------------------------------------------------ setup --

---@param opts? table
function M.setup(opts)
  M.did_setup = true
  vim.notify(
    'gliter.pack is deprecated and on its way out',
    vim.log.levels.WARN, { title = 'gliter.pack' })
  opts = (type(opts) == 'table') and opts or {}
  for k, v in pairs(opts) do
    if k == 'keys' or k == 'sources' then
      cfg[k] = vim.tbl_deep_extend('force', cfg[k] or {}, (type(v) == 'table') and v or {})
    else
      cfg[k] = v
    end
  end

  vim.api.nvim_create_user_command('GliterPack', function(a)
    M.search(a.args ~= '' and a.args or nil)
  end, { nargs = '?', desc = 'gliter.pack: the plugin menu (no argument: everything)' })
  vim.api.nvim_create_user_command('GliterPackUpdate', M.update, { desc = 'gliter.pack: refetch the plugin index' })

  return M
end

return M
