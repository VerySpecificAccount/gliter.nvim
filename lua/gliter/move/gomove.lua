--- gliter.move's moving engine, ported from booperlv/nvim-gomove (MIT
--- License, Copyright (c) 2021 booperlv —
--- https://github.com/booperlv/nvim-gomove). The algorithms are that
--- plugin's: the line moves (the :move block swap, the >>/<< indent
--- drag), the block moves (the cut-and-paste rectangle, the virtualedit
--- walk, the trailing-whitespace bookkeeping), and the fold-aware
--- destination arithmetic. Adapted to be driven from gliter's move
--- session:
---
---   * the functions take explicit positions and return the moved
---     region — gomove's are driven by marks and its own mappings
---   * the undo joining is the session's business: _change() joins
---     every change onto the last undo entry but the session's first,
---     so a whole session is one undo step (gomove's undo.lua replaced)
---   * gomove's block_horizontal saved and restored a register
---     literally named "register" while cutting with z — an upstream
---     bug that wiped the z register on every move; fixed here, and
---     the register's TYPE is kept through the save/restore too
---   * gomove's duplicate-half is not ported: the mode moves, it does
---     not duplicate — use gomove itself for that
---
--- Options (gomove's own, exposed through gliter.move's setup):
---   reindent          reindent lines after a vertical line move
---                     (gomove defaults true; gliter ships false — a
---                     move moves, it does not reformat)
---   move_past_end_col let a block slide past the end of the shortest
---                     row it covers, padding rows as it lands (gomove
---                     defaults false; gliter ships true — the hug)

local M = {}

M.opts = { reindent = false, move_past_end_col = true }

---------------------------------------------------------------------------
-- the session's undo joining
---------------------------------------------------------------------------

M.join = false -- true once the session has made its first change
local in_move = false -- true after the first change of the current move

--- Start a move: the first change of THIS move joins onto the session's
--- earlier changes only when the session already made some.
function M._begin()
  in_move = false
end

--- Call immediately before every buffer-changing command: the change
--- joins onto the previous undo entry, so a whole session is ONE undo
--- step (the cancel rewinds by number — `:undo {seq}` — the join only
--- serves the user's own later `u`).
function M._change()
  if M.join or in_move then
    pcall(vim.cmd, 'silent! undojoin')
  end
  in_move = true
end

---------------------------------------------------------------------------
-- folds (gomove's utils)
---------------------------------------------------------------------------

local function fold_start(num)
  return (vim.fn.foldclosed(num) ~= -1 and vim.fn.foldclosed(num) or num)
end

local function fold_end(num)
  return (vim.fn.foldclosedend(num) ~= -1 and vim.fn.foldclosedend(num) or num)
end

local function contains_fold(startnum, endnum)
  local found = {}
  local i = startnum
  while i <= endnum do
    if vim.fn.foldclosed(i) ~= -1 then
      found[#found + 1] = { vim.fn.foldclosed(i), vim.fn.foldclosedend(i) }
      if vim.fn.foldclosedend(i) > endnum then
        break
      end
      i = vim.fn.foldclosedend(i)
    end
    i = i + 1
  end
  return (next(found) and true or false), found
end

local function open_fold(line_start, line_end)
  local has, folds = contains_fold(line_start, line_end)
  if has then
    for _, f in ipairs(folds) do
      vim.cmd(f[1] .. ',' .. f[2] .. 'foldopen')
    end
  end
end

-- the height of a range as the user sees it: a closed fold is one line
local function user_height(start_range, end_range)
  local n = 0
  local i = start_range
  while i <= end_range do
    n = n + 1
    if vim.fn.foldclosedend(i) ~= -1 then
      i = vim.fn.foldclosedend(i) + 1
    else
      i = i + 1
    end
  end
  return n
end

-- gomove's utils.reindent: reindent the first line by filetype, then
-- apply the same delta to the rest
local function reindent(new_line_start, new_line_end)
  local has_fold = contains_fold(new_line_start, new_line_end)
  if not has_fold then
    vim.fn.cursor(new_line_start, 1)
    local old_indent = vim.fn.indent('.')
    vim.cmd('silent! normal! ==')
    local new_indent = vim.fn.indent('.')
    if new_line_start < new_line_end and old_indent ~= new_indent then
      local op = (old_indent < new_indent)
        and string.rep('>', new_indent - old_indent)
        or string.rep('<', old_indent - new_indent)
      local old_sw = vim.fn.shiftwidth()
      vim.o.shiftwidth = 1
      vim.cmd('silent! ' .. new_line_start + 1 .. ',' .. new_line_end .. op)
      vim.o.shiftwidth = old_sw
    end
  end
end

---------------------------------------------------------------------------
-- the destination of a vertical move (gomove's handle_vertical)
---------------------------------------------------------------------------

local function normal_move(going_down, next_position)
  vim.fn.cursor(next_position, 1)
  vim.cmd('normal! ' .. (going_down and 'j' or 'k'))
  return vim.fn.line('.')
end

-- move past folds recursively to avoid going into them
local function block_move(going_down, next_position, height)
  local prev_position = next_position
  vim.fn.cursor(prev_position, 1)
  if going_down then
    vim.cmd('normal! j')
    next_position = vim.fn.line('.') + (height - 1)
    -- workaround for end of file is fold
    if fold_end(next_position) >= vim.fn.line('$') then
      next_position = prev_position
    end
  else
    vim.cmd('normal! k')
    next_position = vim.fn.line('.') - (height - 1)
    -- workaround for start of file is fold
    if next_position <= 1 then
      vim.cmd('normal! j')
      next_position = fold_end(vim.fn.line('.')) - 1
      return next_position
    end
  end
  return next_position
end

-- move along folds as if they were lines
local function line_move(going_down, next_position)
  local at = vim.fn.line('.') -- normal_move left the cursor here
  if going_down then
    return fold_end(at)
  end
  return fold_start(at)
end

-- The ideal destination of a vertical range moved as a block ("b") or as
-- lines ("l"): `distance` rows down (positive) or up, folds accounted
-- for. Returns the destination's first and last row.
local function handle_vertical(l_or_b, start_low, start_high, distance)
  local going_down = (distance > 0)

  start_low = fold_start(start_low)
  start_high = fold_end(start_high)

  local height = user_height(start_low, start_high)

  local next_position = going_down and start_high or start_low
  local old_pos = vim.fn.winsaveview()
  vim.fn.cursor(next_position, 1)

  for _ = 1, math.abs(distance) do
    next_position = normal_move(going_down, next_position)
    if vim.fn.foldclosed('.') ~= -1 then
      if l_or_b == 'l' then
        -- just move among folds as if they were lines
        next_position = line_move(going_down, next_position)
      else
        -- move past folds recursively to avoid going into them
        while vim.fn.foldclosed('.') ~= -1 do
          local prev_value = next_position
          next_position = block_move(going_down, next_position, height)
          if prev_value == next_position then
            break
          end
        end
      end
    end
  end
  vim.fn.winrestview(old_pos)

  local destn_low = going_down and (next_position - (height - 1)) or next_position
  return destn_low, destn_low + (height - 1)
end

---------------------------------------------------------------------------
-- linewise moves (gomove's selection/line/*)
---------------------------------------------------------------------------

--- Move the rows r1..r2 as a block of lines `distance` rows down
--- (positive) or up. Returns the new first and last row, or nil when
--- the move cannot be made.
function M.line_vertical_move(r1, r2, distance)
  M._begin()
  if not vim.o.modifiable or distance == 0 then
    return nil
  end
  local going_down = (distance > 0)
  local old_pos = vim.fn.winsaveview()

  local d1, d2 = handle_vertical('l', r1, r2, distance)
  -- If there is no actual movement, stop right here.
  if r1 == d1 and r2 == d2 then
    return nil
  end
  -- Make up for the oddness of :move: down lands after the destination
  -- block's end, up before its start.
  local destn = going_down and d2 or (d1 - 1)

  vim.fn.winrestview(old_pos)
  M._change()
  local ok = pcall(vim.cmd, r1 .. ',' .. r2 .. 'move ' .. destn)
  if not ok then
    return nil
  end
  local nr1 = vim.fn.line("'[")
  local nr2 = vim.fn.line("']")
  if M.opts.reindent then
    reindent(nr1, nr2)
  end
  return nr1, nr2
end

--- Indent (positive) or unindent the rows r1..r2 `distance` times — the
--- classic linewise drag. The rows themselves do not move; returns them.
function M.line_horizontal_move(r1, r2, distance)
  M._begin()
  if not vim.o.modifiable or distance == 0 then
    return nil
  end
  local action = (distance > 0) and string.rep('>', distance) or string.rep('<', -distance)
  M._change()
  vim.cmd('silent! ' .. r1 .. ',' .. r2 .. action)
  return r1, r2
end

--- Shift the rows r1..r2 horizontally by exact COLUMNS — the word-walk
--- carry for a line selection (gliter's own; gomove drags by
--- shiftwidths, the goto motions aim at columns). Positive prepends
--- `delta` columns of whitespace to every row; negative strips up to
--- `-delta` COLUMNS of leading whitespace from each row — a row never
--- loses text, its own indent is its floor, `<`'s own clamp — and a tab
--- that straddles the cut is split the way `<` splits it. The rows
--- themselves do not move; returns them, or nil when nothing changed.
function M.line_indent_cols(r1, r2, delta)
  M._begin()
  if not vim.o.modifiable or delta == 0 then
    return nil
  end
  local ts = vim.bo.tabstop or 8
  local rows = {}
  for r = r1, r2 do
    local line = vim.fn.getline(r) or ''
    if line == '' then
      rows[#rows + 1] = line -- a blank row has nothing to shift
    elseif delta > 0 then
      rows[#rows + 1] = (' '):rep(delta) .. line
    else
      -- strip `take` columns off the leading whitespace: whole chars
      -- while they fit, a straddling tab split into the spaces its
      -- tail covers, everything past the cut kept exactly as it was
      local take = -delta
      local ws = line:match('^%s*')
      local body = line:sub(#ws + 1)
      local drop, col, lead = 0, 0, ''
      for i = 1, #ws do
        local ch = ws:sub(i, i)
        local w = (ch == '\t') and ts or 1
        if col + w <= take then
          drop, col = i, col + w
        elseif col < take and ch == '\t' then
          -- the tab straddles the cut: its tail stays, as spaces
          lead = (' '):rep(col + w - take) .. ws:sub(i + 1)
          drop = #ws
          break
        else
          break
        end
      end
      rows[#rows + 1] = lead .. ws:sub(drop + 1) .. body
    end
  end
  local old = vim.api.nvim_buf_get_lines(0, r1 - 1, r2, false)
  for i = 1, #old do
    if old[i] ~= rows[i] then
      M._change()
      vim.api.nvim_buf_set_lines(0, r1 - 1, r2, false, rows)
      return r1, r2
    end
  end
  return nil -- every row already stood where the shift would put it
end

---------------------------------------------------------------------------
-- block moves (gomove's selection/block/*, rewritten)
--
-- A block is a RECTANGLE OF DISPLAY COLUMNS [vc1, vc2] — Vim's own
-- truth: a blockwise selection covers, on every row it spans, the
-- whole characters whose screen cells intersect the range, a wide
-- character straddling an edge included whole, and a blockwise put
-- lands every row's piece at the cursor's DISPLAY column. The ported
-- engine once walked the cut out with `l`/`h` under virtualedit and
-- pasted from a register — a walk of CHARACTER steps fed a distance
-- counted in BYTES, and on a multibyte row the two disagree: the
-- block landed past its target, deep in the virtual space past the
-- row's end, rows padded by runaway widths, pieces at columns that
-- matched no rectangle — text scrambled. The moves are now pure
-- Lua on the buffer's lines, display columns the only currency: cut,
-- slide, insert — a character is never split, a piece never lands off
-- a character boundary, the rectangle stays a rectangle.
---------------------------------------------------------------------------

--- The characters of `line` as a list of { byte_from, byte_to, vcol,
--- cells } — one entry per character, `vcol` the display column its
--- first cell occupies (1-based), `cells` how many it occupies. A
--- character's width is the increment its bytes add to the line's
--- display width — the honest way to weigh a zero-width character (a
--- variation selector, a combining mark), which strdisplaywidth
--- counts as a cell on its own but Vim's own virtcol reads as riding
--- its base's cell: such a character is FOLDED into the base's entry
--- (🖼️ one entry, two cells), so the rectangle stays Vim's own
--- truth — a lone zero-width character with no base takes a cell of
--- its own.
local function char_cells(line)
  local out = {}
  local pos = vim.str_utf_pos(line)
  local vcol = 1
  for i = 1, #pos do
    local from = pos[i]
    local to = (pos[i + 1] and pos[i + 1] - 1) or #line
    local cells = vim.fn.strdisplaywidth(line:sub(1, to))
      - vim.fn.strdisplaywidth(line:sub(1, from - 1))
    if cells == 0 and #out > 0 then
      out[#out][2] = to -- zero-width: folded into its base's entry
    else
      if cells < 1 then
        cells = 1 -- a lone zero-width character: a cell of its own
      end
      out[#out + 1] = { from, to, vcol, cells }
      vcol = vcol + cells
    end
  end
  return out
end

--- The byte columns of the characters of `line` whose display cells
--- intersect [vc1, vc2] — the block's own slice of the row. Returns
--- from_byte, to_byte (1-based, inclusive; nil when nothing
--- intersects — the row does not reach the block's left edge) and the
--- display width the slice occupies.
local function span_at_vcols(line, vc1, vc2)
  local f, t, w = nil, nil, 0
  for _, c in ipairs(char_cells(line)) do
    if c[3] <= vc2 and c[3] + c[4] - 1 >= vc1 then
      if not f then
        f = c[1]
      end
      t = c[2]
      w = w + c[4]
    end
  end
  return f, t, w
end

--- `line` with `text` inserted so its LEFT edge sits on display
--- column `vc`: the character covering that column (the first whose
--- last cell reaches it) shifts right, whole — never split; a row too
--- short for the column is padded with spaces up to it (the hug).
--- A blockwise put's own landing.
local function insert_at_vcol(line, vc, text)
  local dw = vim.fn.strdisplaywidth(line)
  if vc > dw then -- the row does not reach the column: pad up to it
    return line .. (' '):rep(vc - dw - 1) .. text
  end
  for _, c in ipairs(char_cells(line)) do
    if c[3] + c[4] - 1 >= vc then
      return line:sub(1, c[1] - 1) .. text .. line:sub(c[1])
    end
  end
  return line .. text -- past the end: appended
end

--- Cut the display-column rectangle [vc1, vc2] out of every row of
--- `arr` (one entry per row, in order): per row, the intersecting
--- characters removed and the tail CLOSED UP (the way Vim's own
--- blockwise `x` leaves the row), rows too short for the left edge
--- untouched. Returns the pieces (one per row, '' for a row that held
--- nothing) and the rows after the cut.
local function cut_rect(arr, vc1, vc2)
  local pieces, rows = {}, {}
  for i = 1, #arr do
    local line = arr[i] or ''
    local f, t = span_at_vcols(line, vc1, vc2)
    if f then
      pieces[#pieces + 1] = line:sub(f, t)
      rows[#rows + 1] = line:sub(1, f - 1) .. line:sub(t + 1)
    else
      pieces[#pieces + 1] = ''
      rows[#rows + 1] = line
    end
  end
  return pieces, rows
end

--- The byte column of display column `vc` on `line`, for placing a
--- cursor: the FIRST byte of the character covering it; past the
--- row's end, the virtual position virtualedit arithmetic speaks —
--- every column beyond the last character is one cell, so byte
--- `#line + (vc - dw)` sits exactly on `vc` under virtualedit=all.
local function byte_at_vcol(line, vc)
  local dw = vim.fn.strdisplaywidth(line)
  if vc > dw then
    return #line + (vc - dw)
  end
  for _, c in ipairs(char_cells(line)) do
    if c[3] + c[4] - 1 >= vc then
      return c[1]
    end
  end
  return #line + 1
end
M.byte_at_vcol = byte_at_vcol -- the session's corners speak it too
M.vcol_span = span_at_vcols -- the exchange's block cuts speak it too:
-- the byte span and the cell width of the chars a cell range covers

--- Move the rectangle r1..r2 x [vc1, vc2] `distance` rows down
--- (positive) or up: cut out of its rows, pasted INSERTED at the
--- destination rows on the same display columns — the landing rows
--- shift right, nothing is overwritten, the rows it leaves close up.
--- The trailing-whitespace bookkeeping rides along: a destination row
--- shorter than the block's left edge is padded when the block lands
--- on it, and once the block has moved PAST such a row the padding
--- goes home (gomove's ledger, in bytes now). Returns the new
--- rectangle's rows and display columns, or nil.
function M.block_vertical_move(r1, r2, vc1, vc2, distance)
  M._begin()
  if not vim.o.modifiable or distance == 0 then
    return nil
  end
  if contains_fold(r1, r2) then
    vim.notify('[gliter.move] a block cannot move across closed folds', vim.log.levels.WARN)
    return nil
  end
  -- If all the lines selected are empty, stop moving.
  local src = vim.api.nvim_buf_get_lines(0, r1 - 1, r2, false)
  if table.concat(src) == '' then
    return nil
  end

  local d1, d2 = handle_vertical('b', r1, r2, distance)
  if r1 == d1 and r2 == d2 then
    return nil
  end
  open_fold(d1, d2)

  -- the rows the move touches, fetched whole so the indexes stay put
  local lo = math.min(r1, d1)
  local hi = math.max(r2, d2)
  local lines = vim.api.nvim_buf_get_lines(0, lo - 1, hi, false)
  for i = 1, hi - lo + 1 do
    lines[i] = lines[i] or ''
  end

  -- the ledger: rows the landing padded (the padding starts where the
  -- row's own content ended) — stale when anything else touched the
  -- buffer since the last move
  local trailing = vim.b.gliter_move_trailing or {}
  if vim.b.gliter_move_last_ct ~= vim.b.changedtick then
    trailing = {}
  end

  -- the cut out of the source rows, then the insert at the
  -- destination's same columns — an insert, never an overwrite: the
  -- landing rows shift right, a row shorter than the left edge is
  -- padded up to it (a piece of its own, '' from a row that held
  -- nothing, pastes nothing at all)
  local pieces, cutrows = cut_rect({ unpack(lines, r1 - lo + 1, r2 - lo + 1) }, vc1, vc2)
  for i = 1, #cutrows do
    lines[r1 - lo + i] = cutrows[i]
  end
  for i = 1, #pieces do
    local piece = pieces[i]
    local idx = d1 - lo + i
    local line = lines[idx] or ''
    if piece ~= '' then
      if vim.fn.strdisplaywidth(line) < vc1 then
        -- the landing pads this row from its own end up to the edge:
        -- the ledger remembers where the padding starts
        trailing[#trailing + 1] = { idx + lo - 1, #line + 1 }
      end
      lines[idx] = insert_at_vcol(line, vc1, piece)
    end
  end

  -- the ledger's cleanup: entries no longer inside the destination
  -- keep only the PADDING the landing left — spaces from the recorded
  -- byte to the row's end, the row's own content never touched; a
  -- tail that is not pure padding is not ours to take back, the entry
  -- goes, the row stays. A row the move never touched (outside its
  -- own span) is cleaned on the live buffer — the entry once just
  -- went, and the padding a far-away landing left leaked
  local rm = {}
  for i, pos in ipairs(trailing) do
    if pos[1] < d1 or pos[1] > d2 then
      local idx = pos[1] - lo + 1
      if idx >= 1 and idx <= #lines then
        local cur = lines[idx] or ''
        if pos[2] > 1 and pos[2] <= #cur + 1 and cur:sub(pos[2]):match('^ *$') then
          lines[idx] = cur:sub(1, pos[2] - 1)
        end
      else
        local cur = vim.fn.getline(pos[1]) or ''
        if cur ~= '' and pos[2] > 1 and pos[2] <= #cur + 1
          and cur:sub(pos[2]):match('^ *$') then
          M._change() -- the write joins the move's own undo entry
          vim.api.nvim_buf_set_lines(0, pos[1] - 1, pos[1], false, { cur:sub(1, pos[2] - 1) })
        end
      end
      rm[#rm + 1] = i -- taken back, or never ours: the entry goes
    end
  end
  for i = #rm, 1, -1 do
    table.remove(trailing, rm[i])
  end

  M._change()
  vim.api.nvim_buf_set_lines(0, lo - 1, hi, false, lines)
  vim.b.gliter_move_trailing = trailing
  vim.b.gliter_move_last_ct = vim.b.changedtick
  return d1, d2, vc1, vc2
end

--- Slide the rectangle r1..r2 x [vc1, vc2] `dvc` display columns
--- right (positive) or left: the block is cut out, and pasted with
--- its left edge at column vc1 + dvc on the POST-CUT rows — the
--- characters passed over shift to where the block was, a row too
--- short for the landing padded up to it (the hug,
--- move_past_end_col). The pieces keep their own rows; nothing is
--- overwritten, no character is ever split. Returns the new
--- rectangle's display columns, or nil.
function M.block_horizontal_move(r1, r2, vc1, vc2, dvc)
  M._begin()
  if not vim.o.modifiable or dvc == 0 then
    return nil
  end
  local rectw = vc2 - vc1 + 1
  local lines = vim.api.nvim_buf_get_lines(0, r1 - 1, r2, false)
  for i = 1, #lines do
    lines[i] = lines[i] or ''
  end

  -- the option to NOT move past the end column of the shortest row:
  -- the right edge clamps to one before it, the rectangle never
  -- sliding onto the shortest row's last character (pre-cut widths,
  -- the rows as the selection found them)
  if dvc > 0 and not M.opts.move_past_end_col then
    local shortest = math.huge
    for _, l in ipairs(lines) do
      shortest = math.min(shortest, vim.fn.strdisplaywidth(l))
    end
    if vc2 < shortest then
      local new_vc2 = math.min(vc1 + dvc + rectw - 1, shortest - 1)
      dvc = math.max(0, new_vc2 - rectw + 1 - vc1)
    else
      dvc = 0 -- already at or past it: don't move anymore
    end
    if dvc == 0 then
      return nil
    end
  end

  local new_vc1 = vc1 + dvc
  if new_vc1 < 1 then
    new_vc1 = 1 -- the line's left edge is the floor
    if new_vc1 == vc1 then
      return nil
    end
  end

  local pieces, cutrows = cut_rect(lines, vc1, vc2)
  for i = 1, #cutrows do
    lines[i] = cutrows[i]
  end
  for i = 1, #pieces do
    local piece = pieces[i]
    if piece ~= '' then
      lines[i] = insert_at_vcol(lines[i], new_vc1, piece)
    end
  end

  M._change()
  vim.api.nvim_buf_set_lines(0, r1 - 1, r2, false, lines)
  return r1, r2, new_vc1, new_vc1 + rectw - 1
end

return M
