-- Word/character primitives that work with no filetype and no treesitter.
--
-- Internal "cipos" = { lnum = 1-based line, ci = 1-based char index }.
-- Public helpers convert to/from 1-based byte columns.
--
-- Convention for region end columns: the FIRST byte of the last character,
-- which is exactly what getpos(".") reports for a charwise visual selection.

local M = {}

local cache = { buf = nil, tick = -1, lines = {} }

local function fetch_line(buf, lnum)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  if cache.buf ~= buf or cache.tick ~= tick then
    cache.buf = buf
    cache.tick = tick
    cache.lines = {}
  end
  local entry = cache.lines[lnum]
  if entry == nil then
    local raw = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ''
    local chars = vim.fn.split(raw, '\\zs')
    local prefix = { 0 }
    for i, c in ipairs(chars) do
      prefix[i + 1] = prefix[i] + #c
    end
    entry = { chars = chars, prefix = prefix, len = #raw }
    cache.lines[lnum] = entry
  end
  return entry
end

M.fetch_line = fetch_line

function M.line_count(buf)
  return vim.api.nvim_buf_line_count(buf)
end

function M.line_len(buf, lnum)
  return fetch_line(buf, lnum).len
end

-- first byte column (1-based) of the last character of a line
function M.line_end_col(buf, lnum)
  local entry = fetch_line(buf, lnum)
  local n = #entry.chars
  if n == 0 then
    return 1
  end
  return entry.prefix[n] + 1
end

function M.ci_to_col(entry, ci)
  ci = math.max(1, math.min(ci, #entry.chars))
  return entry.prefix[ci] + 1
end

function M.col_to_ci(entry, col)
  local n = #entry.chars
  for i = 1, n do
    if col <= entry.prefix[i + 1] then
      return i
    end
  end
  return n + 1
end

-- byte col (1-based) -> cipos
function M.to_cipos(buf, lnum, col)
  local entry = fetch_line(buf, lnum)
  return { lnum = lnum, ci = M.col_to_ci(entry, col) }
end

-- cipos -> first byte col (1-based) of that character
function M.to_col(buf, pos)
  local entry = fetch_line(buf, pos.lnum)
  return M.ci_to_col(entry, pos.ci)
end

local function class_of(c)
  if c == nil or c == '' then
    return 0 -- blank
  end
  if c:find('^%s') then
    return 0
  end
  if c:find('^[%w_]') then
    return 2 -- word
  end
  if #c == 1 then
    return 1 -- ascii punctuation
  end
  return 2 -- multibyte: treat as word char
end

function M.char_at(buf, pos)
  local entry = fetch_line(buf, pos.lnum)
  return entry.chars[pos.ci]
end

-- run (word / punctuation group) containing ci; nil on blank or out of range
function M.run_at(buf, lnum, ci)
  local entry = fetch_line(buf, lnum)
  local c = entry.chars[ci]
  if c == nil or class_of(c) == 0 then
    return nil
  end
  local cl = class_of(c)
  local s, e = ci, ci
  while s > 1 and class_of(entry.chars[s - 1]) == cl do
    s = s - 1
  end
  while e < #entry.chars and class_of(entry.chars[e + 1]) == cl do
    e = e + 1
  end
  return { s = s, e = e }
end

function M.cipos_eq(a, b)
  return a.lnum == b.lnum and a.ci == b.ci
end

function M.cipos_lt(a, b)
  return a.lnum < b.lnum or (a.lnum == b.lnum and a.ci < b.ci)
end

function M.next_cipos(buf, pos)
  local entry = fetch_line(buf, pos.lnum)
  if pos.ci < #entry.chars then
    return { lnum = pos.lnum, ci = pos.ci + 1 }
  end
  if pos.lnum < M.line_count(buf) then
    return { lnum = pos.lnum + 1, ci = 1 }
  end
  return nil
end

function M.prev_cipos(buf, pos)
  if pos.ci > 1 then
    return { lnum = pos.lnum, ci = pos.ci - 1 }
  end
  if pos.lnum > 1 then
    local entry = fetch_line(buf, pos.lnum - 1)
    local n = #entry.chars
    return { lnum = pos.lnum - 1, ci = n > 0 and n or 1 }
  end
  return nil
end

-- `e`-style: position of the LAST char of the run reached going forward.
-- Mid-run: completes the current run. At a run end / on blanks: end of the
-- next run (possibly on a following line).
function M.forward_run_end(buf, pos)
  local run = M.run_at(buf, pos.lnum, pos.ci)
  if run and run.e > pos.ci then
    return { lnum = pos.lnum, ci = run.e }
  end
  local p = pos
  while true do
    p = M.next_cipos(buf, p)
    if not p then
      return nil
    end
    local r = M.run_at(buf, p.lnum, p.ci)
    if r then
      return { lnum = p.lnum, ci = r.e }
    end
  end
end

-- `b`-style: position of the FIRST char of the run reached going backward.
function M.backward_run_start(buf, pos)
  local run = M.run_at(buf, pos.lnum, pos.ci)
  if run and run.s < pos.ci then
    return { lnum = pos.lnum, ci = run.s }
  end
  local p = pos
  while true do
    p = M.prev_cipos(buf, p)
    if not p then
      return nil
    end
    local r = M.run_at(buf, p.lnum, p.ci)
    if r then
      return { lnum = p.lnum, ci = r.s }
    end
  end
end

-- next / previous whole run strictly after / before pos
function M.next_run(buf, pos)
  local p = pos
  while true do
    p = M.next_cipos(buf, p)
    if not p then
      return nil
    end
    local r = M.run_at(buf, p.lnum, p.ci)
    if r then
      return { lnum = p.lnum, s = r.s, e = r.e }
    end
  end
end

function M.prev_run(buf, pos)
  local p = pos
  while true do
    p = M.prev_cipos(buf, p)
    if not p then
      return nil
    end
    local r = M.run_at(buf, p.lnum, p.ci)
    if r then
      return { lnum = p.lnum, s = r.s, e = r.e }
    end
  end
end

-- cipos of the first run START strictly after `pos`; nil at the buffer end.
-- A run containing `pos` is skipped entirely (it starts at/before pos).
function M.next_run_start(buf, pos)
  local p = pos
  local run = M.run_at(buf, p.lnum, p.ci)
  if run then
    p = { lnum = p.lnum, ci = run.e } -- last char of the run containing pos
  end
  local nr = M.next_run(buf, p)
  if not nr then
    return nil
  end
  return { lnum = nr.lnum, ci = nr.s }
end

function M.line_is_blank(buf, lnum)
  local entry = fetch_line(buf, lnum)
  for _, c in ipairs(entry.chars) do
    if class_of(c) ~= 0 then
      return false
    end
  end
  return true
end

-- paragraph (block of non-blank lines) containing the region's lines
function M.paragraph_range(buf, region)
  local n = M.line_count(buf)
  local first = math.max(1, region.s[1])
  local last = math.min(n, region.e[1])
  while first > 1 and not M.line_is_blank(buf, first - 1) do
    first = first - 1
  end
  while last < n and not M.line_is_blank(buf, last + 1) do
    last = last + 1
  end
  return { s = { first, 1 }, e = { last, M.line_end_col(buf, last) } }
end

-- next (dir=1) / previous (dir=-1) paragraph block relative to region
function M.next_paragraph(buf, region, dir)
  local n = M.line_count(buf)
  if dir > 0 then
    local l = math.min(region.e[1], n)
    while l <= n and not M.line_is_blank(buf, l) do
      l = l + 1
    end
    while l <= n and M.line_is_blank(buf, l) do
      l = l + 1
    end
    if l > n then
      return nil
    end
    local first = l
    while l + 1 <= n and not M.line_is_blank(buf, l + 1) do
      l = l + 1
    end
    return { s = { first, 1 }, e = { l, M.line_end_col(buf, l) } }
  else
    local l = math.max(1, region.s[1])
    while l >= 1 and not M.line_is_blank(buf, l) do
      l = l - 1
    end
    while l >= 1 and M.line_is_blank(buf, l) do
      l = l - 1
    end
    if l < 1 then
      return nil
    end
    local last = l
    while l - 1 >= 1 and not M.line_is_blank(buf, l - 1) do
      l = l - 1
    end
    return { s = { l, 1 }, e = { last, M.line_end_col(buf, last) } }
  end
end

return M
