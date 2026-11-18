--- Adapter between this plugin and native netrw (v184, Neovim 0.12+).
---
--- Nothing here creates a buffer: every function works on the buffer netrw itself rendered.
--- We read netrw's documented state (`b:netrw_curdir`, `w:netrw_liststyle`, `w:netrw_treetop`,
--- `w:netrw_bannercnt`), parse the listing text, and ask netrw to refresh itself afterwards.
local fs = require('gliter.netrw.fs')

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
    first = vim.w[win].netrw_bannercnt or 1,
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
  return {
    lnum = lnum,
    col = col,
    end_col = col + #raw,
    name = name,
    display = raw,
    path = fs.join(dir, name),
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
-- Custom listing (`setup { listing = 'ls -ltrhF' }`; rendered by custom.lua)
---------------------------------------------------------------------------

--- ls's classify suffixes: `/` directory, `@` symlink, `*` executable,
--- `|` fifo, `=` socket.
local CLASSIFY = '/%@*|='

--- The real entries of `dir` as a name -> is_dir table.
local function name_set(dir)
  local set = {}
  for _, e in ipairs(fs.list(dir)) do
    set[e.name] = e.type == 'directory'
  end
  return set
end

--- A shown token back to a real entry: the token itself when a file wears
--- every character of its name (a name may legitimately end in `*`), else
--- the token minus one classify suffix — and whether that suffix was the
--- directory `/`.
local function resolve_custom(set, token)
  if token == '' then
    return nil
  end
  if set[token] ~= nil then
    return token, set[token]
  end
  local base, suffix = token:match('^(.-)([' .. CLASSIFY .. '])$')
  if base ~= nil and base ~= '' and set[base] ~= nil then
    return base, suffix == '/'
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
local function parse_custom_line(set, dir, line, lnum, out)
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

---@param ctx GliterNetrwCtx
---@param from integer
---@param to integer
---@return GliterNetrwEntry[]
local function parse_custom(ctx, from, to)
  local lines = vim.api.nvim_buf_get_lines(ctx.buf, from - 1, to, false)
  local set = name_set(ctx.root)
  local out = {}
  for idx, line in ipairs(lines) do
    parse_custom_line(set, ctx.root, line, from + idx - 1, out)
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
