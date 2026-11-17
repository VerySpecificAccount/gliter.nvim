--- gliter.textobj — targets.vim's quotes and separators.
---
--- QUOTE objects — ' " ` — that work ON and AROUND their delimiters
--- and SEEK like targets.vim when the cursor is outside every pair:
---   * on or inside a pair: Vim's own pairing, replicated from
---     Neovim's textobject.c — parity pairing when the cursor is ON a
---     quote, the pair around it when it is between one pair's quotes;
---   * `a"` includes the whitespace after the closing quote (or before
---     the opening one), like the built-in — on every variant;
---   * backslash-escaped quotes follow 'quoteescape', like the built-in;
---   * anywhere else — in the GAP between two strings, before the
---     first pair, after the last, on a line with no pairs — gliter
---     seeks, in this order (the order targets.vim itself scores):
---       1. the NEXT pair on the cursor's line (a count skips, like
---          `in"`) — the gap between two strings behaves exactly like
---          `in"` does;
---       2. the LAST pair before the cursor, still on the cursor's own
---          line (targets.vim's 'll' — back to the pair you just
---          passed; this is where a cursor standing after a quote
---          goes);
---       3. the NEAREST pair on another line within `seek_lines`,
---          distance in lines first, characters second; at a tie the
---          pair BEFORE the cursor wins.
---   * in"/il" (and an"/al"/In"/Il") keep targets.vim's forced
---     directions: the next/last pair strictly after/before the
---     cursor, this line first, then across lines, count skipping
---     pairs. From on or inside a pair the pair you are on never
---     counts as next or last — targets.vim's smart quote skipping.
---   Triple-quoted strings (``` fences, '''/""" docstrings) are NOT
---   detected — a run of quotes is just that many single quotes, the
---   way Vim's own objects read it; nvim-various-textobjs covers
---   those.
---   i" a" I"    inside / around / inside-trimmed
---   in" an" In" force the NEXT pair after the cursor (a count skips)
---   il" al" Il" force the LAST pair before it (a count skips)
---
--- SEPARATOR objects — , . ; : + - = ~ _ * # / \ | & $ by default — the
--- region between the nearest separator before the cursor and the nearest
--- one after it, across line boundaries when the list runs over them.
---
--- Everything behaves like Vim's built-ins at the edges:
---   * `ci"` on `""` inserts BETWEEN the quotes (the one-character-space
---     trick targets.vim and mini.ai use), `di"` deletes nothing, `yi"`
---     yanks nothing;
---   * `vi"` on `""` leaves exactly the selection Vim's own `vi"` leaves
---     (cursor on the opening quote, anchor on the closing one);
---   * no pair anywhere: the pending operator is CANCELLED, like Vim's
---     E348 — nothing is changed, nothing is inserted;
---   * `ci"new<Esc>` then `.` repeats, and the cursor column rules are
---     Vim's (selection ends on the closing delimiter).
---
--- Mappings created after setup() win in Vim, so the keys are guarded:
--- re-asserted once every plugin has loaded (VimEnter), audited three
--- seconds in, and audit-first on BufEnter/FileType/UIEnter/InsertEnter
--- — while the keys are gliter's nothing at all happens; a guard that
--- finds one gone maps every key again (the last mapping created wins
--- in Vim) and deletes a buffer-local thief first. `reclaim = false`
--- opts out of every guard; :GliterTextobjClaim re-asserts on demand
--- and :GliterTextobjCheck names who owns a key.
---
--- HOW THE MAPPINGS ARE MADE (every idiom verified against real nvims
--- 0.10 and 0.12):
---   * the OPERATOR-pending side is an <expr> mapping returning one of
---     two strings: '<Esc>' — which cancels the pending operator when
---     there is nothing to select — or '<Plug>(gliter-textobj)', a
---     plain mapping that performs the selection (cursor to the start,
---     `normal! v`, cursor to the end; for an empty region and the
---     operators that can act on one — c and d — one space is inserted
---     and selected, so the operator eats the space, not the quotes);
---   * the VISUAL side is a plain Lua mapping: force charwise, cursor to
---     the start, `o` (swap corners), cursor to the end — the selection
---     is exactly the region whichever corner the user started from.
---
--- USAGE (from your init.lua)
---   require('gliter.textobj').setup()                -- defaults
---   require('gliter.textobj').setup { seek_lines = 0 } -- current line only
---   require('gliter.textobj').setup { reclaim = false } -- keep whoever mapped later
---   require('gliter').setup { textobj = true }        -- through gliter

local M = {}

M.did_setup = false

local defaults = {
  -- the quote characters that get i/a/I objects (with in/an/il/al when
  -- seek is on); set the list to change which are mapped
  quotes = { '"', "'", '`' },
  -- targets.vim's default separator set; each gets i/a/I objects
  separators = { ',', '.', ';', ':', '+', '-', '=', '~', '_', '*', '#', '/', '\\', '|', '&', '$' },
  seek = true, -- quotes work from on/around a pair, and look
  -- next/last when the cursor is outside every pair (in"/an"/il"/al")
  seek_lines = 200, -- how many lines each way a quote seek looks
  multiline_sep = 50, -- how many lines each way a separator object
  -- searches for its delimiters
  reclaim = true, -- re-assert the mappings on VimEnter, after every
  -- plugin has loaded — mappings created later win in Vim, so this
  -- takes gliter's keys back from whatever mapped over them
}
local cfg = vim.deepcopy(defaults)

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'gliter.textobj' })
end

local function say_later(msg)
  -- never from inside the expression itself: the message area belongs to
  -- the mapping's caller
  vim.schedule(function()
    notify(msg)
  end)
end

---------------------------------------------------------------- regions --

--- The cursor as (row, 1-based byte col) — nil (with a reason) when the
--- editor will not give one up: exotic call contexts must not turn into
--- arithmetic-on-nil.
---@return integer? row
---@return integer? col
---@return string? why
local function here()
  local ok, pos = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok or type(pos) ~= 'table' or type(pos[1]) ~= 'number' or type(pos[2]) ~= 'number' then
    return nil, nil, 'no cursor to work from here'
  end
  if pos[1] < 1 or pos[2] < 0 then
    return nil, nil, 'no cursor to work from here'
  end
  return pos[1], pos[2] + 1, nil
end

--- 'quoteescape' as a string of escape bytes (never empty).
local function qe()
  local v = vim.bo.quoteescape
  if type(v) ~= 'string' or v == '' then
    return '\\'
  end
  return v
end

--- One line's line as it is in the buffer.
local function line_at(l)
  return vim.api.nvim_buf_get_lines(0, l - 1, l, false)[1] or ''
end

------------------------------------------------------------- vim's own --
-- Neovim's textobject.c, translated: the pairing the built-in
-- i"/a" do on a line, so that on or inside a string gliter picks the
-- very same pair the built-in picks. quote_pairs below IS the
-- algorithm: quotes pair up from the line start (parity), a quote
-- escaped by 'quoteescape' is content, and a quote with no partner
-- opens nothing. The pair the built-in selects from `col` is then:
--   * the pair whose quotes contain `col` — on either quote (parity
--     decides which pair a quote belongs to, exactly the built-in's
--     loop over find_next_quote pairs) or strictly between them;
-- everywhere else (the gap between two pairs, before the first, after
-- the last, no pairs at all) the built-in either pairs the gap between
-- two adjacent quotes as a pseudo-string or FAILS — gliter does neither:
-- it seeks (next pair on the line, then last, then nearest), the
-- order targets.vim itself scores.

--- The `q` quote bytes of one line, left to right (1-based). A quote
--- escaped by 'quoteescape' is content, not a delimiter.
---@param line string
---@param q string
---@return table
local function quote_cols(line, q)
  local esc = qe()
  local out = {}
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if esc:find(c, 1, true) then
      i = i + 2 -- escaped chars stay inside the string
    elseif c == q then
      out[#out + 1] = i
      i = i + 1
    else
      i = i + 1
    end
  end
  return out
end

--- The quote pairs of one line, as {s = open col, e = close col}
--- (1-based bytes), paired in parity order — Vim's own pairing. A
--- quote with no partner opens nothing.
---@param line string
---@param q string
---@return table[]
local function quote_pairs(line, q)
  local out = {}
  local open_at = nil
  for _, p in ipairs(quote_cols(line, q)) do
    if open_at then
      out[#out + 1] = { s = open_at, e = p }
      open_at = nil
    else
      open_at = p
    end
  end
  return out
end

--- The pair a forced direction picks from ONE line's pairs: 'around' the
--- cursor (on or inside a pair), the 'next' one starting after it, or
--- the 'last' one ending before it; `count` skips that many. nil when
--- there is none.
---@param pairs table[]
---@param col integer the cursor's 1-based byte column
---@param where 'around'|'next'|'last'
---@param count integer
---@return table?
local function seek_pair(pairs, col, where, count)
  if where == 'around' then
    for _, p in ipairs(pairs) do
      if col >= p.s and col <= p.e then
        return p
      end
    end
    return nil
  end
  if where == 'next' then
    local n = 0
    for _, p in ipairs(pairs) do
      if p.s > col then
        n = n + 1
        if n >= count then
          return p
        end
      end
    end
    return nil
  end
  local n = 0
  for i = #pairs, 1, -1 do
    if pairs[i].e < col then
      n = n + 1
      if n >= count then
        return pairs[i]
      end
    end
  end
  return nil
end

------------------------------------------------------------- all pairs --
-- Every same-line pair in the buffer, in document order — what the
-- forced directions walk, so their count keeps accumulating across
-- lines. Cached per buffer + changedtick: an edit invalidates, a
-- scroll or a repeat does not.

local all_cache = {} -- [buf] = { tick, q, pairs }

--- EVERY same-line pair in document order, for the forced directions
--- and their counts.
---@param q string
---@return table[] pairs {sl, sc, el, ec}
local function all_pairs_buf(q)
  local buf = vim.api.nvim_get_current_buf()
  local tick = vim.b[buf].changedtick or 0
  local c = all_cache[buf]
  if c and c.tick == tick and c.q == q then
    return c.pairs
  end
  local total = vim.api.nvim_buf_line_count(0)
  local lines = vim.api.nvim_buf_get_lines(0, 0, total, false)
  local pairs = {}
  for r, line in ipairs(lines) do
    if line:find(q, 1, true) then
      for _, p in ipairs(quote_pairs(line, q)) do
        pairs[#pairs + 1] = { sl = r, sc = p.s, el = r, ec = p.e }
      end
    end
  end
  all_cache = { [buf] = { tick = tick, q = q, pairs = pairs } }
  return pairs
end

------------------------------------------------------------- the objects --

-- The mapped objects, by index. The operator-pending side is an <expr>
-- mapping (it must be able to say '<Esc>'), and expression mappings
-- cannot run :normal — so the expr side computes the region and returns
-- '<Plug>(gliter-textobj-N)', a PLAIN per-object mapping (side effects
-- allowed) that selects the region — computing it AGAIN, so that a
-- dot-repeat, which replays the plug keys directly, follows the cursor
-- instead of a stale stash.
local objects = {}

--- A found region {sl, sc, el, ec} turned into the region of kind
--- 'i'/'a'/'I': between the delimiters, the delimiters plus Vim's
--- whitespace rule, or the trimmed inside — whitespace stripped.
---@param reg table
---@param kind 'i'|'a'|'I'
---@return integer sl
---@return integer sc
---@return integer el
---@return integer ec
local function finish_region(reg, kind)
  local sl, sc, el, ec = reg.sl, reg.sc, reg.el, reg.ec
  if kind == 'a' then
    -- the built-in's a" rule, on every variant: the quotes plus every
    -- space/tab after the closing quote, or before the opening one when
    -- there is none after
    local tclose = line_at(el)
    if tclose:sub(ec + 1, ec + 1):find('^[ \t]') then
      while ec < #tclose and tclose:sub(ec + 1, ec + 1):find('^[ \t]') do
        ec = ec + 1
      end
    else
      local topen = line_at(sl)
      while sc > 1 and topen:sub(sc - 1, sc - 1):find('^[ \t]') do
        sc = sc - 1
      end
    end
  else
    sc, ec = sc + 1, ec - 1
    if kind == 'I' then
      -- the spaces/tabs around the content, stripped
      local l = line_at(sl)
      while sc <= ec and l:sub(sc, sc):find('^%s') do
        sc = sc + 1
      end
      local l2 = line_at(el)
      while ec >= sc and l2:sub(ec, ec):find('^%s') do
        ec = ec - 1
      end
    end
  end
  return sl, sc, el, ec
end

--- One separator region: the region between the nearest `sep` before the
--- cursor and the nearest one after it — on this line or up to
--- multiline_sep lines away — raw between the delimiters for 'i',
--- whitespace-trimmed for 'I', delimiters included for 'a'. nil (with a
--- reason) when a side is missing.
---@param sep string
---@param kind 'i'|'a'|'I'
---@return integer? sl
---@return integer? sc
---@return integer? el
---@return integer? ec
---@return string? why
local function separator_region(sep, kind)
  local row, col = here()
  if not row then
    return nil, nil, nil, nil, col
  end
  local total = vim.api.nvim_buf_line_count(0)
  local span = math.max(0, tonumber(cfg.multiline_sep) or 0)
  local from = math.max(1, row - span)
  local to = math.min(total, row + span)
  local lines = vim.api.nvim_buf_get_lines(0, from - 1, to, false)

  -- a flat string over the slice (a separator never matches across
  -- lines: the seams are \n), with every line's start offset recorded
  local offsets, parts, off = {}, {}, 0
  for i, l in ipairs(lines) do
    offsets[i] = off + 1
    parts[#parts + 1] = l
    parts[#parts + 1] = '\n'
    off = off + #l + 1
  end
  local flat = table.concat(parts)
  local cur = offsets[row - from + 1] + col - 1 -- 1-based byte of the cursor

  local bs, as = nil, nil
  for i = cur, 1, -1 do
    if flat:sub(i, i) == sep then
      bs = i
      break
    end
  end
  for i = cur + 1, #flat do
    if flat:sub(i, i) == sep then
      as = i
      break
    end
  end
  if not bs or not as then
    local shown = sep == '\\' and '\\' or sep
    return nil, nil, nil, nil, ('no %s before and after the cursor'):format(shown)
  end

  local s, e = bs, as
  if kind ~= 'a' then
    -- 'i': the raw content between the delimiters, nothing trimmed
    -- 'I': the content with leading/trailing whitespace (space, tab,
    -- newline) stripped
    s, e = bs + 1, as - 1
    if kind == 'I' then
      while s <= e and (flat:sub(s, s) == ' ' or flat:sub(s, s) == '\t' or flat:sub(s, s) == '\n') do
        s = s + 1
      end
      while e >= s and (flat:sub(e, e) == ' ' or flat:sub(e, e) == '\t' or flat:sub(e, e) == '\n') do
        e = e - 1
      end
    end
  end
  -- `,,` (or all-whitespace content for 'I'): s ends up past e, which is
  -- the empty region sc == ec + 1 — the caller's empty handling applies
  -- (c and d get the space trick, visual gets Vim's own selection)

  -- flat offsets back to (line, column)
  local function at(off)
    local idx = 1
    while idx < #offsets and offsets[idx + 1] <= off do
      idx = idx + 1
    end
    if flat:sub(off, off) == '\n' then
      return nil
    end
    return from + idx - 1, off - offsets[idx] + 1
  end
  local sl, sc = at(s)
  local el, ec = at(e)
  if not (sl and el) then
    return nil, nil, nil, nil, 'the region landed on a line seam'
  end
  return sl, sc, el, ec
end

--- Compute the region of object `i`: kind 'i' (inside), 'a' (around) or
--- 'I' (inside, whitespace trimmed). Quotes seek across lines;
--- separators already span them.
---@param i integer
---@return integer? sl
---@return integer? sc
---@return integer? el
---@return integer? ec
---@return string? why
local function region_of(i)
  local o = objects[i]
  if not o then
    return nil, nil, nil, nil, 'no such object'
  end
  if o.t == 'quote' then
    local row, col = here()
    if not row then
      return nil, nil, nil, nil, col
    end
    local total = vim.api.nvim_buf_line_count(0)
    local span = math.max(0, tonumber(cfg.seek_lines) or 0)
    local count = math.max(1, vim.v.count1 or 1)
    local where = o.w or 'around'
    local line = vim.api.nvim_get_current_line() or ''
    local function pairs_at(l)
      return quote_pairs(line_at(l), o.c)
    end

    if where == 'around' then
      -- 1. the pair the cursor is ON or INSIDE — Vim's own pairing:
      -- quote_pairs pairs quotes from the line start, so a cursor on a
      -- quote gets the pair parity gives it, and one between a pair's
      -- quotes gets that pair
      local ps = quote_pairs(line, o.c)
      for _, p in ipairs(ps) do
        if p.s <= col and col <= p.e then
          return finish_region({ sl = row, sc = p.s, el = row, ec = p.e }, o.k)
        end
      end

      -- 2. the cursor is OUTSIDE every pair: the NEXT pair on this
      -- line first (the gap between two strings takes the next STRING,
      -- the way `in"` does and the built-in does not; a count skips,
      -- like on the forced variants)
      local p = seek_pair(ps, col, 'next', count)
      if not p then
        -- 3. then the LAST pair before the cursor, still on this line —
        -- targets.vim's 'll': back to the pair you just passed, which
        -- is where a cursor standing after a quote goes
        p = seek_pair(ps, col, 'last', count)
      end
      if p then
        return finish_region({ sl = row, sc = p.s, el = row, ec = p.e }, o.k)
      end
      if not cfg.seek then
        return nil, nil, nil, nil, ('no %s pair around, before or after the cursor on this line'):format(o.c)
      end

      -- 4. the NEAREST pair on another line — distance in lines
      -- first, and at a tie the pair BEFORE the cursor ("back to the
      -- quotes you passed")
      local up, up_d = nil, nil
      for l = row - 1, math.max(1, row - span), -1 do
        local ps2 = pairs_at(l)
        local p2 = ps2[#ps2]
        if p2 then
          up = { sl = l, sc = p2.s, el = l, ec = p2.e }
          up_d = row - l
          break -- the nearest line above that has a pair, period
        end
      end
      local down, down_d = nil, nil
      for l = row + 1, math.min(total, row + span) do
        local p2 = pairs_at(l)[1]
        if p2 then
          down = { sl = l, sc = p2.s, el = l, ec = p2.e }
          down_d = l - row
          break
        end
      end
      local pick = nil
      if up and down then
        -- strictly nearer below wins; at a tie the pair above (the one
        -- BEFORE the cursor) stays
        pick = down_d < up_d and down or up
      elseif down then
        pick = down
      elseif up then
        pick = up
      end
      if pick then
        return finish_region(pick, o.k)
      end
      return nil, nil, nil, nil, ('no %s pair within %d lines of the cursor'):format(o.c, span)
    end

    -- forced next/last: targets.vim's skip-countable seeking — every
    -- pair in the buffer in document order, so the count KEEPS
    -- ACCUMULATING across lines (`3in"` with two pairs left on the
    -- line and one below finds the one below). A pair containing the
    -- cursor never counts — targets.vim's smart quote skipping.
    local allp = all_pairs_buf(o.c)
    if where == 'next' then
      local n = 0
      for _, p in ipairs(allp) do
        if p.sl > row + span then
          break -- document order: everything after is out of range too
        end
        if p.sl > row or (p.sl == row and p.sc > col) then
          n = n + 1
          if n >= count then
            return finish_region(p, o.k)
          end
        end
      end
      return nil, nil, nil, nil, ('no %s pair after the cursor'):format(o.c)
    end
    local n = 0
    for ii = #allp, 1, -1 do
      local p = allp[ii]
      if p.el < row - span then
        break -- document order: everything earlier ends even earlier
      elseif p.el < row or (p.el == row and p.ec < col) then
        n = n + 1
        if n >= count then
          return finish_region(p, o.k)
        end
      end
    end
    return nil, nil, nil, nil, ('no %s pair before the cursor'):format(o.c)
  end
  return separator_region(o.c, o.k)
end

------------------------------------------------------------ selection --

--- The ANCHOR of a region's start (set in normal mode): the byte
--- before the region's first byte, 0-based.
local function start_corner(sl, sc)
  return sl, sc - 1
end

--- The MOVING corner of a region's end (set in visual mode): the
--- region's last byte, 0-based.
local function end_corner(el, ec)
  return el, ec - 1
end

--- The plain per-object <Plug> mapping the operator-pending expr
--- returns to — and the one a dot-repeat replays directly (the redo
--- buffer holds the plug keys, NOT the expression), so it RECOMPUTES
--- the region from the current cursor instead of trusting a stash.
---@param i integer
local function plug_select(i)
  local sl, sc, el, ec = region_of(i)
  if not sl then
    -- the buffer changed under a dot-repeat: cancel the pending
    -- operator (the one way a plain mapping can: an immediately
    -- processed <Esc>)
    return vim.api.nvim_feedkeys('\27', 'nx', false)
  end
  if sl == el and sc > ec then
    -- targets.vim's (and mini.ai's) way to let `ci"` on `""` insert
    -- between the quotes: put one space there, select it, and let the
    -- still-pending operator eat the space.
    --
    -- We must NOT send <Esc> here — that would cancel the pending
    -- operator before it ever acts. Instead: insert the space directly
    -- with the API (no mode change, no key events), then establish the
    -- visual selection the way the normal path does, so the pending
    -- operator (c or d) sees exactly one character to act on.
    local ei = vim.o.eventignore
    vim.o.eventignore = 'all'
    -- sc-1 is the 0-based byte of the closing quote; the space goes there
    vim.api.nvim_buf_set_text(0, sl - 1, sc - 1, sl - 1, sc - 1, { ' ' })
    -- cursor to the space (0-based: sc-1), then v-select it
    vim.api.nvim_win_set_cursor(0, { sl, sc - 1 })
    vim.o.eventignore = ei
    pcall(vim.cmd, 'normal! zv')
    vim.cmd('normal! v')
    -- the space occupies exactly one byte; the selection ends on it
    vim.api.nvim_win_set_cursor(0, { sl, sc - 1 })
    pcall(vim.cmd, 'normal! zv')
    return
  end
  local ar, ac = start_corner(sl, sc)
  vim.api.nvim_win_set_cursor(0, { ar, ac })
  pcall(vim.cmd, 'normal! zv')
  vim.cmd('normal! v')
  local er, ec2 = end_corner(el, ec)
  vim.api.nvim_win_set_cursor(0, { er, ec2 })
  pcall(vim.cmd, 'normal! zv')
end

--- The operator-pending <expr> body: compute, cancel or delegate.
---@param i integer
---@return string
local function o_rhs(i)
  local sl, sc, el, ec, why = region_of(i)
  if not sl then
    say_later(why or 'no region')
    return '<Esc>' -- cancel the pending operator, Vim's E348 style
  end
  if sl == el and sc > ec and not (vim.v.operator == 'c' or vim.v.operator == 'd') then
    -- the empty region (""), and an operator that cannot act on one
    say_later('the region is empty — nothing to do')
    return '<Esc>'
  end
  return ('<Plug>(gliter-textobj-%d)'):format(i)
end

--- The visual-mode body: reselect exactly the region, charwise.
---@param i integer
local function x_rhs(i)
  local sl, sc, el, ec, why = region_of(i)
  if not sl then
    return say_later(why or 'no region')
  end
  local m = vim.api.nvim_get_mode().mode
  if m ~= 'v' then
    vim.cmd('normal! v') -- V and CTRL-V become charwise, anchor kept
  end
  -- from, swap corners, to: the selection is exactly [from, to] — and
  -- for an empty region, to is from-1, which is exactly the selection
  -- Vim's own `vi"` leaves on `""` (cursor on the opening quote, anchor
  -- on the closing one).
  local sr, sc2 = start_corner(sl, sc)
  vim.api.nvim_win_set_cursor(0, { sr, sc2 })
  pcall(vim.cmd, 'normal! zv')
  vim.cmd('normal! o')
  local er, ec2 = end_corner(el, ec)
  vim.api.nvim_win_set_cursor(0, { er, ec2 })
  pcall(vim.cmd, 'normal! zv')
end

------------------------------------------------------------------ setup --

--- Create (or re-create — the last mapping created wins in Vim) every
--- key the configured objects map. setup() calls it, the reclaim
--- guards call it when they find a key gone, and :GliterTextobjClaim
--- calls it anytime.
local function apply_maps()
  for i, o in ipairs(objects) do
    -- the plain per-object mapping the expr delegates to: LHS starting
    -- with <Plug> is remappable by default, which is what makes the
    -- delegation work — and it recomputes the region, so a dot-repeat
    -- (which replays these keys, not the expression) stays honest
    vim.keymap.set('o', ('<Plug>(gliter-textobj-%d)'):format(i), function()
      plug_select(i)
    end, {
      silent = true,
      desc = o.desc,
    })
    vim.keymap.set('o', o.lhs, function()
      return o_rhs(i)
    end, {
      expr = true,
      silent = true,
      desc = o.desc,
    })
    vim.keymap.set('x', o.lhs, function()
      x_rhs(i)
    end, {
      silent = true,
      desc = o.desc,
    })
  end
end

--- Which of gliter's keys something else owns right now — the audit
--- behind the reclaim guards. A key is stolen when the map that
--- would answer it is not gliter's: another plugin's, an init line's,
--- a map somebody deleted, or a buffer-local override — which beats
--- every global map, whoever made it.
local function stolen_keys()
  local out, seen = {}, {}
  for _, o in ipairs(objects) do
    for _, mode in ipairs({ 'o', 'x' }) do
      local m = vim.fn.maparg(o.lhs, mode, false, true)
      local ours = false
      if type(m) == 'table' and not vim.tbl_isempty(m) then
        ours = (type(m.desc) == 'string' and m.desc:find('gliter', 1, true) ~= nil)
          or (type(m.rhs) == 'string' and m.rhs:find('gliter', 1, true) ~= nil)
      end
      if not ours then
        local k = mode .. o.lhs
        if not seen[k] then
          seen[k] = true
          out[#out + 1] = {
            lhs = o.lhs,
            mode = mode,
            buflocal = type(m) == 'table' and not vim.tbl_isempty(m) and m.buffer == 1 or false,
          }
        end
      end
    end
  end
  return out
end

--- The guards' body: re-assert, but only when a key was actually
--- taken — while the keys are gliter's this costs a few maparg calls
--- and changes nothing. A buffer-local thief is deleted first (it
--- would keep winning however late gliter maps), then every key is
--- mapped again, which wins them all back — silently: the keys just
--- work again.
local function reclaim_audit()
  local stolen = stolen_keys()
  if #stolen == 0 then
    return
  end
  for _, s in ipairs(stolen) do
    if s.buflocal then
      pcall(vim.keymap.del, s.mode, s.lhs, { buffer = 0 })
    end
  end
  apply_maps()
end

---@param opts? table
function M.setup(opts)
  M.did_setup = true
  opts = (type(opts) == 'table') and opts or {}
  for k, v in pairs(opts) do
    if k == 'quotes' or k == 'separators' then
      cfg[k] = (type(v) == 'table') and v or cfg[k]
    else
      cfg[k] = v
    end
  end

  objects = {}

  local function map_object(spec, lhs, desc)
    spec.lhs = lhs
    spec.desc = desc
    objects[#objects + 1] = spec
  end

  local kindname = { i = 'inside', a = 'around', I = 'inside trimmed' }

  for _, q in ipairs(cfg.quotes) do
    local maps = {
      { lhs = 'i' .. q, kind = 'i', where = nil },
      { lhs = 'a' .. q, kind = 'a', where = nil },
      { lhs = 'I' .. q, kind = 'I', where = nil },
    }
    if cfg.seek then
      maps[#maps + 1] = { lhs = 'in' .. q, kind = 'i', where = 'next' }
      maps[#maps + 1] = { lhs = 'an' .. q, kind = 'a', where = 'next' }
      maps[#maps + 1] = { lhs = 'In' .. q, kind = 'I', where = 'next' }
      maps[#maps + 1] = { lhs = 'il' .. q, kind = 'i', where = 'last' }
      maps[#maps + 1] = { lhs = 'al' .. q, kind = 'a', where = 'last' }
      maps[#maps + 1] = { lhs = 'Il' .. q, kind = 'I', where = 'last' }
    end
    for _, m in ipairs(maps) do
      local where_s = m.where == 'next' and 'next pair '
        or m.where == 'last' and 'last pair ' or ''
      map_object({ t = 'quote', c = q, k = m.kind, w = m.where }, m.lhs,
        ('gliter.textobj: %s %s%s quotes'):format(kindname[m.kind], where_s, q))
    end
  end

  for _, s in ipairs(cfg.separators) do
    for kind, name in pairs({ i = 'between', a = 'around', I = 'between trimmed' }) do
      map_object({ t = 'sep', c = s, k = kind }, kind .. s,
        ('gliter.textobj: %s the %s separators'):format(name, s == '\\' and '\\' or s))
    end
  end

  apply_maps()

  -- :GliterTextobjClaim — map gliter's keys again, right now: the last
  -- mapping created wins in Vim, so whatever took a key over after
  -- setup() (another plugin, an old line in an init file, a lazy
  -- loader) loses it back. The companion to :GliterTextobjCheck.
  vim.api.nvim_create_user_command('GliterTextobjClaim', function()
    apply_maps()
    notify(('mapped %d text-object keys again'):format(#objects))
  end, { desc = 'gliter.textobj: re-assert every mapping (the last one created wins in Vim)' })

  -- mappings created AFTER gliter's setup win in Vim — so when
  -- something else takes a key over, gliter maps its keys again and
  -- wins them back. The guards, all opted out with reclaim = false:
  --   * VimEnter — one re-map once every plugin has loaded;
  --   * a deferred audit three seconds in — timers, LSP handlers and
  --     other late starters that map after the startup dust settles;
  --   * BufEnter and FileType, audit-first (nothing happens while the
  --     keys are gliter's) — lazy loaders that map on file events;
  --   * UIEnter and InsertEnter, once each, audit-first too.
  -- :GliterTextobjClaim does the same on demand, anytime.
  if cfg.reclaim ~= false then
    local group = vim.api.nvim_create_augroup('GliterTextobjReclaim', { clear = true })
    if vim.v.vim_did_enter == 0 then
      vim.api.nvim_create_autocmd('VimEnter', {
        group = group,
        once = true,
        callback = apply_maps,
      })
      vim.api.nvim_create_autocmd('VimEnter', {
        group = group,
        once = true,
        callback = function()
          vim.defer_fn(reclaim_audit, 3000)
        end,
      })
    end
    vim.api.nvim_create_autocmd({ 'BufEnter', 'FileType' }, {
      group = group,
      callback = reclaim_audit,
    })
    vim.api.nvim_create_autocmd({ 'UIEnter', 'InsertEnter' }, {
      group = group,
      once = true,
      callback = reclaim_audit,
    })
  end

  -- :GliterTextobjCheck — the first thing to run when a key does not
  -- behave: every operator-pending key gliter maps, with who owns it
  -- right now — the FILE a foreign Lua callback was defined in — and
  -- Visual-mode keys are audited too.
  vim.api.nvim_create_user_command('GliterTextobjCheck', function()
    local lines = { 'gliter.textobj — who owns the operator-pending keys:' }
    local foreign = 0
    local function show(lhs, mode)
      local m = vim.fn.maparg(lhs, mode, false, true)
      if type(m) ~= 'table' or vim.tbl_isempty(m) then
        if mode == 'o' then
          lines[#lines + 1] = ('  %-4s (unmapped — a built-in text object answers)'):format(lhs)
        end
        return
      end
      local rhs = m.rhs or (m.callback and '<Lua callback>') or '?'
      if m.lhs and m.lhs:find('^<Plug>%(gliter%-textobj') then
        if mode == 'o' then
          lines[#lines + 1] = ('  %-32s gliter'):format(lhs)
        end
      elseif rhs:find('gliter', 1, true) or (m.desc or ''):find('gliter', 1, true) then
        if mode == 'o' then
          local desc2 = type(m.desc) == 'string' and m.desc or ''
          lines[#lines + 1] = ('  %-4s gliter%s'):format(lhs,
            desc2 ~= '' and (' — ' .. desc2) or '')
        end
      else
        foreign = foreign + 1
        local script = type(m.script) == 'string' and m.script or ''
        local desc = type(m.desc) == 'string' and m.desc or ''
        local from = ''
        if type(m.callback) == 'function' then
          -- name the file behind a foreign Lua callback — the one
          -- thing :verbose omap cannot show for a callback
          local ok, info = pcall(debug.getinfo, m.callback, 'S')
          if ok and type(info) == 'table' and info.short_src then
            from = (' (defined at %s:%d)'):format(info.short_src, info.linedefined or 0)
          end
        end
        lines[#lines + 1] = ('  %-4s %-2s FOREIGN: %s%s%s%s'):format(lhs, mode, rhs, from,
          script ~= '' and ('  (from ' .. script .. ')') or '',
          desc ~= '' and (' — ' .. desc) or '')
      end
    end
    local keys = {}
    for _, q in ipairs(cfg.quotes) do
      for _, lhs in ipairs({ 'i' .. q, 'a' .. q, 'I' .. q, 'in' .. q, 'an' .. q, 'In' .. q, 'il' .. q, 'al' .. q, 'Il' .. q }) do
        keys[#keys + 1] = lhs
      end
    end
    for _, s in ipairs(cfg.separators) do
      for _, pfx in ipairs({ 'i', 'a', 'I' }) do
        keys[#keys + 1] = pfx .. s
      end
    end
    for _, lhs in ipairs(keys) do
      show(lhs, 'o')
    end
    for _, lhs in ipairs(keys) do
      show(lhs, 'x')
    end
    for i = 1, #objects do
      local d = vim.fn.maparg(('<Plug>(gliter-textobj-%d)'):format(i), 'o', false, true)
      if type(d) ~= 'table' or vim.tbl_isempty(d) then
        lines[#lines + 1] = ('  <Plug>(gliter-textobj-%d) MISSING — run setup() again'):format(i)
      end
    end
    if foreign > 0 then
      lines[#lines + 1] = ('%d key%s owned by something else — :GliterTextobjClaim maps them again (the last mapping created wins); :verbose omap <key> confirms.'):format(
        foreign, foreign == 1 and ' is' or 's are')
    else
      lines[#lines + 1] = '  every operator-pending and Visual key is gliter\'s'
    end
    vim.api.nvim_echo(vim.tbl_map(function(l)
      return { l, 'None' }
    end, lines), true, {})
  end, { desc = 'gliter.textobj: who owns every operator-pending text-object key' })

  return M
end

return M
