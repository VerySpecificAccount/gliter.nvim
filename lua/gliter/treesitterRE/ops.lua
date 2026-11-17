-- Operators for gliter.treesitterRE.
--
-- A region is { s = { lnum, col }, e = { lnum, col } } with 1-based lines and
-- 1-based byte columns; `e.col` is the FIRST byte of the last character,
-- exactly what getpos(".") reports for a charwise visual selection.
--
-- <BS> works like expand-region (Emacs), by way of nvim-expand-region
-- (lth-go): around the current selection it builds a list of candidate
-- regions — enclosing bracket pairs (inner trimmed, inner raw, with
-- delimiters), treesitter ancestors (plus the span between their
-- delimiters), line and paragraph levels — sorts them by size and walks UP
-- that ladder press by press. <M-BS> walks back down. The tree root and the
-- whole buffer are never rungs, so the climb always stops at the outermost
-- statement (or the paragraph, without a parser).

local text = require('gliter.treesitterRE.text')
local ts = require('gliter.treesitterRE.treesitter')
local state = require('gliter.treesitterRE.state')

local M = {}

-- ------------------------------------------------------------------ regions

local function pos_le(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] <= b[2])
end

local function pos_lt(a, b)
  return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
end

local function contains(outer, inner)
  return pos_le(outer.s, inner.s) and pos_le(inner.e, outer.e)
end

local function strictly(outer, inner)
  return contains(outer, inner) and not state.regions_equal(outer, inner)
end

local function size(r)
  return (r.e[1] - r.s[1]) * 100000 + (r.e[2] - r.s[2])
end

local function overlaps(a, b)
  return pos_le(a.s, b.e) and pos_le(b.s, a.e)
end

-- ---------------------------------------------------------------- selection

local ESC = vim.api.nvim_replace_termcodes('<Esc>', true, true, true)

local function feed(keys)
  vim.cmd('normal! ' .. keys)
end

local function visual_mode()
  local m = vim.api.nvim_get_mode().mode
  if m == 'v' or m == 'V' or m == '\22' then
    return m
  end
  return nil
end

local function current_region(buf)
  local m = visual_mode()
  if not m then
    return nil
  end
  local vs = vim.fn.getpos('v')
  local ve = vim.fn.getpos('.')
  local a, b = { vs[2], vs[3] }, { ve[2], ve[3] }
  if not pos_le(a, b) then
    a, b = b, a
  end
  -- clamp both ends into their lines: `v$` (and friends) report the cursor
  -- one past the last character, which must read as that last character
  a[2] = math.max(1, math.min(a[2], text.line_len(buf, a[1])))
  b[2] = math.max(1, math.min(b[2], text.line_len(buf, b[1])))
  if m == 'V' then
    return { s = { a[1], 1 }, e = { b[1], text.line_end_col(buf, b[1]) } }
  end
  return { s = a, e = b } -- v and blockwise (bounding box)
end

local function cursor_pos()
  local c = vim.api.nvim_win_get_cursor(0)
  return { c[1], c[2] + 1 }
end

local function clamp_col(buf, lnum, col)
  local len = text.line_len(buf, lnum)
  if len <= 0 or col < 1 then
    return 1
  end
  if col > len then
    return len
  end
  return col
end

local function set_visual(buf, region)
  feed(ESC)
  local sc = clamp_col(buf, region.s[1], region.s[2])
  vim.api.nvim_win_set_cursor(0, { region.s[1], sc - 1 })
  feed('v')
  local ec = clamp_col(buf, region.e[1], region.e[2])
  pcall(vim.api.nvim_win_set_cursor, 0, { region.e[1], ec - 1 })
end

local function commit(before, region, dir)
  local buf = vim.api.nvim_get_current_buf()
  set_visual(buf, region)
  state.push(before, region)
  if dir then
    state.get().last_dir = dir
  end
end

-- -------------------------------------------------------------------- words

local function run_region(buf, lnum, run)
  local entry = text.fetch_line(buf, lnum)
  return {
    s = { lnum, text.ci_to_col(entry, run.s) },
    e = { lnum, text.ci_to_col(entry, run.e) },
  }
end

-- full run under the cursor (iw-like), else nearest run forward/backward
local function seed_word_region(buf, pos)
  local p = text.to_cipos(buf, pos[1], pos[2])
  local run = text.run_at(buf, p.lnum, p.ci)
  if run then
    return run_region(buf, p.lnum, run)
  end
  local nr = text.next_run(buf, p)
  if nr then
    return run_region(buf, nr.lnum, nr)
  end
  local pr = text.prev_run(buf, p)
  if pr then
    return run_region(buf, pr.lnum, pr)
  end
  return nil
end

-- `ve`-like seed: cursor -> end of the current (or next) run
local function seed_ve_region(buf, pos)
  local p = text.to_cipos(buf, pos[1], pos[2])
  local e = text.forward_run_end(buf, p)
  if not e then
    return nil
  end
  return { s = { pos[1], pos[2] }, e = { e.lnum, text.to_col(buf, e) } }
end

-- if the region is a strict subset of a single run, return the whole run
local function run_superset(buf, region)
  if region.s[1] ~= region.e[1] then
    return nil
  end
  local entry = text.fetch_line(buf, region.s[1])
  local s_ci = text.col_to_ci(entry, region.s[2])
  local e_ci = text.col_to_ci(entry, region.e[2])
  local run = text.run_at(buf, region.s[1], s_ci)
  if not run then
    return nil
  end
  if run.s >= s_ci and run.e <= e_ci then
    return nil -- region already covers the run
  end
  if run.s > s_ci or run.e < e_ci then
    return nil -- region extends beyond the run
  end
  return run_region(buf, region.s[1], run)
end

-- first / last run of the buffer — the wrap targets of the word-mode cycle
local function first_run(buf)
  local r = text.run_at(buf, 1, 1)
  if r then
    return { lnum = 1, s = r.s, e = r.e }
  end
  return text.next_run(buf, { lnum = 1, ci = 1 })
end

local function last_run(buf)
  local n = text.line_count(buf)
  local entry = text.fetch_line(buf, n)
  local ci = #entry.chars
  if ci == 0 then
    ci = 1
  end
  local r = text.run_at(buf, n, ci)
  if r then
    return { lnum = n, s = r.s, e = r.e }
  end
  return text.prev_run(buf, { lnum = n, ci = ci })
end

-- --------------------------------------------------------- bracket scanning

local MATCH = { ['('] = ')', ['['] = ']', ['{'] = '}' }

local function find_closer_forward(buf, open_pos, budget)
  local open_char = text.char_at(buf, open_pos)
  local want = MATCH[open_char]
  if not want then
    return nil
  end
  local depth = 0
  local p = open_pos
  local steps = 0
  while p do
    steps = steps + 1
    if steps > budget then
      return nil
    end
    local c = text.char_at(buf, p)
    if c == open_char then
      depth = depth + 1
    elseif c == want then
      depth = depth - 1
      if depth == 0 then
        return p
      end
    end
    p = text.next_cipos(buf, p)
  end
  return nil
end

local function build_pair(buf, open_pos, close_pos)
  local outer = {
    s = { open_pos.lnum, text.to_col(buf, open_pos) },
    e = { close_pos.lnum, text.to_col(buf, close_pos) },
  }
  local is = text.next_cipos(buf, open_pos)
  local ie = text.prev_cipos(buf, close_pos)
  local inner = nil
  if is and ie and not text.cipos_lt(ie, is) then
    inner = { s = { is.lnum, text.to_col(buf, is) }, e = { ie.lnum, text.to_col(buf, ie) } }
  end
  local trim = inner
  if inner then
    local a = text.to_cipos(buf, inner.s[1], inner.s[2])
    local b = text.to_cipos(buf, inner.e[1], inner.e[2])
    while text.cipos_lt(a, b) do
      local c = text.char_at(buf, a)
      if c and not c:find('^%s') then
        break
      end
      local na = text.next_cipos(buf, a)
      if not na then
        break
      end
      a = na
    end
    while text.cipos_lt(a, b) do
      local c = text.char_at(buf, b)
      if c and not c:find('^%s') then
        break
      end
      local nb = text.prev_cipos(buf, b)
      if not nb then
        break
      end
      b = nb
    end
    if text.cipos_lt(a, b) then
      trim = { s = { a.lnum, text.to_col(buf, a) }, e = { b.lnum, text.to_col(buf, b) } }
    end
  end
  return { outer = outer, inner = inner, trim = trim }
end

-- innermost bracket pair strictly containing the region (no treesitter).
-- Works inside comments and parser-less buffers; the pair may share one
-- edge with the region as long as it extends past the other edge.
local function enclosing_pair(buf, region)
  local s_pos = text.to_cipos(buf, region.s[1], region.s[2])
  local e_pos = text.to_cipos(buf, region.e[1], region.e[2])
  local p = s_pos -- inclusive: an opener at region start counts
  local depth = 0
  local steps = 0
  while p do
    steps = steps + 1
    if steps > 50000 then
      return nil
    end
    local c = text.char_at(buf, p)
    if c == ')' or c == ']' or c == '}' then
      depth = depth + 1
    elseif c == '(' or c == '[' or c == '{' then
      if depth == 0 then
        local closer = find_closer_forward(buf, p, 100000)
        if closer
          and not text.cipos_lt(closer, e_pos)
          and (text.cipos_lt(p, s_pos) or text.cipos_lt(e_pos, closer))
        then
          return build_pair(buf, p, closer)
        end
      else
        depth = depth - 1
      end
    end
    p = text.prev_cipos(buf, p)
  end
  return nil
end

-- -------------------------------------------------------- one level inward

local function strip_delims(buf, region)
  local entry_s = text.fetch_line(buf, region.s[1])
  local entry_e = text.fetch_line(buf, region.e[1])
  local c1 = entry_s.chars[text.col_to_ci(entry_s, region.s[2])]
  local c2 = entry_e.chars[text.col_to_ci(entry_e, region.e[2])]
  if not c1 or not c2 then
    return nil
  end
  local matched = (ts.OPENS[c1] and ts.CLOSES[c2])
    or (ts.QUOTES[c1] and ts.QUOTES[c2] and c1 == c2)
  if not matched then
    return nil
  end
  local is = text.next_cipos(buf, text.to_cipos(buf, region.s[1], region.s[2]))
  local ie = text.prev_cipos(buf, text.to_cipos(buf, region.e[1], region.e[2]))
  if not is or not ie or text.cipos_lt(ie, is) then
    return nil
  end
  return { s = { is.lnum, text.to_col(buf, is) }, e = { ie.lnum, text.to_col(buf, ie) } }
end

local function trim_blank_edges(buf, region)
  local a = text.to_cipos(buf, region.s[1], region.s[2])
  local b = text.to_cipos(buf, region.e[1], region.e[2])
  local a0, b0 = a, b
  if not text.cipos_lt(a, b) then
    return nil
  end
  while text.cipos_lt(a, b) do
    local c = text.char_at(buf, a)
    if c and not c:find('^%s') then
      break
    end
    local na = text.next_cipos(buf, a)
    if not na then
      return nil
    end
    a = na
  end
  while text.cipos_lt(a, b) do
    local c = text.char_at(buf, b)
    if c and not c:find('^%s') then
      break
    end
    local nb = text.prev_cipos(buf, b)
    if not nb then
      return nil
    end
    b = nb
  end
  if (text.cipos_eq(a, a0) and text.cipos_eq(b, b0)) or not text.cipos_lt(a, b) then
    return nil
  end
  return { s = { a.lnum, text.to_col(buf, a) }, e = { b.lnum, text.to_col(buf, b) } }
end

local function largest_inside(buf, region)
  local parser = ts.get_parser(buf)
  if not parser then
    return nil
  end
  local node = ts.covering_node(parser, buf, region)
  if not node then
    return nil
  end
  local best, best_size = nil, -1
  local stack = { node }
  local visited = 0
  while #stack > 0 do
    local n = table.remove(stack)
    for i = 0, n:child_count() - 1 do
      local c = n:child(i)
      if c:named() then
        visited = visited + 1
        if visited > 2000 then
          break
        end
        local cr = ts.node_region(buf, c)
        if cr then
          if contains(region, cr) and strictly(region, cr) then
            local sz = size(cr)
            if sz > best_size then
              best, best_size = cr, sz
            end
          elseif overlaps(region, cr) then
            table.insert(stack, c)
          end
        end
      end
    end
  end
  return best
end

-- one level down from the current region (used when there is no history)
local function inner_region(buf, region)
  local stripped = strip_delims(buf, region)
  if stripped then
    return stripped
  end
  local inside = largest_inside(buf, region)
  if inside then
    return inside
  end
  return trim_blank_edges(buf, region)
end

-- ------------------------------------------- the <BS> candidate ladder (NER)

local MAX_CANDIDATES = 80

local function region_key(r)
  return ('%d:%d:%d:%d'):format(r.s[1], r.s[2], r.e[1], r.e[2])
end

--- All regions strictly containing `seed`, sorted by size ascending
--- (nvim-expand-region order). Sources:
---   * the completed word, when the seed covers part of one
---   * treesitter ancestors, each with the span between its delimiters
---     (and the blank-trimmed span) as separate rungs
---   * enclosing bracket pairs found by text scan — inner trimmed,
---     inner raw, then the pair with its delimiters — chained outward
---   * the trimmed and full line (single-line seeds)
---   * the paragraph (only without a treesitter parser)
--- The tree root and the whole buffer are never rungs.
local function compute_outward_candidates(buf, seed)
  local list = {}
  local seen = {}

  local function add(r)
    if not r then
      return
    end
    if not strictly(r, seed) then
      return
    end
    local k = region_key(r)
    if seen[k] then
      return
    end
    seen[k] = true
    list[#list + 1] = r
  end

  -- 1. complete a partially selected word
  add(run_superset(buf, seed))

  -- 2. treesitter ancestors
  local parser = ts.get_parser(buf)
  if parser then
    local node = ts.covering_node(parser, buf, seed)
    local steps = 0
    while node and steps < 40 do
      steps = steps + 1
      if node:parent() then -- the tree root is never a rung
        local nr = ts.node_region(buf, node)
        if nr then
          local inner = ts.delimited_region(buf, node)
          if inner and strictly(inner, seed) and strictly(nr, inner) then
            local trimmed = trim_blank_edges(buf, inner)
            if trimmed and strictly(trimmed, seed) and strictly(inner, trimmed) then
              add(trimmed)
            end
            add(inner)
          end
          add(nr)
        end
      end
      node = node:parent()
    end
  end

  -- 3. bracket pairs by text scan (works in comments and plain buffers)
  local pair = enclosing_pair(buf, seed)
  local hops = 0
  while pair and hops < 10 do
    hops = hops + 1
    if pair.trim then
      add(pair.trim)
    end
    if pair.inner then
      add(pair.inner)
    end
    add(pair.outer)
    local outside = enclosing_pair(buf, pair.outer)
    if not outside or not strictly(outside.outer, pair.outer) then
      break
    end
    pair = outside
  end

  -- 4. line levels (single-line seeds)
  if seed.s[1] == seed.e[1] then
    local l = seed.s[1]
    local entry = text.fetch_line(buf, l)
    local first, last
    for i, c in ipairs(entry.chars) do
      if not c:find('^%s') then
        if not first then
          first = i
        end
        last = i
      end
    end
    if first then
      add({
        s = { l, text.ci_to_col(entry, first) },
        e = { l, text.ci_to_col(entry, last) },
      })
    end
    add({ s = { l, 1 }, e = { l, text.line_end_col(buf, l) } })
  end

  -- 5. paragraph — the ceiling of the no-parser ladder
  if not parser then
    add(text.paragraph_range(buf, seed))
  end

  -- nvim-expand-region sort: size ascending; on ties the later start
  -- first, then the earlier end.
  table.sort(list, function(a, b)
    local sa, sb = size(a), size(b)
    if sa ~= sb then
      return sa < sb
    end
    if a.s[1] ~= b.s[1] or a.s[2] ~= b.s[2] then
      return pos_lt(b.s, a.s)
    end
    return pos_lt(a.e, b.e)
  end)

  while #list > MAX_CANDIDATES do
    table.remove(list)
  end
  return list
end

-- ------------------------------------------------ word-wise edge extension

local function extend_region(buf, cur, dir)
  if dir == 'right' then
    local e = text.forward_run_end(buf, text.to_cipos(buf, cur.e[1], cur.e[2]))
    if e then
      local ne = { e.lnum, text.to_col(buf, e) }
      if pos_lt(cur.e, ne) then
        return { s = cur.s, e = ne }
      end
    end
  elseif dir == 'left' then
    local s = text.backward_run_start(buf, text.to_cipos(buf, cur.s[1], cur.s[2]))
    if s then
      local ns = { s.lnum, text.to_col(buf, s) }
      if pos_lt(ns, cur.s) then
        return { s = ns, e = cur.e }
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------- API

-- <BS>: expand-region — walk up the candidate ladder, one rung per press.
-- First press from Normal mode grips the word under the cursor.
function M.expand_up()
  local buf = vim.api.nvim_get_current_buf()
  local cur = current_region(buf)
  if not cur then
    local seed = seed_word_region(buf, cursor_pos())
    if seed then
      commit(nil, seed, nil)
      state.ladder_set(seed, nil)
    end
    return
  end

  -- keep walking the recorded ladder while the selection is on it;
  -- recompute (from the live selection) whenever it left the ladder
  local ladder = state.ladder_get()
  local positioned = ladder ~= nil and ladder.candidates ~= nil
    and (
      (ladder.index == 0 and state.regions_equal(cur, ladder.seed))
      or (ladder.index > 0 and ladder.candidates[ladder.index] ~= nil
        and state.regions_equal(cur, ladder.candidates[ladder.index]))
    )
  if not positioned then
    ladder = state.ladder_set(cur, compute_outward_candidates(buf, cur))
  end

  if ladder.index >= #ladder.candidates then
    return -- at the top of the ladder: stay put
  end
  ladder.index = ladder.index + 1
  commit(cur, ladder.candidates[ladder.index], nil)
end

-- <M-p> / <M-BS>: undo the last selection change; when the selection did
-- not come from this plugin (a manual selection), descend one structural
-- level inward instead. At the very bottom, leave Visual mode.
function M.shrink()
  local buf = vim.api.nvim_get_current_buf()
  local cur = current_region(buf)
  if not cur then
    return
  end
  local what, region = state.pop(cur)
  if what == 'select' then
    set_visual(buf, region)
    return
  end
  if what == 'exit' then
    feed(ESC)
    return
  end
  -- 'descend' (continue an inward walk) or 'none' (manual selection):
  -- move one structural level inward, never ping-ponging back up.
  local inner = inner_region(buf, cur)
  if inner then
    state.push_descent(cur, inner)
    set_visual(buf, inner)
  end
end

-- <M-f>: extend the selection right, word by word (like e/w chaining)
function M.expand_right()
  local buf = vim.api.nvim_get_current_buf()
  local cur = current_region(buf)
  if not cur then
    local seed = seed_ve_region(buf, cursor_pos())
    if seed then
      commit(nil, seed, 'right')
    end
    return
  end
  local r = extend_region(buf, cur, 'right')
  if r then
    commit(cur, r, 'right')
  end
end

-- <M-b>: extend the selection left, word by word (like b)
function M.expand_left()
  local buf = vim.api.nvim_get_current_buf()
  local cur = current_region(buf)
  if not cur then
    local pos = cursor_pos()
    local s = text.backward_run_start(buf, text.to_cipos(buf, pos[1], pos[2]))
    if not s then
      return
    end
    local ns = { s.lnum, text.to_col(buf, s) }
    if not pos_lt(ns, pos) then
      return
    end
    commit(nil, { s = ns, e = pos }, 'left')
    return
  end
  local r = extend_region(buf, cur, 'left')
  if r then
    commit(cur, r, 'left')
  end
end

-- <M-o>: push the LEFT edge of the selection out by ONE CHARACTER
-- (the v_h equivalent for the left side; <M-b> is the word-wise one).
-- Stays inside the line, like h in Visual mode.
function M.left_out()
  local buf = vim.api.nvim_get_current_buf()
  local cur = current_region(buf)
  if not cur then
    -- from Normal: select the cursor char together with the one before it
    local pos = cursor_pos()
    local p = text.to_cipos(buf, pos[1], pos[2])
    local prev = text.prev_cipos(buf, p)
    if not prev or prev.lnum < pos[1] then
      return -- column 1: nothing to the left on this line
    end
    commit(nil, { s = { prev.lnum, text.to_col(buf, prev) }, e = pos }, 'left')
    return
  end
  local p = text.to_cipos(buf, cur.s[1], cur.s[2])
  local prev = text.prev_cipos(buf, p)
  if not prev or prev.lnum < cur.s[1] then
    return -- left edge at column 1: stay (h does not cross lines)
  end
  commit(cur, { s = { prev.lnum, text.to_col(buf, prev) }, e = cur.e }, 'left')
end

-- <M-u>: pull the LEFT edge of the selection in by ONE CHARACTER
-- (the v_l equivalent for the left side), keeping at least one character.
function M.left_in()
  local buf = vim.api.nvim_get_current_buf()
  local cur = current_region(buf)
  if not cur then
    return
  end
  local p = text.to_cipos(buf, cur.s[1], cur.s[2])
  local nxt = text.next_cipos(buf, p)
  if not nxt then
    return
  end
  local ns = { nxt.lnum, text.to_col(buf, nxt) }
  if pos_lt(cur.e, ns) then
    return -- would empty the selection
  end
  commit(cur, { s = ns, e = cur.e }, nil)
end

-- <M-w>: `viw` at the edge where the last lateral motion happened —
-- the right edge after <M-f> (where the cursor actually sits), the left
-- edge after <M-b> (where the cursor would sit if it had tracked the
-- motion, like a native `vb`).
--
-- * the edge char is inside a word run -> select that whole run
--   (completing a partially covered word, or narrowing a bigger
--   selection down to its edge word)
-- * that run already IS the whole selection -> advance one word in the
--   direction (viw where `w`/`b` from the cursor would land)
-- * the edge sits on blanks -> the next/previous run in the direction
function M.hop_word()
  local buf = vim.api.nvim_get_current_buf()
  local cur = current_region(buf)
  if not cur then
    local seed = seed_word_region(buf, cursor_pos())
    if seed then
      commit(nil, seed, nil)
    end
    return
  end
  local dir = state.get().last_dir or 'right'
  local edge = dir == 'left'
    and text.to_cipos(buf, cur.s[1], cur.s[2])
    or text.to_cipos(buf, cur.e[1], cur.e[2])
  local run = text.run_at(buf, edge.lnum, edge.ci)
  if run then
    local rr = run_region(buf, edge.lnum, run)
    if rr and not state.regions_equal(rr, cur) then
      commit(cur, rr, dir) -- viw on the edge char
      return
    end
    -- the edge run is already selected: advance past it
    edge = { lnum = edge.lnum, ci = dir == 'left' and run.s or run.e }
  end
  local target
  if dir == 'left' then
    local pr = text.prev_run(buf, edge)
    if pr then
      target = run_region(buf, pr.lnum, pr)
    end
  else
    local nr = text.next_run(buf, edge)
    if nr then
      target = run_region(buf, nr.lnum, nr)
    end
  end
  if target then
    commit(cur, target, dir)
  end
end

-- cache for the depth cycle: recomputed only when the buffer or the
-- cycling depth changes (edits bump the changedtick and invalidate it)
local depth_cache = { buf = nil, tick = -1, depth = nil, items = nil }

-- <M-n> / <M-p>: cycle the selection through the flat sequence of
-- same-level nodes — siblings AND the nodes continuing in the neighboring
-- subtrees. In
--   highlight = { enable = true, use_languagetree = true }
-- starting from the key `enable` this walks enable -> true ->
-- use_languagetree -> true -> (wraps). At the field level it walks the
-- fields. A pure lateral move (the selection is replaced, never grown)
-- that wraps around; unlike gl/gh it never climbs.
function M.cycle_sibling(dir)
  local buf = vim.api.nvim_get_current_buf()
  local cur = current_region(buf)
  local anchor = cur
  if not anchor then
    local c = cursor_pos()
    anchor = { s = { c[1], c[2] }, e = { c[1], c[2] } }
  end

  local parser = ts.get_parser(buf)
  if parser then
    local node = ts.covering_node(parser, buf, anchor)
    if not node or not node:parent() then
      return
    end
    local depth, root = ts.node_depth(node)
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local items
    if depth_cache.buf == buf and depth_cache.tick == tick and depth_cache.depth == depth then
      items = depth_cache.items
    else
      items = ts.depth_nodes(root, depth)
      depth_cache = { buf = buf, tick = tick, depth = depth, items = items }
    end
    if #items < 2 then
      return
    end
    -- locate the current node in the flat sequence
    local idx
    for i, it in ipairs(items) do
      if it == node then
        idx = i
        break
      end
    end
    if not idx then
      local cur_r = ts.node_region(buf, node)
      if cur_r then
        for i, it in ipairs(items) do
          local ir = ts.node_region(buf, it)
          if ir and state.regions_equal(ir, cur_r) then
            idx = i
            break
          end
        end
      end
    end
    if not idx then
      return
    end
    local target_node
    if dir > 0 then
      target_node = items[idx + 1] or items[1] -- wrap around
    else
      target_node = items[idx - 1] or items[#items]
    end
    local tr = ts.node_region(buf, target_node)
    if tr and not state.regions_equal(tr, cur) then
      commit(cur, tr, nil)
    end
    return
  end

  -- word mode: cycle the runs of the buffer, wrapping at the ends
  local from
  if cur then
    from = dir > 0
      and text.to_cipos(buf, cur.e[1], cur.e[2])
      or text.to_cipos(buf, cur.s[1], cur.s[2])
  else
    local c = cursor_pos()
    from = text.to_cipos(buf, c[1], c[2])
  end
  local anchor_run = text.run_at(buf, from.lnum, from.ci)
  if anchor_run then
    from = { lnum = from.lnum, ci = dir > 0 and anchor_run.e or anchor_run.s }
  end
  local run
  if dir > 0 then
    run = text.next_run(buf, from) or first_run(buf)
  else
    run = text.prev_run(buf, from) or last_run(buf)
  end
  if run then
    commit(cur, run_region(buf, run.lnum, run), nil)
  end
end

-- gl / gh: select the next / previous sibling (node, or word without a
-- parser). Climbs one level when the sibling chain is exhausted, and
-- stops at the tree root.
function M.sibling(dir)
  local buf = vim.api.nvim_get_current_buf()
  local cur = current_region(buf)
  local anchor = cur
  if not anchor then
    local c = cursor_pos()
    anchor = { s = { c[1], c[2] }, e = { c[1], c[2] } }
  end

  local parser = ts.get_parser(buf)
  if parser then
    local node = ts.covering_node(parser, buf, anchor)
    while node do
      local sib = ts.named_sibling(node, dir)
      if sib then
        local sr = ts.node_region(buf, sib)
        if sr then
          commit(cur, sr, nil)
          return
        end
      end
      if not node:parent() then
        return -- the root has no siblings
      end
      node = node:parent()
    end
    return
  end

  -- word fallback: jump to the next / previous run (skipping the run the
  -- anchor is inside, so a press from Normal mode slides OFF the word
  -- under the cursor)
  local from
  if cur then
    from = dir > 0
      and text.to_cipos(buf, cur.e[1], cur.e[2])
      or text.to_cipos(buf, cur.s[1], cur.s[2])
  else
    local c = cursor_pos()
    from = text.to_cipos(buf, c[1], c[2])
  end
  local anchor_run = text.run_at(buf, from.lnum, from.ci)
  if anchor_run then
    from = { lnum = from.lnum, ci = dir > 0 and anchor_run.e or anchor_run.s }
  end
  local run
  if dir > 0 then
    run = text.next_run(buf, from)
  else
    run = text.prev_run(buf, from)
  end
  if run then
    commit(cur, run_region(buf, run.lnum, run), nil)
  end
end

-- gj / gk: select the next / previous scope (function/if/loop/... or paragraph)
local function scope_sibling(node, dir)
  local sib = node
  local steps = 0
  while true do
    if dir > 0 then
      sib = sib:next_sibling()
    else
      sib = sib:prev_sibling()
    end
    if not sib or steps > 5000 then
      return nil
    end
    steps = steps + 1
    if sib:named() and ts.is_scope_type(sib:type()) then
      return sib
    end
  end
end

function M.scope(dir)
  local buf = vim.api.nvim_get_current_buf()
  local cur = current_region(buf)
  local anchor = cur
  if not anchor then
    local c = cursor_pos()
    anchor = { s = { c[1], c[2] }, e = { c[1], c[2] } }
  end

  local parser = ts.get_parser(buf)
  if parser then
    local node = ts.covering_node(parser, buf, anchor)
    local scope_node = ts.enclosing_scope(node)
    while scope_node do
      local target = scope_sibling(scope_node, dir)
      if target then
        local tr = ts.node_region(buf, target)
        if tr then
          commit(cur, tr, nil)
          return
        end
      end
      scope_node = scope_node:parent()
    end
  end

  -- fallback: next / previous paragraph
  local base = cur
  if not base then
    local c = cursor_pos()
    base = { s = { c[1], c[2] }, e = { c[1], c[2] } }
  end
  local para = text.next_paragraph(buf, base, dir)
  if para then
    commit(cur, para, nil)
  end
end

return M
