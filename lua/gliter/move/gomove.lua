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
-- block moves (gomove's selection/block/*)
---------------------------------------------------------------------------

--- Move the rectangle r1..r2 x c1..c2 `distance` rows down (positive)
--- or up: cut out of its rows, paste INSERTED at the destination rows at
--- the same column — the landing rows shift right, nothing is
--- overwritten, the rows it leaves close up. The LIVE selection must be
--- the rectangle (blockwise) when this is called — the session sees to
--- it. Returns the new rectangle, or nil.
function M.block_vertical_move(r1, r2, c1, c2, distance)
  M._begin()
  if not vim.o.modifiable or distance == 0 then
    return nil
  end
  local going_down = (distance > 0)
  local old_pos = vim.fn.winsaveview()

  local col_start, col_end = math.min(c1, c2), math.max(c1, c2)
  local width = col_end - col_start

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

  -- The trailing-whitespace bookkeeping: a row shorter than the block's
  -- left edge gets padded when the block lands on it; once the block
  -- has moved PAST such a row, the padding it left behind goes home
  -- (gomove's ledger). Rows are recorded before anything is cut.
  local all_pos = {}
  for l = d1, d2 do
    all_pos[#all_pos + 1] = { l, #(vim.fn.getline(l) or '') + 1 }
  end
  local trailing = vim.b.gliter_move_trailing or {}
  -- anything else touched the buffer since the last move: the ledger
  -- from before describes a buffer that no longer exists
  if vim.b.gliter_move_last_ct ~= vim.b.changedtick then
    trailing = {}
  end
  for _, pos in ipairs(all_pos) do
    if pos[2] < col_start then
      local has = false
      for _, v in ipairs(trailing) do
        if v[1] == pos[1] then
          has = true
          break
        end
      end
      if not has then
        trailing[#trailing + 1] = pos
      end
    end
  end

  vim.fn.winrestview(old_pos)
  local register = 'z'
  local old_reg, old_type = vim.fn.getreg(register), vim.fn.getregtype(register)
  local old_ve = vim.o.virtualedit
  vim.o.virtualedit = 'all'

  M._change()
  vim.cmd('silent! normal! "' .. register .. 'x')
  vim.fn.cursor(d1, col_start)
  M._change()
  vim.cmd('silent! normal! "' .. register .. 'P')

  vim.o.virtualedit = old_ve
  vim.fn.setreg(register, old_reg, old_type)

  -- the ledger's cleanup: entries no longer inside the destination
  local rm = {}
  for i, pos in ipairs(trailing) do
    local in_dest = false
    for _, p in ipairs(all_pos) do
      if p[1] == pos[1] then
        in_dest = true
        break
      end
    end
    if not in_dest and vim.fn.getline(pos[1]) ~= '' then
      vim.fn.cursor(pos)
      M._change()
      vim.cmd('normal! dw')
      rm[#rm + 1] = i
    end
  end
  for i = #rm, 1, -1 do
    table.remove(trailing, rm[i])
  end
  vim.b.gliter_move_trailing = trailing
  vim.b.gliter_move_last_ct = vim.b.changedtick

  return d1, d2, col_start, col_start + width
end

--- Slide the rectangle r1..r2 x c1..c2 `distance` columns right
--- (positive) or left: the block is cut out, the cursor walks to the
--- destination, and the block is pasted there — the characters passed
--- over shift to where the block was. Under virtualedit the walk can
--- carry the cursor past the end of the row (rows are padded as the
--- block lands — the hug), and a column that stalls (the row's edge) is
--- stepped by hand, exactly gomove's arithmetic. The LIVE selection
--- must be the rectangle (blockwise) when this is called. Returns the
--- new rectangle, or nil.
function M.block_horizontal_move(r1, r2, c1, c2, distance)
  M._begin()
  if not vim.o.modifiable or distance == 0 then
    return nil
  end
  local going_right = (distance > 0)
  local col_start, col_end = math.min(c1, c2), math.max(c1, c2)
  local width = col_end - col_start

  local register = 'z'
  local old_reg, old_type = vim.fn.getreg(register), vim.fn.getregtype(register)

  -- the lines' state before deleting anything (for the clamp)
  local lines = vim.api.nvim_buf_get_lines(0, r1 - 1, r2, false)
  table.sort(lines, function(a, b)
    return #a < #b
  end)

  local old_ve = vim.o.virtualedit
  vim.o.virtualedit = 'all'

  M._change()
  vim.cmd('silent! normal! "' .. register .. 'x')

  -- go to the new destination: one step at a time; when col() stalls
  -- (the end of the row for l, the start for h) the step is counted by
  -- hand — the walk's arithmetic tracks the virtual column
  local destn_start
  for _ = 1, math.abs(distance) do
    local last = destn_start
    vim.cmd('normal! ' .. (going_right and 'l' or 'h'))
    destn_start = vim.fn.col('.')
    if last == destn_start then
      destn_start = destn_start + (going_right and 1 or -1)
    end
  end

  -- the option to NOT move past the end column of the shortest row
  if going_right and not M.opts.move_past_end_col then
    local shortest = #lines[1]
    if col_end < shortest then
      if destn_start < shortest then
        vim.fn.cursor(vim.fn.line('.'), destn_start)
      else
        vim.fn.cursor(vim.fn.line('.'), shortest)
        vim.cmd('normal! ' .. width .. 'h')
        destn_start = shortest - width
      end
    else
      -- don't move anymore
      vim.fn.cursor(vim.fn.line('.'), col_start)
      destn_start = col_start
    end
  end

  M._change()
  vim.cmd('silent! normal! "' .. register .. 'P')

  vim.o.virtualedit = old_ve
  vim.fn.setreg(register, old_reg, old_type)

  -- where the put landed: its own left-edge mark — a virtual walk makes
  -- col() lag behind the cursor's real position
  local nc1 = vim.fn.getpos("'[")[3]
  return r1, r2, nc1, nc1 + width
end

return M
