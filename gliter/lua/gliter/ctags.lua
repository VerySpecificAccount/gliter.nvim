--- gliter.ctags — the built-in ctags support, with better defaults, a
--- simpler interface and quickfix on top (Neovim 0.10+).
---
--- WHAT IT DOES
---   * Generates the tags file through universal-ctags (or exuberant-ctags)
---     with the flags that matter for editing: qualified tags (--extras=+q,
---     so `Class.method` resolves), line numbers (--fields=+n) and
---     signatures — recursing the project root, skipping .git/node_modules/
---     build dirs (and .cache, venvs, __pycache__ & co). A run that fails
---     (a stale `--langdef=` in ~/.ctags.d, in ~/.ctags, in a .ctags of
---     the working directory, or in $CTAGS, say) is retried with the
---     preload option files off (--options=NONE), then from a SANDBOX —
---     a scratch cwd, a dark HOME, a scrubbed environment: nowhere an
---     option file can hide, whichever ctags flavor it is — the run goes
---     through, whatever the environment puts in the way, and the ladder
---     starts over every time so a freshly-stale option file cannot hide
---     the working rung below it.
---   * A file with NO project root above it (a loose main.c on the Desktop,
---     where everything else also lives) never gets a recursive run over
---     the directory it sits in — that is how 300 MB tags files happen.
---     It gets single-file tags instead: cached under stdpath('data'),
---     absolute names inside, regenerated per save like a project's.
---     $HOME itself never counts as a root (a dotfiles .git lives there).
---   * The tags file is found, not assumed: the configured one, else a `tags`
---     already sitting in the project root (yours, made by hand — generate
---     regenerates *it*), else the first one between the buffer's own file
---     and the project root (a plain `ctags` run in a subdirectory writes
---     ./tags right there). The default when nothing exists is
---     stdpath('data')/gliter/tags/ (no untracked file in your repo; set
---     tags_file = 'tags' for the classic in-project file), and every
---     buffer of the project gets it prepended to its buffer-local 'tags',
---     so <C-]> and :tag work without any configuration.
---   * A simpler interface than :tselect's horizontal affair:
---     :GliterCtags list (or <Leader>]) — the word under the cursor, one
---     vertical split listing every match (name, kind, file:line,
---     signature), <CR> to jump, q to close. One match: straight there.
---   * Quickfix support: :GliterCtags quickfix (or <Leader>[) puts every
---     match in the quickfix list — :cnext through them all; and
---     :GliterCtags file puts the symbols of the current file in the
---     quickfix list, sorted by line: a poor man's document outline.
---   * :GliterCtags generate runs ctags asynchronously; with
---     auto_generate (default) the tags are regenerated (debounced)
---     whenever a buffer of a project that already has a tags file is
---     saved.
---   * :GliterCtags generate % (or any file argument) regenerates the tags
---     of that ONE file inside the project's tags file — its old entries
---     dropped, its fresh ones spliced in, the file kept sorted (Vim's
---     'tagbsearch' binary search demands it) — without re-running ctags
---     over the whole tree.
---
--- USAGE (from your init.lua)
---   require('gliter.ctags').setup()                     -- defaults
---   require('gliter.ctags').setup { tags_file = 'tags' }
---   require('gliter').setup { ctags = true }            -- through gliter

local M = {}

M.did_setup = false

if vim.fn.has('nvim-0.10') == 0 then
  function M.setup()
    vim.notify('[gliter] ctags needs Neovim 0.10+ (vim.system)', vim.log.levels.WARN)
  end
  return M
end

local defaults = {
  keys = {
    list = '<Leader>]', -- list the tags of the word under the cursor
    quickfix = '<Leader>[', -- the same matches, in the quickfix list
    generate = false, -- e.g. '<Leader>tg'; commands work without a key
  },
  bin = 'ctags', -- the ctags executable
  -- nil = stdpath('data')/gliter/tags/<hash> (per project, nothing in the
  -- repo); or an absolute path; or a path relative to the project root
  -- such as 'tags'.
  tags_file = nil,
  root_markers = { '.git', '.hg', '.svn', 'Makefile', 'package.json', 'go.mod', 'Cargo.toml', 'pyproject.toml', 'setup.py' },
  excludes = {
    '.git', '.hg', '.svn', 'node_modules', 'target', 'dist', 'build',
    '.cache', '.venv', 'venv', '__pycache__', '.npm', '.cargo', '.rustup',
    '.pyenv', '.mypy_cache', '.pytest_cache', '.tox',
  },
  extra_args = {}, -- appended to the ctags command line
  auto_generate = true, -- regenerate (debounced) on :w, once the project has a tags file
  quickfix = { open = true, height = 10 },
  skip_home_root = true, -- $HOME (a dotfiles .git, usually) is not a
  -- project root: a buffer there falls back to single-file tags instead
  -- of recursing the whole home directory
  max_entries = 300000, -- entries parsed out of a tags file for
  -- list/quickfix; a bigger one is truncated with a notice — a runaway
  -- tags file (a 300 MB one on a crowded Desktop, say) must not eat the
  -- editor
  warn_mb = 50, -- a generated tags file over this many MB earns a
  -- warning that the project root is probably too broad
}
local cfg = vim.deepcopy(defaults)

local projects = {} -- [root] = { root, file, rel_exists }
local singles = {} -- [abs file] = { root = its dir, file = its own tags, single = true }
local buf_root = {} -- [buf] = root
local debounce = {} -- [root] = uv timer
local running = false
local rerun = false
local pickers = {} -- [picker buf] = { entries, from, root }

local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'gliter.ctags' })
end

--- The options for the SANDBOX rung both ladders end in: ctags runs from
--- a scratch directory (no option file lands there), under a scrubbed
--- environment — a minimal set that is complete on its own (PATH and
--- TMPDIR kept, HOME pointed at the scratch directory so ~/.ctags and
--- ~/.ctags.d go dark, $CTAGS emptied) — with absolute paths for
--- everything. Under a dark HOME and a scratch CWD there are no option
--- files left to read: wherever a stale `--langdef=css` hides — ~/.ctags,
--- ~/.ctags.d, a .ctags in the working directory, $CTAGS — it cannot
--- reach the run. exuberant-ctags has no --options=NONE to skip them
--- with; the sandbox is its only defense.
---@return string dir the scratch directory (delete with :call delete(dir, 'rf'))
---@return table opts the vim.system options
local function sandbox_opts()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, 'p')
  return dir, {
    cwd = dir,
    text = true,
    env = {
      PATH = vim.env.PATH or '/usr/local/bin:/usr/bin:/bin',
      HOME = dir,
      TMPDIR = vim.env.TMPDIR or '/tmp',
      CTAGS = '',
    },
  }
end

--- The hint for the one failure every stale option file produces, so
--- the notice says where to clean up.
---@param err string
---@return string
local function langdef_hint(err)
  if err:find('already defined', 1, true) then
    return '\n  a --langdef for a language ctags already knows sits in an option file'
      .. ' (~/.ctags.d/, ~/.ctags, a .ctags in the directory, or $CTAGS);'
      .. ' even the sandboxed run failed, so check the command line'
      .. ' (extra_args) and the ctags binary itself'
  end
  return ''
end

---------------------------------------------------------------- project --

--- The project root of `buf` (a buffer id, 0 for the current one): the
--- nearest ancestor with a root marker, else nil. $HOME (and /) never
--- count when skip_home_root is on — a dotfiles repo's .git sits right
--- there, and `ctags -R ~` is the 300 MB file nobody asked for.
---@param buf integer
---@return string?
local function root_of(buf)
  local b = buf == 0 and vim.api.nvim_get_current_buf() or buf
  if buf_root[b] ~= nil then
    return buf_root[b]
  end
  local root = vim.fs.root(b, cfg.root_markers)
  if root and cfg.skip_home_root then
    local home = vim.fs.normalize(vim.uv.os_homedir())
    root = vim.fs.normalize(root)
    if root == home or root == '/' then
      root = nil
    end
  end
  buf_root[b] = root or false
  return root
end

--- The single-file project of a loose file (no root anywhere above it):
--- its tags live in stdpath('data')/gliter/tags/single/<hash>, its entries
--- carry absolute names, and generate works on the file alone — never a
--- recursive run over the directory it happens to sit in (a Desktop with
--- everything on it, say).
---@param bname string an absolute file path
---@return table proj
local function single_of(bname)
  local src = vim.fs.normalize(vim.fn.fnamemodify(bname, ':p'))
  local p = singles[src]
  if not p then
    p = {
      root = vim.fs.dirname(src),
      file = vim.fs.joinpath(vim.fn.stdpath('data'), 'gliter', 'tags', 'single', vim.fn.sha256(src):sub(1, 20)),
      single = true,
      src = src,
    }
    singles[src] = p
  end
  return p
end

--- The tags file path of `root` (a table with the file's existence is
--- cached per root).
---@param root string
---@return table proj { root, file }
local function project_of(root)
  local p = projects[root]
  if not p then
    local file
    if type(cfg.tags_file) == 'string' then
      if cfg.tags_file:sub(1, 1) == '~' or cfg.tags_file:sub(1, 1) == '/' or cfg.tags_file:match('^%a:[/\\]') then
        file = vim.fn.expand(cfg.tags_file)
      else
        file = vim.fs.joinpath(root, cfg.tags_file)
      end
    elseif vim.uv.fs_stat(vim.fs.joinpath(root, 'tags')) then
      -- the project already carries a tags file (made by hand, or by an
      -- earlier generate): use it, and regenerate it, not a private copy
      file = vim.fs.joinpath(root, 'tags')
    else
      file = vim.fs.joinpath(vim.fn.stdpath('data'), 'gliter', 'tags', vim.fn.sha256(root):sub(1, 20))
    end
    p = { root = root, file = file }
    projects[root] = p
  end
  return p
end

--- Prepend the project's tags file to the buffer-local 'tags' option, so
--- the built-in <C-]> / :tag see it without touching the global option.
---@param buf integer
---@param proj table
local function set_buf_tags(buf, proj)
  if vim.bo[buf].buftype ~= '' then
    return
  end
  local cur = vim.bo[buf].tags or ''
  if cur:find(proj.file, 1, true) then
    return
  end
  local esc = vim.fn.escape(proj.file, ' \\,')
  vim.bo[buf].tags = cur == '' and esc or (esc .. ',' .. cur)
end

--- The project table for `buf`, pointing at whatever tags file is usable:
--- the configured one, else a `tags` in the project root, else the first
--- one between the buffer's own file and the project root (a plain `ctags`
--- run in a subdirectory writes ./tags right there — a tags ABOVE the
--- root belongs to another project and is not adopted). A buffer with no
--- root falls back to its single-file tags, else a `tags` sitting right
--- next to the file; nil when none exists.
---@param buf integer
---@return table?
local function discover(buf)
  local b = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local bname = vim.api.nvim_buf_get_name(b)
  local root = root_of(b)
  if not root then
    -- no project: this file's own tags, else one beside it. Nothing above
    -- the file's directory — that way a tags in $HOME never adopts a loose
    -- file on the Desktop
    if bname == '' then
      return nil
    end
    local single = single_of(bname)
    if vim.uv.fs_stat(single.file) then
      return single
    end
    local beside = vim.fs.joinpath(vim.fs.dirname(single.src), 'tags')
    if vim.uv.fs_stat(beside) then
      return { root = single.root, file = beside, base = single.root }
    end
    return nil
  end
  local proj = project_of(root)
  if vim.uv.fs_stat(proj.file) then
    return proj
  end
  if bname ~= '' then
    local dir = vim.fs.dirname(vim.fs.normalize(bname))
    while dir and dir ~= '/' do
      local found = vim.fs.joinpath(dir, 'tags')
      if vim.uv.fs_stat(found) then
        proj.file = vim.fs.normalize(found)
        -- names inside are relative to where that ctags ran: the file's own dir
        proj.base = vim.fs.dirname(proj.file)
        proj.entries = nil
        proj.mtime = nil
        return proj
      end
      if dir == root then
        break
      end
      dir = vim.fs.dirname(dir)
    end
  end
  return nil
end

--- `discover`, with a notice when nothing was found.
---@param buf integer
---@return table?
local function ready_project(buf)
  local proj = discover(buf)
  if not proj then
    notify('No tags file for this buffer yet — :GliterCtags generate', WARN)
  end
  return proj
end

----------------------------------------------------------------- parsing --

--- Count a tags file's entries without building anything — the notice
--- after a generate must not pay for parsing a 300 MB file into Lua
--- tables just to say a number.
---@param path string
---@return integer
local function count_entries(path)
  local n = 0
  local f = io.open(path, 'r')
  if not f then
    return 0
  end
  for l in f:lines() do
    if l ~= '' and l:sub(1, 1) ~= '!' then
      n = n + 1
    end
  end
  f:close()
  return n
end

--- Parse a tags file: every line becomes { name, rel, abs, line, kind, sig,
--- pattern }. File names are resolved against `root` (ctags ran there) —
--- absolute names pass through untouched. Parsed entries are cached until
--- the file's mtime moves, and capped at max_entries: a runaway tags file
--- truncates (with a notice at use time) instead of eating the editor.
---@param proj table
---@return table[]
local function entries_of(proj)
  local st = vim.uv.fs_stat(proj.file)
  local mtime = st and (st.mtime.sec .. '.' .. st.mtime.nsec) or '0'
  if proj.entries and proj.mtime == mtime then
    return proj.entries
  end
  local out = {}
  local f = io.open(proj.file, 'r')
  if f then
    for l in f:lines() do
      if #out >= cfg.max_entries then
        proj.truncated = true
        break
      end
      if l ~= '' and l:sub(1, 1) ~= '!' then
        local parts = vim.split(l, '\t', { plain = true })
        if #parts >= 3 then
          local rel = parts[2]
          local e = {
            name = parts[1],
            rel = rel,
            abs = rel:sub(1, 1) == '/' and vim.fs.normalize(rel)
              or vim.fs.normalize(vim.fs.joinpath(proj.base or proj.root, rel)),
            pattern = parts[3],
          }
          for i = 4, #parts do
            local k, v = parts[i]:match('^(%a+):(.*)$')
            if k == 'line' then
              e.line = tonumber(v)
            elseif k == 'kind' then
              e.kind = v
            elseif k == 'signature' then
              e.sig = v
            end
          end
          out[#out + 1] = e
        end
      end
    end
    f:close()
  end
  proj.entries = out
  proj.mtime = mtime
  return out
end

--- The truncation notice, said once per project.
local function truncation_notice(proj)
  if proj.truncated and not proj.truncation_said then
    proj.truncation_said = true
    notify(('tags file truncated at %d entries — raise max_entries, or regenerate inside a narrower root'):format(cfg.max_entries), WARN)
  end
end

--- Exact matches first; none, then the names starting with `pat`.
---@param entries table[]
---@param pat string
---@return table[]
local function matches_of(entries, pat)
  local exact, prefix = {}, {}
  for _, e in ipairs(entries) do
    if e.name == pat then
      exact[#exact + 1] = e
    elseif e.name:sub(1, #pat) == pat then
      prefix[#prefix + 1] = e
    end
  end
  return #exact > 0 and exact or prefix
end

------------------------------------------------------------------ jumping --

--- Open the entry's file in `win` and put the cursor on the tag: by line
--- number when ctags recorded one, else by searching the recorded pattern.
---@param e table
---@param win integer
local function goto_entry(e, win)
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.api.nvim_win_call(win, function()
    pcall(vim.cmd.edit, vim.fn.fnameescape(e.abs))
  end)
  vim.api.nvim_win_call(win, function()
    if e.line then
      pcall(vim.api.nvim_win_set_cursor, win, { e.line, 0 })
      pcall(vim.cmd, 'normal! zv')
    else
      -- /pattern/;" (or ?pattern?;") -> the pattern between the separators
      local sep, content = e.pattern:match('^([/?])(.-)%1;?"?$')
      if content then
        pcall(vim.fn.search, content, 'w')
      end
    end
  end)
end

--- The pattern to look for: the argument, else the word under the cursor,
--- else a prompt (nil when the prompt is cancelled or empty).
---@param pat string?
---@return string?
local function ask_pattern(pat)
  if pat and pat ~= '' then
    return pat
  end
  pat = vim.fn.expand('<cword>')
  if pat ~= '' then
    return pat
  end
  pat = vim.fn.input('Tag: ')
  if pat == '' then
    return nil
  end
  return pat
end

------------------------------------------------------------------ picker --

--- Open the vertical tag picker on `matches`.
---@param pat string
---@param matches table[]
---@param from integer
local function open_picker(pat, matches, from)
  -- close a picker left open by an earlier list
  for pb, _ in pairs(pickers) do
    if vim.api.nvim_buf_is_valid(pb) then
      for _, w in ipairs(vim.fn.win_findbuf(pb)) do
        pcall(vim.api.nvim_win_close, w, true)
      end
      vim.api.nvim_buf_delete(pb, { force = true })
    end
    pickers[pb] = nil
  end

  vim.cmd('rightbelow 45vnew')
  local buf = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  pickers[buf] = { entries = matches, from = from }

  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, buf, 'gliter://ctags/' .. pat)
  vim.wo[win].cursorline = true

  -- the columns: name (padded), [kind] file:line, signature
  local w = 0
  for _, e in ipairs(matches) do
    w = math.max(w, math.min(#e.name, 44))
  end
  local lines, cols = {}, {}
  for i, e in ipairs(matches) do
    local name = e.name
    local kind = e.kind and ('[' .. e.kind .. '] ') or ''
    local file = ('%s:%s'):format(e.rel, e.line or e.pattern:sub(1, 12))
    local sig = e.sig or ''
    lines[i] = name .. (' '):rep(w - #name + 2) .. kind .. file .. (sig ~= '' and ('  ' .. sig) or '')
    cols[i] = { #name, #kind > 0 and (w + 2) or nil, w + 2 + #kind }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  for i, c in ipairs(cols) do
    vim.api.nvim_buf_add_highlight(buf, -1, 'Tag', i - 1, 0, c[1])
    if c[2] then
      vim.api.nvim_buf_add_highlight(buf, -1, 'Type', i - 1, c[2], c[2] + c[3] - w - 3 + 1)
    end
    vim.api.nvim_buf_add_highlight(buf, -1, 'Comment', i - 1, c[3] or c[1], -1)
  end

  local function jump()
    local p = pickers[buf]
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local e = p and p.entries[row]
    if not e then
      return
    end
    local from_win = p.from
    pcall(vim.api.nvim_win_close, win, true)
    goto_entry(e, from_win)
  end
  vim.keymap.set('n', '<CR>', jump, { buffer = buf, silent = true, desc = 'gliter.ctags: jump to this tag' })
  vim.keymap.set('n', 'q', function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, silent = true, desc = 'gliter.ctags: close' })
  vim.keymap.set('n', '<Esc>', function()
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, silent = true, desc = 'gliter.ctags: close' })
end

--------------------------------------------------------------------- API --

--- Run ctags for the project of `root` (default: the current buffer's),
--- asynchronously. A buffer with NO project root (a loose main.c on the
--- Desktop, say) does not recurse the directory it happens to sit in —
--- that is how a 300 MB tags file happens — it gets single-file tags
--- instead (`generate %`, with a notice saying so).
---
--- The first attempt uses the full set of flags; a failure (universal-ctags
--- reads option files from ~/.ctags.d, and a stale `--langdef=css` there
--- makes every run die with `Language "css" already defined` — the
--- $CTAGS environment variable can do the same) is retried with the
--- preload option files off (`--options=NONE`), then with a bare
--- `ctags --options=NONE -R -f tags` under a scrubbed environment. The
--- ladder always starts at the first rung — the failing rungs die at
--- startup in milliseconds, and a stage remembered from an earlier run
--- (before the option file went stale) must never hide the ones below it.
---@param root? string
function M.generate(root)
  if vim.fn.executable(cfg.bin) ~= 1 then
    return notify(("'%s' not found — install universal-ctags"):format(cfg.bin), ERROR)
  end
  if root == nil then
    root = root_of(0)
    if not root then
      local bname = vim.api.nvim_buf_get_name(0)
      if bname == '' then
        return notify('No project root (no .git, Makefile, ... above this buffer) and no file to tag.', WARN)
      end
      notify(('No project root above %s — tags for this file only (give the directory a root marker for a whole-tree run)'):format(vim.fs.basename(bname)))
      return M.generate_file(bname)
    end
  end
  if running then
    rerun = true
    return
  end
  local proj = project_of(root)
  local out = proj.file
  vim.fn.mkdir(vim.fs.dirname(out), 'p')

  -- universal-ctags spells it --extras, exuberant-ctags --extra; the
  -- signature field is S in universal, absent in exuberant's defaults.
  local universal = true
  local ok_v, v = pcall(function()
    return vim.system({ cfg.bin, '--version' }, { text = true }):wait()
  end)
  if ok_v and v and v.stdout and not v.stdout:match('Universal Ctags') then
    universal = false
  end

  local function with_excludes(args)
    for _, x in ipairs(cfg.excludes) do
      args[#args + 1] = '--exclude=' .. x
    end
    for _, a in ipairs(cfg.extra_args) do
      args[#args + 1] = a
    end
    return args
  end

  -- stage 1: everything — user option files and environment included;
  -- the scan root is an explicit ABSOLUTE argument, so the same stages
  -- also run from the sandbox's scratch directory
  local stages = {
    with_excludes({
      cfg.bin,
      '-R',
      '-f',
      out,
      universal and '--extras=+q' or '--extra=+q',
      universal and '--fields=+nS' or '--fields=+n',
      root,
    }),
  }
  if universal then
    -- stage 2: no preload option files — the fix for `Language "css"
    -- already defined` out of a stale ~/.ctags.d entry
    stages[#stages + 1] = with_excludes({
      cfg.bin,
      '--options=NONE',
      '-R',
      '-f',
      out,
      '--extras=+q',
      '--fields=+nS',
      root,
    })
    -- stage 3: the SANDBOX — a scratch directory, a scrubbed
    -- environment, nothing on the command line but the run itself
    stages[#stages + 1] = { cfg.bin, '--options=NONE', '-R', '-f', out, root }
  else
    -- exuberant has no --options=NONE: the sandbox is its only defense
    stages[#stages + 1] = { cfg.bin, '-R', '-f', out, root }
  end

  running = true
  local stage = 1
  local scratch = nil -- the sandbox rung's scratch directory

  local function run_stage()
    local opts = { cwd = root, text = true }
    if stage == #stages then
      scratch, opts = sandbox_opts()
    elseif stage > 1 then
      -- $CTAGS can carry its own --langdef; PATH stays (whatever the
      -- env semantics, this set is complete on its own)
      opts.env = { PATH = vim.env.PATH or '/usr/local/bin:/usr/bin:/bin', CTAGS = '' }
    end
    local ok_sys, sysobj = pcall(vim.system, stages[stage], opts, function(r)
      vim.schedule(function()
        if scratch then
          vim.fn.delete(scratch, 'rf')
          scratch = nil
        end
        if r.code ~= 0 and stage < #stages then
          -- this stage's flags (or the environment's option files) are no
          -- good: fall back to the simpler command line
          stage = stage + 1
          proj.stage = stage
          run_stage()
          return
        end
        running = false
        if r.code == 0 then
          proj.stage = stage
          -- the names inside are relative to the cwd the run went from:
          -- the project root — except in the sandbox rung, where they are
          -- absolute (the root sits outside the scratch cwd); either way
          -- entries_of passes absolute names through and resolves the rest
          proj.base = nil
          proj.entries = nil
          local st = vim.uv.fs_stat(out)
          local mb = st and (st.size / 1048576) or 0
          local what = mb > 100 and ('%.0f MB'):format(mb) or ('%d entries'):format(count_entries(out))
          local how = stage > 1 and (' (fallback command %d of %d)'):format(stage, #stages) or ''
          notify(('tags: %s (%s)%s'):format(what, root, how))
          if mb > cfg.warn_mb then
            notify(('the tags file is %.0f MB — the root looks too broad; root_markers or excludes can narrow it'):format(mb), WARN)
          end
          -- every loaded buffer of the project gets the file in its 'tags'
          for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) and root_of(b) == root then
              set_buf_tags(b, proj)
            end
          end
        else
          local err = vim.trim((r.stderr or '') .. (r.stdout or ''))
          notify(('ctags failed (exit %d): %s%s\n  command: %s'):format(
            r.code,
            err ~= '' and err:sub(1, 300) or 'no output',
            langdef_hint(err),
            table.concat(stages[#stages], ' ')
          ), ERROR)
        end
        if rerun then
          rerun = false
          M.generate(root)
        end
      end)
    end)
    if not ok_sys then
      -- the spawn itself died (missing binary, hostile environment): a
      -- failed rung like any other, not an error that kills the ladder
      if scratch then
        vim.fn.delete(scratch, 'rf')
        scratch = nil
      end
      if stage < #stages then
        stage = stage + 1
        proj.stage = stage
        return run_stage()
      end
      running = false
      notify(('ctags failed to start: %s'):format(tostring(sysobj)), ERROR)
      if rerun then
        rerun = false
        M.generate(root)
      end
    end
  end
  run_stage()
end

--- :GliterCtags generate <file> — regenerate the tags of ONE file inside
--- the project's tags file, without re-running ctags over the whole tree:
--- the file's old entries are dropped from the tags file, ctags runs on
--- that single file alone, and the fresh entries are spliced in, sorted
--- (Vim's 'tagbsearch' binary search requires a sorted tags file). The
--- file argument is expanded (`%` is the current buffer's file, `~` works
--- too); no argument regenerates the current buffer's file. A file with
--- no project above it gets a tags file of its own (see single_of) —
--- absolute names inside, so the tags follow the file wherever it is
--- opened from. A failure climbs the same ladder `generate` climbs —
--- full flags, `--options=NONE`, then `--options=NONE` bare under a
--- scrubbed environment — always from the first rung (a stage remembered
--- before an option file went stale must not hide the working one below).
---@param path? string
function M.generate_file(path)
  if vim.fn.executable(cfg.bin) ~= 1 then
    return notify(("'%s' not found — install universal-ctags"):format(cfg.bin), ERROR)
  end
  if path and path ~= '' then
    path = vim.fn.expand(path)
  end
  if type(path) ~= 'string' or path == '' then
    path = vim.api.nvim_buf_get_name(0)
  end
  if path == '' then
    return notify('No file to generate tags for.', WARN)
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  if vim.uv.fs_stat(path) == nil then
    return notify(('No such file: %s'):format(path), WARN)
  end

  local root = root_of(0)
  local proj = root and project_of(root) or single_of(path)
  vim.fn.mkdir(vim.fs.dirname(proj.file), 'p')
  -- how the recursive run names this file inside the tags file: relative
  -- to the root ctags ran in (absolute when the file lies outside it — and
  -- always absolute for a single-file project, whose root is just its dir)
  local rel = path
  if root and path:sub(1, #root + 1) == root .. '/' then
    rel = path:sub(#root + 2)
  end

  local universal = true
  local ok_v, v = pcall(function()
    return vim.system({ cfg.bin, '--version' }, { text = true }):wait()
  end)
  if ok_v and v and v.stdout and not v.stdout:match('Universal Ctags') then
    universal = false
  end

  -- The ladder of M.generate, one file at a time: full flags, then
  -- --options=NONE (a stale ~/.ctags.d `--langdef=css` dies with
  -- `Language "css" already defined` — so can $CTAGS), then the SANDBOX:
  -- a scratch cwd, a dark HOME, a scrubbed environment — from the first
  -- rung, every time. The sandbox rung names the file absolutely; the
  -- splice below rewrites its entries back to the file's own spelling.
  local max_stage = universal and 3 or 2
  local tmp = vim.fn.tempname()
  local function stage_args(stage)
    -- --options=NONE has to be the FIRST option of the command line:
    -- universal-ctags scans only the leading options for it, and stops
    -- at the first one it does not recognize (options.c:
    -- previewFirstOption). Anywhere later, NONE is parsed as an option
    -- FILE literally so named — "ctags: cannot stat \"NONE\" : No such
    -- file or directory" — and the rung dies for a reason no option
    -- file ever caused.
    local a = { cfg.bin }
    if universal and stage >= 2 then
      a[#a + 1] = '--options=NONE'
    end
    a[#a + 1] = '-f'
    a[#a + 1] = tmp
    if stage == 1 then
      a[#a + 1] = universal and '--extras=+q' or '--extra=+q'
      a[#a + 1] = universal and '--fields=+nS' or '--fields=+n'
      for _, x in ipairs(cfg.extra_args) do
        a[#a + 1] = x
      end
      a[#a + 1] = rel
    elseif universal and stage == 2 then
      -- the stale option files off (a ~/.ctags.d `--langdef=css` dies
      -- with `Language "css" already defined` — so can $CTAGS), flags on
      a[#a + 1] = '--extras=+q'
      a[#a + 1] = '--fields=+nS'
      a[#a + 1] = rel
    else
      -- the SANDBOX rung (universal's 3rd, exuberant's 2nd): bare, and
      -- the file argument ABSOLUTE — the scratch cwd cannot resolve a
      -- path relative to the project root
      a[#a + 1] = path
    end
    return a
  end
  local stage = 1
  local ok_r, r = false, nil
  local scratch = nil
  while true do
    local opts = { cwd = proj.root, text = true }
    if stage == max_stage then
      scratch, opts = sandbox_opts()
    elseif stage > 1 then
      opts.env = { PATH = vim.env.PATH or '/usr/local/bin:/usr/bin:/bin', CTAGS = '' }
    end
    ok_r, r = pcall(function()
      return vim.system(stage_args(stage), opts):wait()
    end)
    if scratch then
      vim.fn.delete(scratch, 'rf')
      scratch = nil
    end
    if ok_r and r and r.code == 0 then
      break
    end
    if stage < max_stage then
      stage = stage + 1
    else
      break
    end
  end
  if not ok_r or not r or r.code ~= 0 then
    os.remove(tmp)
    local started = ok_r and r ~= nil
    local err = started and vim.trim((r.stderr or '') .. (r.stdout or '')) or tostring(r or 'failed to run')
    return notify(('ctags failed (exit %s): %s%s\n  command: %s'):format(
      started and r.code or '?',
      err ~= '' and err:sub(1, 300) or 'no output',
      started and langdef_hint(err) or '',
      table.concat(stage_args(max_stage), ' ')
    ), ERROR)
  end
  local sandboxed = stage == max_stage
  proj.stage = stage

  -- splice: keep every line that is not this file's, then the fresh ones,
  -- sorted by tag name so binary searching ('tagbsearch') keeps working.
  -- A runaway tags file is not spliced — reading and re-writing it in one
  -- piece is exactly the resource spike this module tries to prevent.
  local st_old = vim.uv.fs_stat(proj.file)
  if st_old and (st_old.size / 1048576) > cfg.warn_mb then
    os.remove(tmp)
    return notify(('the tags file is %.0f MB — splicing it in one piece would spike the editor; regenerate inside a narrower root first'):format(st_old.size / 1048576), WARN)
  end
  local ok_old, old = pcall(vim.fn.readfile, proj.file)
  local merged = {}
  for _, l in ipairs(ok_old and old or {}) do
    local drop = false
    if l ~= '' and l:sub(1, 1) ~= '!' then
      local f = l:match('^[^\t]+\t([^\t]+)')
      drop = f == rel or f == path -- both spellings of this file: the
      -- run's relative one, and the absolute one (a sandboxed or
      -- single-file run) — a mixed file must not survive either
    end
    if not drop then
      merged[#merged + 1] = l
    end
  end
  local added = 0
  for _, l in ipairs(vim.fn.readfile(tmp)) do
    -- the fresh run's own `!_TAG_` headers are dropped: the file being
    -- spliced into already has its own, and the count says entries
    if l ~= '' and l:sub(1, 1) ~= '!' then
      if sandboxed then
        -- the sandbox rung named the file absolutely (it ran from a
        -- scratch cwd); splice back to the spelling the file's other
        -- entries use
        local parts = vim.split(l, '\t', { plain = true })
        if #parts >= 3 and parts[2] == path then
          parts[2] = rel
          l = table.concat(parts, '\t')
        end
      end
      merged[#merged + 1] = l
      added = added + 1
    end
  end
  os.remove(tmp)
  table.sort(merged, function(a, b)
    local ha, hb = a:sub(1, 1) == '!', b:sub(1, 1) == '!'
    if ha ~= hb then
      return ha -- the `!` header lines stay on top
    end
    if ha then
      return false
    end
    return a < b -- tag name first on the line: byte order, what Vim expects
  end)
  vim.fn.writefile(merged, proj.file)
  proj.entries = nil -- force a re-read (mtime moved; be explicit anyway)
  proj.mtime = nil

  -- this splice was made relative to the root it ran in (absolute names
  -- for a single-file project): entries resolve against it
  proj.base = proj.single and proj.root or nil
  notify(('tags: %d entries for %s (%s)'):format(added, proj.single and path or rel, proj.root))
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      if root then
        if root_of(b) == root then
          set_buf_tags(b, proj)
        end
      elseif vim.fs.normalize(vim.api.nvim_buf_get_name(b)) == path then
        set_buf_tags(b, proj)
      end
    end
  end
end

--- :GliterCtags list — the picker for `pat` (default: the word under the
--- cursor). One match jumps straight to it.
---@param pat string?
function M.list(pat)
  pat = ask_pattern(pat)
  if not pat then
    return
  end
  local proj = ready_project(0)
  if not proj then
    return
  end
  local matches = matches_of(entries_of(proj), pat)
  truncation_notice(proj)
  if #matches == 0 then
    return notify(('No tags matching %s.'):format(pat), WARN)
  end
  if #matches == 1 then
    goto_entry(matches[1], vim.api.nvim_get_current_win())
    return
  end
  open_picker(pat, matches, vim.api.nvim_get_current_win())
end

--- :GliterCtags quickfix — every match of `pat` (default: the word under
--- the cursor) in the quickfix list.
---@param pat string?
function M.quickfix(pat)
  pat = ask_pattern(pat)
  if not pat then
    return
  end
  local proj = ready_project(0)
  if not proj then
    return
  end
  local matches = matches_of(entries_of(proj), pat)
  truncation_notice(proj)
  if #matches == 0 then
    return notify(('No tags matching %s.'):format(pat), WARN)
  end
  table.sort(matches, function(a, b)
    if a.abs ~= b.abs then
      return a.abs < b.abs
    end
    return (a.line or 0) < (b.line or 0)
  end)
  local seen, items = {}, {}
  for _, e in ipairs(matches) do
    local key = e.abs .. ':' .. (e.line or 0)
    if not seen[key] then
      seen[key] = true
      local item = { filename = e.abs, text = ('%s [%s]%s'):format(e.name, e.kind or '?', e.sig and (' ' .. e.sig) or '') }
      if e.line then
        item.lnum = e.line
      end
      items[#items + 1] = item
    end
  end
  vim.fn.setqflist({}, ' ', { title = 'gliter.ctags: ' .. pat, items = items })
  if cfg.quickfix.open then
    vim.cmd(('botright %dcopen'):format(cfg.quickfix.height))
  end
end

--- :GliterCtags file — the symbols of the current file, by line, in the
--- quickfix list.
function M.file_tags()
  local proj = ready_project(0)
  if not proj then
    return
  end
  local abs = vim.fs.normalize(vim.api.nvim_buf_get_name(0))
  local items = {}
  for _, e in ipairs(entries_of(proj)) do
    if e.abs == abs and e.line then
      items[#items + 1] = {
        filename = e.abs,
        lnum = e.line,
        text = ('%s [%s]%s'):format(e.name, e.kind or '?', e.sig and (' ' .. e.sig) or ''),
      }
    end
  end
  if #items == 0 then
    return notify(('No tags recorded for %s.'):format(abs), WARN)
  end
  table.sort(items, function(a, b)
    return a.lnum < b.lnum
  end)
  vim.fn.setqflist({}, ' ', { title = 'gliter.ctags: ' .. vim.fs.basename(abs), items = items })
  if cfg.quickfix.open then
    vim.cmd(('botright %dcopen'):format(cfg.quickfix.height))
  end
end

------------------------------------------------------------------ setup() --

---@param opts? table
function M.setup(opts)
  M.did_setup = true
  cfg = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})

  if cfg.keys then
    if cfg.keys.list then
      vim.keymap.set('n', cfg.keys.list, function()
        M.list()
      end, { desc = 'gliter.ctags: list the tags of the word under the cursor' })
    end
    if cfg.keys.quickfix then
      vim.keymap.set('n', cfg.keys.quickfix, function()
        M.quickfix()
      end, { desc = 'gliter.ctags: tag matches into the quickfix list' })
    end
    if cfg.keys.generate then
      vim.keymap.set('n', cfg.keys.generate, function()
        M.generate()
      end, { desc = 'gliter.ctags: regenerate the tags file' })
    end
  end

  vim.api.nvim_create_user_command('GliterCtags', function(o)
    local args = vim.split(o.args or '', '%s+', { trimempty = true })
    local sub = table.remove(args, 1) or 'list'
    local pat = table.concat(args, ' ')
    if sub == 'generate' or sub == 'gen' then
      if pat ~= '' then
        M.generate_file(pat) -- :GliterCtags generate % — one file only
      else
        M.generate()
      end
    elseif sub == 'list' then
      M.list(pat ~= '' and pat or nil)
    elseif sub == 'quickfix' or sub == 'qf' then
      M.quickfix(pat ~= '' and pat or nil)
    elseif sub == 'file' or sub == 'symbols' then
      M.file_tags()
    else
      notify(('Unknown subcommand: %s (generate, list, quickfix, file)'):format(sub), WARN)
    end
  end, {
    nargs = '*',
    complete = function(arg_lead, cmd_line, _)
      -- how many arguments are fully typed? 0 = the subcommand itself is
      -- being completed (silent: completion never notifies).
      local words = vim.split(vim.trim(cmd_line), '%s+')
      local completing_new = cmd_line:match('%s$') ~= nil
      local n_done = #words - 1 - (completing_new and 0 or 1)
      if n_done <= 0 then
        local out = {}
        for _, s in ipairs({ 'generate', 'list', 'quickfix', 'file' }) do
          if s:find(arg_lead, 1, true) == 1 then
            out[#out + 1] = s
          end
        end
        return out
      end
      -- `generate` takes a file argument (% is the current buffer's):
      -- complete file names, not tag names
      local sub = words[2]
      if sub == 'generate' or sub == 'gen' then
        return vim.fn.getcompletion(arg_lead, 'file')
      end
      local root = root_of(0)
      if not root then
        return {}
      end
      local proj = project_of(root)
      if not vim.uv.fs_stat(proj.file) then
        return {}
      end
      local out = {}
      for _, e in ipairs(entries_of(proj)) do
        if e.name:find(arg_lead, 1, true) == 1 then
          out[#out + 1] = e.name
          if #out >= 30 then
            break
          end
        end
      end
      return out
    end,
    desc = 'gliter.ctags: generate | list [pat] | quickfix [pat] | file',
  })

  local group = vim.api.nvim_create_augroup('GliterCtags', { clear = true })

  -- <C-]> and :tag work out of the box: whatever tags file belongs to the
  -- file's project goes into that buffer's 'tags' (buffer-local, so projects
  -- stay apart) — ours, or one already sitting in the project root or next
  -- to the file.
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufWinEnter' }, {
    group = group,
    callback = function(a)
      if vim.bo[a.buf].buftype ~= '' then
        return
      end
      local proj = discover(a.buf)
      if proj then
        set_buf_tags(a.buf, proj)
      end
    end,
  })

  -- Regenerate (debounced) on save, but only where tags already exist —
  -- the first :GliterCtags generate opts a project (or a loose file) in.
  -- A rootless file regenerates ITS OWN tags, never the directory's: a
  -- save on the Desktop must not fire a recursive ctags over it.
  if cfg.auto_generate then
    vim.api.nvim_create_autocmd('BufWritePost', {
      group = group,
      callback = function(a)
        local root = root_of(a.buf)
        if root then
          local proj = project_of(root)
          if not vim.uv.fs_stat(proj.file) then
            return
          end
          local t = debounce[root]
          if not t then
            t = vim.uv.new_timer()
            debounce[root] = t
          end
          t:stop()
          t:start(500, 0, vim.schedule_wrap(function()
            M.generate(root)
          end))
          return
        end
        local bname = vim.api.nvim_buf_get_name(a.buf)
        if bname == '' then
          return
        end
        local proj = single_of(bname)
        if not vim.uv.fs_stat(proj.file) then
          return
        end
        local t = debounce[proj.file]
        if not t then
          t = vim.uv.new_timer()
          debounce[proj.file] = t
        end
        t:stop()
        t:start(500, 0, vim.schedule_wrap(function()
          M.generate_file(bname)
        end))
      end,
    })
  end

  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(a)
      buf_root[a.buf] = nil
      pickers[a.buf] = nil
    end,
  })

  return M
end

return M
