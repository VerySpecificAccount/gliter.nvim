--- Adapter between this plugin and native netrw (v184, Neovim 0.12+).
---
--- Nothing here creates a buffer: every function works on the buffer netrw itself rendered.
--- We read netrw's documented state (`b:netrw_curdir`, `w:netrw_liststyle`, `w:netrw_treetop`,
--- `w:netrw_bannercnt`), parse the listing text, and ask netrw to refresh itself afterwards.
local fs = require('gliter.netrw.fs')
local config = require('gliter.netrw.config')

local M = {}

M.THIN, M.LONG, M.WIDE, M.TREE = 0, 1, 2, 3

---@class GliterNetrwCtx
---@field buf integer
---@field win integer
---@field root string   directory shown (tree style: the tree's top directory)
---@field style integer 0 thin, 1 long, 2 wide, 3 tree
---@field first integer first listing line (1-based), i.e. just below the banner

---@class GliterNetrwEntry
---@field lnum integer  1-based line
---@field col integer   0-based byte column where the name starts
---@field end_col integer
---@field name string
---@field display string the name as the listing shows it — `dir/`, `link@`,
---`file*`, the text a `/` search in the buffer matches
---@field path string   absolute path
---@field is_dir boolean netrw shows it with a trailing slash

--- The first listing line when the window never saw this buffer's listing:
--- netrw's banner is `"`-prefixed lines, and the listing starts at the first
--- line that is not one. A window that jumped to an already-listed buffer
--- (g:netrw_fastbrowse=2 reuses them under eventignore=all — no listing
--- runs, so no w:netrw_bannercnt is set for the window) carries none of its
--- own, and reading the banner off the text keeps a render from writing the
--- custom listing over it from line 1.
---@param buf integer
---@return integer
local function banner_end(buf)
  local n = vim.api.nvim_buf_line_count(buf)
  for i = 1, math.min(n, 20) do
    local l = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ''
    if l:sub(1, 1) ~= '"' then
      return i
    end
  end
  return math.min(n, 20) + 1
end

---@param buf? integer
---@param win? integer
---@return GliterNetrwCtx? ctx, string? err
function M.context(buf, win)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= 'netrw' then
    return nil, 'not a netrw buffer'
  end
  if not (win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf) then
    local cur = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(cur) == buf then
      win = cur
    else
      win = vim.fn.win_findbuf(buf)[1]
    end
  end
  if not win then
    return nil, 'netrw buffer is not displayed in a window'
  end
  local style = vim.w[win].netrw_liststyle or vim.g.netrw_liststyle or 0
  -- In tree style b:netrw_curdir follows the last expanded directory; the stable root is the treetop.
  local root = style == M.TREE and vim.w[win].netrw_treetop or vim.b[buf].netrw_curdir
  if type(root) ~= 'string' or root == '' then
    return nil, 'cannot determine the netrw directory'
  end
  if root:match('^%a[%w+.-]+://') then
    return nil, 'remote (scp/ftp/http) directories are not supported'
  end
  return {
    buf = buf,
    win = win,
    root = fs.normalize(root),
    style = style,
    first = vim.w[win].netrw_bannercnt or banner_end(buf),
  }
end

---------------------------------------------------------------------------
-- Listing parser
---------------------------------------------------------------------------

--- netrw appends "\t --> target" to symlinks in thin and tree style.
local function strip_link(raw)
  return (raw:gsub('\t %-%->.*$', ''))
end

--- Turn the text netrw displayed into a real name. netrw decorates entries:
--- `/` directory, `@` symlink, `*` executable, `|` fifo, `=` socket.
--- The filesystem decides whether a trailing `*` is a decoration or part of the name.
---@return string name, boolean is_dir
local function resolve(dir, raw)
  if raw:sub(-1) == '/' then
    return raw:sub(1, -2), true
  end
  if fs.exists(fs.join(dir, raw)) then
    return raw, false
  end
  if raw:find('[@*|=]$') then
    return raw:sub(1, -2), false
  end
  return raw, false
end

local function make(lnum, col, raw, dir, name, is_dir)
  local path
  if name == '..' then
    path = fs.dirname(dir) -- the parent, as netrw's own Enter on `..` browses it
  elseif name == '.' then
    path = dir
  else
    path = fs.join(dir, name)
  end
  return {
    lnum = lnum,
    col = col,
    end_col = col + #raw,
    name = name,
    display = raw,
    path = path,
    is_dir = is_dir,
  }
end

local function is_dot(name)
  return name == '.' or name == '..' or name == ''
end

--- Long style: `name<padding>  <size> <date>`; name field is padded, size always follows 2+ spaces.
local function long_name(dir, line)
  local init, first = 1, nil
  while true do
    local s = line:find('%s%s+%-?[%d%.,]+%a?%s', init)
    if not s then
      break
    end
    local raw = line:sub(1, s - 1)
    local name, is_dir = resolve(dir, raw)
    first = first or { raw, name, is_dir }
    if fs.exists(fs.join(dir, name)) then
      return raw, name, is_dir
    end
    init = s + 1
  end
  if first then
    return first[1], first[2], first[3]
  end
  local raw = line:gsub('%s+$', '')
  local name, is_dir = resolve(dir, raw)
  return raw, name, is_dir
end

--- Wide style: cells padded with at least two spaces.
local function wide_cells(line)
  local cells, pos = {}, 1
  while true do
    local s = line:find('%S', pos)
    if not s then
      break
    end
    local e = line:find('%s%s', s)
    local text = line:sub(s, e and e - 1 or #line):gsub('%s+$', '')
    cells[#cells + 1] = { col = s - 1, text = text }
    if not e then
      break
    end
    pos = e + 2
  end
  return cells
end

---------------------------------------------------------------------------
-- Custom listing (`setup { listing = 'ls -ltrhF --color=always' }`;
-- rendered by custom.lua, colored by color.lua)
---------------------------------------------------------------------------

--- ls's classify suffixes: `/` directory, `@` symlink, `*` executable,
--- `|` fifo, `=` socket.
local CLASSIFY = '/%@*|='

--- Read a token the way the shell would: `'my dir'`, `"my dir"`, `my\ dir`,
--- `'it'\''s'` — the forms eza, exa, GNU ls (`--quoting-style=shell-escape`,
--- the default) and `ls -b` print around a name with spaces, quotes or
--- other characters a shell would read — and become the plain name when
--- the shell's quoting comes off. Unquoted tokens come back unchanged.
--- (`\x` -> `x`, `'x'` -> `x`, `"x"` -> `x`, `"x"`'s `\x` -> `x`; a lone
--- quote or backslash at the end is kept — half a pair quotes nothing.)
---@param s string
---@return string
local function shell_unescape(s)
  if not (s:find("['\\\"]", 1) or s:find('\\', 1, true)) then
    return s
  end
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == '\\' and i < n then
      out[#out + 1] = s:sub(i + 1, i + 1)
      i = i + 2
    elseif c == "'" or c == '"' then
      local q = c
      i = i + 1
      while i <= n do
        local d = s:sub(i, i)
        if d == q then
          i = i + 1
          break
        elseif d == '\\' and q == '"' and i < n then
          out[#out + 1] = s:sub(i + 1, i + 1)
          i = i + 2
        else
          out[#out + 1] = d
          i = i + 1
        end
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

--- A token wrapped in ONE pair of single quotes, however sloppily: some
--- listing tools quote a spaced name by wrapping it and never escape the
--- apostrophes inside (`'it's here'`, `'quote'd file.txt'`). The shell's
--- own reading of that token stops at the first inner quote and loses the
--- character; here the OUTERMOST pair comes off instead — everything
--- between the first quote and the last one is the name. Only tried after
--- the shell reading failed to match an entry, so a name that really ends
--- in a quote (and resolved as printed) is never misread.
---@param s string
---@return string
local function naive_unquote(s)
  if #s >= 2 and s:sub(1, 1) == "'" and s:sub(-1) == "'" then
    return s:sub(2, -2)
  end
  return s
end

--- The real entries of `dir` as a name -> is_dir table.
local function name_set(dir)
  local set = {}
  for _, e in ipairs(fs.list(dir)) do
    set[e.name] = e.type == 'directory'
  end
  return set
end

--- One surface form of a token against the real entries: the name as
--- printed, then its `./`-stripped and classify-suffix-stripped readings.
---@param set table
---@param token string
---@return string? name, boolean? is_dir
local function resolve_one(set, token)
  if token == '' then
    return nil
  end
  if set[token] ~= nil then
    return token, set[token]
  end
  -- `.` and `..`, when a listing prints them (`ls -la` does, `eza -l`
  -- does not), are entries of a kind: netrw's own Enter browses up from
  -- `..` and re-lists on `.` — Enter on the custom listing must do the
  -- same, not announce that nothing is there.
  if token == '.' or token == '..' then
    return token, true
  end
  -- a leading `./` (`find .` prints it on every line) is part of no name
  if token:sub(1, 2) == './' then
    local t = token:sub(3)
    if set[t] ~= nil then
      return t, set[t]
    end
    token = t
  end
  local base, suffix = token:match('^(.-)([' .. CLASSIFY .. '])$')
  if base ~= nil and base ~= '' and set[base] ~= nil then
    return base, suffix == '/'
  end
  return nil
end

--- A shown token back to a real entry: the token itself when a file wears
--- every character of its name (a name may legitimately end in `*`), else
--- the token minus one classify suffix — and whether that suffix was the
--- directory `/`. A shell-quoted token (`'my dir/'`, `my\ dir`) is read
--- through the shell's eyes first, so the quoting a listing command puts
--- around a name with spaces never hides the entry it wraps.
---@param set table
---@param token string
---@return string? name, boolean? is_dir
local function resolve_custom(set, token)
  local name, is_dir = resolve_one(set, token)
  if name then
    return name, is_dir
  end
  local bare = shell_unescape(token)
  if bare ~= token and bare ~= '' then
    name, is_dir = resolve_one(set, bare)
    if name then
      return name, is_dir
    end
  end
  -- the sloppy quoting (`'it's here'`): the shell reading lost the inner
  -- quote — the outermost pair may be the wrapper the tool meant
  local outer = naive_unquote(token)
  if outer ~= token and outer ~= '' then
    return resolve_one(set, outer)
  end
  return nil
end

--- A token that names no entry of `dir` may still name a file under it:
--- `fd .` prints `sub/file.lua`, `git ls-files` the tracked paths. The
--- token is read as a path relative to `dir` — a leading `./` dropped,
--- ls's classify suffixes and the shell quoting around a spaced name
--- (`'my dir/file'`) read the same way — and when the filesystem
--- has it, it becomes an entry, one that opens (`listing_paths`).
---@param root string
---@param token string
---@return string? name, boolean? is_dir
local function resolve_path(root, token)
  if token == '' then
    return nil
  end
  for _, form in ipairs({ token, shell_unescape(token), naive_unquote(token) }) do
    local t = form:match('^%./(.+)') or form
    if t ~= '' and t ~= '/' and t ~= '.' and t ~= '..' and t:sub(1, 1) ~= '/' then
      local is_dir = t:sub(-1) == '/'
      t = t:gsub('[' .. CLASSIFY .. ']$', '')
      if t ~= '' and t ~= '.' and t ~= '..' then
        -- the filesystem decides: a token that is not a path under `root`
        -- (an `ls -l` line's metadata, a heading, a summary) stats to nothing
        local st = vim.uv.fs_stat(fs.join(root, t))
        if st then
          return t, st.type == 'directory' or is_dir
        end
      end
    end
  end
  return nil
end

--- Positions where an entry name can begin on a line: the first non-blank
--- of the line and of every blank run after it.
local function word_starts(line)
  local out, gap = {}, true
  for pos = 1, #line do
    local c = line:sub(pos, pos)
    if c == ' ' or c == '\t' then
      gap = true
    else
      if gap then
        out[#out + 1] = pos
      end
      gap = false
    end
  end
  return out
end

--- One custom-listing line's entries. Three shapes, in order:
---   1. `ls -m`'s comma stream — every ', '-separated chunk an entry;
---   2. `ls -C`/`-x` column rows — every chunk of a 2+-space split an entry
---      (taken only when every chunk resolves: a `ls -l` line's metadata
---      never does, so the long format falls through to 3);
---   3. the entry at the end — the longest token starting at a word start
---      that resolves (a long-format name field, or the plain one-per-line
---      name), a symlink's ` -> target` tail cut away first — so `link ->
---      target` reads as `link`, while a file genuinely named `x -> y` is
---      still tried whole (it only loses to a plain `x` sitting next to it,
---      a shape no listing can tell apart).
local function parse_custom_line(set, dir, line, lnum, out, paths)
  if line == '' then
    return
  end
  local function try_chunks(pat, plain)
    local res, pos = {}, 1
    while true do
      local s, e = line:find(pat, pos, plain)
      if not s then
        break
      end
      res[#res + 1] = { text = line:sub(pos, s - 1), col = pos }
      pos = e + 1
    end
    if #res == 0 then
      return false
    end
    res[#res + 1] = { text = line:sub(pos), col = pos }
    if #res < 2 then
      return false
    end
    local resolved = {}
    for i, c in ipairs(res) do
      local name, is_dir = resolve_custom(set, c.text)
      if not name then
        return false
      end
      resolved[i] = { c, name, is_dir }
    end
    for _, r in ipairs(resolved) do
      out[#out + 1] = make(lnum, r[1].col - 1, r[1].text, dir, r[2], r[3])
    end
    return true
  end
  local function suffix_from(text)
    for _, pos in ipairs(word_starts(text)) do
      local token = text:sub(pos)
      local name, is_dir = resolve_custom(set, token)
      if name then
        out[#out + 1] = make(lnum, pos - 1, token, dir, name, is_dir)
        return true
      end
      if paths then
        local rel, pdir = resolve_path(dir, token)
        if rel then
          out[#out + 1] = make(lnum, pos - 1, token, dir, rel, pdir)
          return true
        end
      end
    end
    return false
  end
  if try_chunks(', ', true) then
    return
  end
  if try_chunks('%s%s+', false) then
    return
  end
  if line:find(' -> ', 1, true) then
    if not suffix_from(line:gsub(' %-> .-$', '')) then
      suffix_from(line)
    end
    return
  end
  suffix_from(line)
end

---------------------------------------------------------------------------
-- Custom listing, `tree` shape: an outline under connector glyphs
---------------------------------------------------------------------------

-- tree's indentation units and connectors, utf-8 and --charset=ascii both.
-- tree 2.x prints '│' followed by two non-breaking spaces and a space
-- (eight bytes: '\226\148\130\194\160\194\160 '); older trees use '│   '
-- (six); the continuation below a last sibling is four plain spaces;
-- --charset=ascii uses '|   ' and '|-- ' / '`-- '.
local TREE_UNITS = {
  '\226\148\130\194\160\194\160 ', 8,
  '\226\148\130   ', 6,
  '    ', 4,
  '|   ', 4,
}
local TREE_CONNECTORS = { '├── ', '└── ', '|-- ', '`-- ' }

--- Where a tree line's entry sits: the position after the indentation,
--- the depth (indentation units), and the connector's byte length — 0
--- when the line has none (the root line above the outline, the summary
--- below it, or a line of some other command's shape).
---@param line string
---@return integer pos, integer depth, integer conn
local function tree_walk(line)
  local pos, depth = 1, 0
  while true do
    local matched = false
    for u = 1, #TREE_UNITS, 2 do
      local unit, len = TREE_UNITS[u], TREE_UNITS[u + 1]
      if line:sub(pos, pos + len - 1) == unit then
        pos = pos + len
        depth = depth + 1
        matched = true
        break
      end
    end
    if not matched then
      break
    end
  end
  for _, c in ipairs(TREE_CONNECTORS) do
    if line:sub(pos, pos + #c - 1) == c then
      return pos, depth, #c
    end
  end
  return pos, depth, 0
end

--- `tree` and its kin (`tree -C`, `tree -F --dirsfirst`, `--charset=ascii`):
--- entries hang under connector glyphs at depths set by the indentation —
--- `├── name`, `│   └── name` — and an entry's parent is the last
--- directory seen one level up (parents[0] is the listed directory). The
--- outline is walked from the listing's first line whatever range was
--- asked for: the parent chain is state only the whole outline builds.
--- The root line tree prints above the outline and the summary below it
--- carry no connector and no entry — except a root line that names a
--- directory of the listing (`tree sub` prints `sub`), which then becomes
--- the outline's parent. `-F` puts ls's classify suffixes on the names;
--- without it the filesystem says what each name is. A symlink's
--- ` -> target` tail is cut, as in the flat shapes.
---@param ctx GliterNetrwCtx
---@param set table root directory's name set
---@param from integer
---@param to integer
---@param out GliterNetrwEntry[]
local function parse_custom_tree(ctx, set, from, to, out)
  local lines = vim.api.nvim_buf_get_lines(ctx.buf, ctx.first - 1, to, false)
  local parents = { [0] = ctx.root }
  local sets = { [ctx.root] = set }
  local function set_of(dir)
    if not sets[dir] then
      sets[dir] = name_set(dir)
    end
    return sets[dir]
  end
  local saw_entry = false
  for idx, line in ipairs(lines) do
    local lnum = ctx.first + idx - 1
    local pos, depth, conn = tree_walk(line)
    if conn == 0 then
      if not saw_entry and line:match('%S') then
        -- above the outline: the root line. `.` (or a path) leaves the
        -- listed directory as the parent; `tree sub`'s `sub` takes over.
        -- `.` itself — the root line `tree` prints — is the listed
        -- directory already, and `..` never re-roots anything.
        local raw = line:gsub('%s+$', '')
        local name, is_dir = resolve_custom(set, raw)
        if name and is_dir and name ~= '.' and name ~= '..' then
          parents[0] = fs.join(ctx.root, name)
        end
      end
      -- below the outline (or nowhere near one): the summary tree
      -- trails with, blank padding — never an entry
    else
      saw_entry = true
      local raw = line:sub(pos + conn)
      if raw:find(' -> ', 1, true) then
        raw = raw:gsub(' %-> .*$', '')
      end
      local parent = parents[depth]
      if parent then
        local name, is_dir = resolve_custom(set_of(parent), raw)
        if name then
          if lnum >= from then
            out[#out + 1] = make(lnum, pos + conn - 1, raw, parent, name, is_dir)
          end
          if is_dir then
            parents[depth + 1] = fs.join(parent, name)
          end
        end
      end
    end
  end
end

---@param ctx GliterNetrwCtx
---@param from integer
---@param to integer
---@return GliterNetrwEntry[]
local function parse_custom(ctx, from, to)
  local lines = vim.api.nvim_buf_get_lines(ctx.buf, from - 1, to, false)
  local set = name_set(ctx.root)
  local out = {}
  -- one connector anywhere in the range: the range is a tree outline
  for _, line in ipairs(lines) do
    local _, _, conn = tree_walk(line)
    if conn > 0 then
      parse_custom_tree(ctx, set, from, to, out)
      return out
    end
  end
  for idx, line in ipairs(lines) do
    parse_custom_line(set, ctx.root, line, from + idx - 1, out, config.options.listing_paths)
  end
  return out
end

---@param ctx GliterNetrwCtx
---@param from integer
---@param to integer
---@return GliterNetrwEntry[]
local function parse_tree(ctx, from, to)
  local lines = vim.api.nvim_buf_get_lines(ctx.buf, ctx.first - 1, to, false)
  local parents, out = {}, {}
  for idx, line in ipairs(lines) do
    local lnum = ctx.first + idx - 1
    local depth, i = 0, 1
    while line:sub(i, i + 1) == '| ' do
      depth, i = depth + 1, i + 2
    end
    local raw = strip_link(line:sub(i))
    if raw ~= '' then
      if depth == 0 then
        -- `../` is the parent link; any other depth-0 line is the tree root itself.
        if raw ~= '../' and raw ~= './' then
          parents[0] = ctx.root
        end
      else
        local parent = parents[depth - 1]
        if parent then
          local name, is_dir = resolve(parent, raw)
          if not is_dot(name) then
            local e = make(lnum, i - 1, raw, parent, name, is_dir)
            if is_dir then
              parents[depth] = e.path
            end
            if lnum >= from then
              out[#out + 1] = e
            end
          end
        end
      end
    end
  end
  return out
end

--- Parse listing lines `from..to` (1-based, inclusive) into entries. Banner lines,
--- `../` and `./` never appear in the result.
---@param ctx GliterNetrwCtx
---@param from integer
---@param to integer
---@return GliterNetrwEntry[]
function M.parse(ctx, from, to)
  from = math.max(from, ctx.first)
  to = math.min(to, vim.api.nvim_buf_line_count(ctx.buf))
  if to < from then
    return {}
  end
  if ctx.style == M.TREE then
    return parse_tree(ctx, from, to)
  end
  if vim.b[ctx.buf].gliter_netrw_custom then
    return parse_custom(ctx, from, to)
  end
  local out = {}
  local lines = vim.api.nvim_buf_get_lines(ctx.buf, from - 1, to, false)
  for idx, line in ipairs(lines) do
    local lnum = from + idx - 1
    if ctx.style == M.WIDE then
      for _, cell in ipairs(wide_cells(line)) do
        local name, is_dir = resolve(ctx.root, cell.text)
        if not is_dot(name) then
          out[#out + 1] = make(lnum, cell.col, cell.text, ctx.root, name, is_dir)
        end
      end
    elseif ctx.style == M.LONG then
      local raw, name, is_dir = long_name(ctx.root, line)
      if raw ~= '' and not is_dot(name) then
        out[#out + 1] = make(lnum, 0, raw, ctx.root, name, is_dir)
      end
    else
      local raw = strip_link(line)
      if raw ~= '' then
        local name, is_dir = resolve(ctx.root, raw)
        if not is_dot(name) then
          out[#out + 1] = make(lnum, 0, raw, ctx.root, name, is_dir)
        end
      end
    end
  end
  return out
end

---@param ctx GliterNetrwCtx
---@return GliterNetrwEntry[]
function M.all(ctx)
  return M.parse(ctx, ctx.first, vim.api.nvim_buf_line_count(ctx.buf))
end

--- The entry under the cursor (wide style: the cell under the cursor; a
--- custom listing with several entries per line: the same column pick).
---@param ctx GliterNetrwCtx
---@return GliterNetrwEntry?
function M.entry_at_cursor(ctx)
  local row, col = unpack(vim.api.nvim_win_get_cursor(ctx.win))
  local entries = M.parse(ctx, row, row)
  if #entries == 0 then
    return nil
  end
  local pick = entries[1]
  if ctx.style == M.WIDE or vim.b[ctx.buf].gliter_netrw_custom then
    for _, e in ipairs(entries) do
      if e.col <= col then
        pick = e
      end
    end
  end
  return pick
end

--- Directory that new/pasted items go into. Tree style follows netrw's own convention:
--- the directory under the cursor, or the parent of the file under the cursor.
---@param ctx GliterNetrwCtx
---@return string
function M.target_dir(ctx)
  if ctx.style == M.TREE then
    local e = M.entry_at_cursor(ctx)
    if e then
      return e.is_dir and e.path or fs.dirname(e.path)
    end
  end
  return ctx.root
end

---------------------------------------------------------------------------
-- Marks (netrw's own `mf`)
---------------------------------------------------------------------------

--- Files marked with `mf` that belong to this listing.
---@param ctx GliterNetrwCtx
---@return string[]
function M.marked(ctx)
  local ok, list = pcall(vim.fn['netrw#Expose'], 'netrwmarkfilelist')
  if not ok or type(list) ~= 'table' then
    return {}
  end
  local out = {}
  for _, p in ipairs(list) do
    p = fs.normalize(p)
    local inside
    if ctx.style == M.TREE then
      inside = fs.is_inside(p, ctx.root)
    else
      inside = fs.dirname(p) == ctx.root
    end
    if inside then
      out[#out + 1] = p
    end
  end
  return out
end

--- Clear netrw's marks (same as netrw's `mu`).
function M.unmark()
  pcall(vim.fn['netrw#Call'], 'NetrwUnmarkAll')
end

---------------------------------------------------------------------------
-- Refresh / reveal
---------------------------------------------------------------------------

--- Ask netrw to re-list the directory shown in `win` (netrw's own <C-l>),
--- then re-apply the custom listing synchronously (gliter.netrw.custom) so
--- anything following the refresh — a reveal, say — reads the custom text,
--- not the netrw text that is about to be replaced. The require is lazy:
--- custom.lua needs this module, and the cycle would not load otherwise.
---@param win integer
function M.refresh_win(win)
  vim.api.nvim_win_call(win, function()
    pcall(vim.cmd.normal, { args = { vim.keycode('<Plug>NetrwRefresh') }, mods = { silent = true } })
  end)
  local buf = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
  if buf and vim.bo[buf].filetype == 'netrw' and vim.b[buf].gliter_netrw_custom then
    require('gliter.netrw.custom').render(buf)
  end
end

---@param ctx GliterNetrwCtx
---@param dirset table<string, boolean>
local function affected(ctx, dirset)
  if dirset[ctx.root] then
    return true
  end
  if ctx.style == M.TREE then
    for d in pairs(dirset) do
      if fs.is_inside(d, ctx.root) then
        return true
      end
    end
  end
  return false
end

--- Move the cursor of `win` onto `path` (no-op when it is not listed, e.g. in a collapsed tree node).
---@param win integer
---@param path string
---@return boolean found
function M.reveal(win, path)
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local ctx = M.context(vim.api.nvim_win_get_buf(win), win)
  if not ctx then
    return false
  end
  for _, e in ipairs(M.all(ctx)) do
    if e.path == path then
      vim.api.nvim_win_set_cursor(win, { e.lnum, e.col })
      return true
    end
  end
  return false
end

--- Refresh every netrw window showing one of `dirs`; netrw buffers that are loaded but
--- hidden are flagged and refreshed when they are shown again.
---@param dirs string[]
---@param reveal? { win: integer, path: string }
function M.refresh_dirs(dirs, reveal)
  local dirset = {}
  for _, d in ipairs(dirs) do
    dirset[fs.normalize(d)] = true
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.bo[buf].filetype == 'netrw' then
      local ctx = M.context(buf, win)
      if ctx and affected(ctx, dirset) then
        M.refresh_win(win)
      end
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].filetype == 'netrw'
      and #vim.fn.win_findbuf(buf) == 0
    then
      local d = vim.b[buf].netrw_curdir
      if type(d) == 'string' and dirset[fs.normalize(d)] then
        vim.b[buf].gliter_netrw_stale = true
      end
    end
  end
  if reveal then
    M.reveal(reveal.win, reveal.path)
  end
end

return M
