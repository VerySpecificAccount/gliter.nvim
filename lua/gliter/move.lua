--- gliter.move — a visual move mode: one key turns the current Visual
--- selection into a thing you carry around the buffer. Enabled on <C-m>
--- (any Visual kind — charwise, linewise, blockwise), the keys stop
--- extending the selection and start MOVING it:
---
---   h j k l    the gomove moves — [count] works (3j = three rows)
---   0 $        the line's edges: the selection slides flush against
---              them — 0 puts its left edge at column 1, $ its right
---              edge at the end of the longest row it covers (a line
---              selection's 0 is the full dedent)
---   gg G       the buffer's edges: the lines/the block flush to the
---              buffer's top (gg) or bottom (G); {count}gg or {count}G
---              lands the top row on line {count}
---   f t F T    finds: f{char} slides the selection toward the char
---              — the carry lands just past it, the whole char
---              carried intact — t{char} stops one short of that;
---              [count] is the Nth occurrence — and F, T
---              are the backward twins: F{char} slides the selection
---              back toward the char, T{char} stops just short of it.
---              What is passed over shifts behind the selection,
---              order intact. A pending char is let go with Esc; the
---              mode stays.
---   w e b      the word motions, the same carry toward words — but
---              LINE-WISE, on the selection's own rows alone: the carry
---              is the slide, a word never takes the selection to
---              another row. FORWARD is Vim's own direction, left to
---              right, and the walk is ROW-FIRST: the words of the
---              line the CURSOR is on — the first line, where the
---              cursor was — are walked before any other's, w landing
---              the selection's right edge on the next word's first
---              character, e on the next word-end, one word a press —
---              and a selection that goes VERTICAL — several rows, V
---              or <C-v> alike — moves forward by the words in the
---              first line, then after reaching its end goes on to
---              the NEXT BIGGEST LINE: the next row that still
---              reaches past the edge, the walk continuing from there
---              (visual mode's own expanding-to-the-right shape),
---              walking all the way to the RIGHT END of the LONGEST
---              LINE covered — past it w is dead. b is the backward
---              twin, the left edge landing on the previous word's
---              first, right to left — with a FLOOR: the beginning of
---              the line. b keeps moving back until column 1, all the
---              way to 0, and past it is dead. On a line selection (V)
---              the carry is the COLUMN shift — every line moves
---              together by exact columns, the walking edge the
---              cursor row's own first word — and b's floor is the
---              FULL dedent, every line to its own beginning.
---              [count] is the Nth word. A word is Vim's own
---              ('iskeyword'), the way `w` reads one.
---   W E B      the WORD twins: Vim's WORDs — non-blank runs,
---              punctuation riding along — the same line-wise carry
---              (W the right edge on the next WORD's first
---              character, E its end, B the left edge on the previous
---              WORD's first), the same first-line-first walk, the
---              same b-to-0 floor, the same right end of the longest
---              line
---   o O        Vim's own corner keys: the cursor walks to another
---              corner of the selection — which corner is the moving
---              one is the cursor's business, the way it is in Visual
---
--- The moving engine is booperlv/nvim-gomove's, ported (see
--- lua/gliter/move/gomove.lua). What each move
--- does per selection kind — gomove's own truth:
---
---                vertical (j/k)             horizontal (h/l)
---   charwise     the span lifts onto the     the span slides through
---   (one line)   next/previous row, at      the line, swapping with
---                the same column            the text passed over
---   charwise     from the line's left       the rectangle of its
---   (several     edge: whole rows move      corners slides through
---   lines)       as a block of lines;       the rows it covers
---                otherwise the RECTANGLE
---                of its corners moves as
---                a block, inserted at the
---                landing rows
---   linewise     the lines move as a        h and l indent / unindent
---   (V)          block of lines             one shiftwidth per press
---                                           (the classic drag)
---   blockwise    the block is cut out and   the block slides THROUGH
---   (<C-v>)      re-inserted a block of     each row: the characters
---                rows away, INSERTED at     passed over move to where
---                the same column; short     the block was; short rows
---                rows are padded where      are padded where the
---                it needs room to land      block needs room to land
---
--- How a session ENDS — and only the last takes everything back:
---
---   <C-t>      KEEP — the moves stay, the selection is dropped, back
---   <C-m><C-t> to normal mode on what moved (either form; <C-m><C-t>
---              is the old spelling, kept working)
---   <Esc>      UNDO — the buffer goes back to the state it had when
---   <C-c>      the mode was entered: the undo sequence number the
---   any other  session started from is remembered, and the
---   key        cancellation is one `:undo {seq}` to it — exact, even
---              from deep in the tree, and never past the start (any
---              key the mode does not know — an operator, a mode
---              change, anything that is not a move — does the same:
---              leaving is a cancellation, not a confirmation)
---   <C-x>      EXCHANGE — inside the mode, the first press marks the
---              selection as the first area of an exchange: it stays
---              highlighted and the mode exits to normal mode for
---              selecting the second area. A move made first is
---              UNDONE by the press — the exchange trades what was
---              SELECTED, not where it was carried, so the buffer is
---              taken back to the state it had when the mode was
---              entered and the selection back to where it started
---              before anything is marked. The second <C-x> — pressed
---              in the mode again (C-m, moves, C-x), on a plain Visual
---              selection, or as C-x{motion} from normal mode, the
---              motion's span the second area — swaps the two areas,
---              whatever each side selected: a block trades with a
---              word or a line too — the word lands in the rectangle's
---              top-left, the rectangle's rows carried into the word's
---              place; both on one row, the swap happens inside that
---              row; moves made before it are undone the same way. From
---              normal mode the DIRECTION motions are spelled with
---              the Ctrl on: C-x C-h/j/k/l swaps with the span the
---              direction names (the plain h j k l after C-x are
---              freed — they leave the pending aim and move, an
---              accidental hjkl no longer swaps a one-character
---              sliver); every other motion aims natively — C-x w,
---              C-x f{char}, C-x $, C-x gg and the rest. A pending
---              exchange waits for the second area and nothing else:
---              <Esc> and <C-c> cancel it (normal or Visual), and so
---              does anything that touches the buffer or leaves the
---              normal/Visual pair — an edit, a paste, one of your
---              own move-line maps, a jump into insert. Motions never
---              cancel it: operator-pending is how the second area
---              is aimed. The marked area is a snapshot; the moment
---              something else changes the text, the wait is over.
---
--- The moves are one undo entry either way: every move after the first
--- is :undojoin-ed onto it, so the cancellation is a single `undo`, and
--- `u` after a KEPT session takes the whole session back too.
---
--- From NORMAL mode <C-m> is a MODE — a getchar() loop, the visual
--- session's own shape, that stays until it is left:
---
---   C-h C-j    transposes WORDS, Vim's own ('iskeyword'), in the
---   C-k C-l    DIRECTION the key names — the Ctrl is ON, the way
---              the exchange's aim keys spell theirs: C-m C-l with
---              the word after the cursor's (Emacs' own M-t), C-m
---              C-h with the one before, C-m C-j with the word below,
---              C-m C-k with the word above (the word whose span
---              sits nearest the cursor word's column, blank lines
---              crossed) — so in foo(bar, baz) the cursor on bar and
---              C-m C-l is foo(baz, bar): the args trade places, the
---              punctuation does not move. The plain h j k l o i are
---              REPLACED, not aliased — C-m C-o is not the same as
---              C-m o — a plain letter is a key the mode does not
---              know. The trade is made ONCE and the mode is done
---              with it — a second trade takes another <C-m> (the
---              old C-t {direction} spelling works the same). On a
---              gap the words AROUND it are the pair (Emacs' rule),
---              C-h and C-l reading the same pair from either side;
---              [count] bubbles the word along, the cursor riding it.
---   C-o / C-i  the jumps: C-o back, C-i forward through THIS FILE'S
---              TRAIL — Vim's own jump list (gg, G, marks, % —
---              everything that jumps feeds it) walked with only the
---              current file's entries applied: a jump that went to
---              another file is skipped, never taken, so a session of
---              file1 > file2 > file1 walks file1's positions alone.
---              The cursor LANDS on each location, [count] locations
---              at a time, and every press keeps walking — the keys
---              mix freely (C-m C-i C-o C-o steps forward one, back
---              two). Native C-o/C-i and new jumps re-anchor the
---              walk, plain moves do not. jumps.scope = 'own' walks a
---              separate list per file instead — Vim's jump records
---              bucketed per file, each list outliving Vim's window
---              list and untouched by what the other files do
---
--- [count] works typed before <C-m> or between the mode's keys.
--- <Esc> and <C-c> leave the mode quietly; anything else — a letter,
--- an operator — is let go with a short notice. Buffers whose <CR> is
--- their own (netrw's open, the quickfix's select, help's follow)
--- never see the mode: their <CR> maps are buffer-local and a local
--- map beats a global one, so Enter keeps opening what it always
--- opened.
---
--- The lineage: Emacs could move lines before any of the Vim plugins —
--- `transpose-lines` (on `C-x C-t`) has swapped the line under point
--- since the 1980s, `transpose-words` (on `M-t`) swapped the words
--- around point just as long — C-m C-l is that key, Vim's words in
--- Emacs' shape — and rejeep's drag-stuff (2010) turned the swap into
--- a carry (`M-<up>`/`M-<down>` take the line — or the region — along).
--- On the Vim side: booperlv's nvim-gomove (2021), whose move engine
--- gliter.move now carries (a port — the algorithms are gomove's, the
--- mode around them is gliter's), mini.move (2022), which proved any
--- Visual selection can be dragged with four keys, and dragvisuals.vim
--- (2006). For richer EXCHANGES than the two-area swap here —
--- treesitter-aware swapping, dragging across levels — use
--- mizlan/iswap.nvim; for
--- duplicating while moving, folding-aware stack moves and the rest,
--- use gomove itself: https://github.com/booperlv/nvim-gomove
---
--- The goto motions (0 $ gg G f t F T) carry the selection to a place,
--- the way a motion takes the cursor: each lands on character
--- boundaries and never lets the carried text cross what it was aimed
--- at — the text passed over shifts behind the selection, order
--- intact, so a line is never scrambled by a carry.
---
--- HOW IT WORKS: the session is a getchar() loop, not a mapping maze.
--- The mapping is a bare <Cmd> — the Visual selection is never dropped:
--- the loop reads it live from the `v` mark and the cursor, and every
--- move is the ported gomove operation on the live buffer (the
--- cut-and-paste with register z under virtualedit, the :move for
--- lines), followed by a re-select so the selection visibly follows the
--- keys. A block move cuts a BLOCKWISE selection — a charwise span is
--- re-selected as the rectangle of its corners first, exactly gomove's
--- own `g`<C-v>g`>`. When the loop ends — <Esc>, the confirm or
--- exchange key, <C-c>, or any key the mode does not know — the
--- selection is left standing: still Visual, on the moved text, so
--- what moved stays in sight. Moves work on character boundaries (a
--- multibyte character is never cut in half). The SCREEN cursor stays
--- in the buffer the whole time — on the selection, on the jump — and
--- never on the message line at the bottom of the screen: every hint
--- is flushed with the cursor at its buffer position again, and the
--- waits read their keys with the cursor kept there (0.11+'s own
--- {cursor = 'keep'}; an older nvim shows it on the message line, the
--- way a getchar() always has).
---
--- USAGE (from your init.lua)
---   require('gliter.move').setup()                  -- defaults
---   require('gliter.move').setup { keys = { mode = '<M-m>' } }
---   require('gliter.move').setup { hint = false }    -- no key echo
---   require('gliter.move').setup { reindent = true } -- gomove's option
---   require('gliter.move').setup { jumps = { scope = 'own' } }
---                    -- a separate jump list per file, C-m C-o/C-i
---                    -- walking each file's own trail
---   require('gliter').setup { move = {} }           -- through gliter
---
---   The carry itself is an API — the goto motions' two legs, for
---   other plugins to aim (a flash.nvim jump, a treehopper node, your
---   own maps): carry_to({ row, col }, region?), positions 1-based
---   byte columns, `region` the selection to carry (the live Visual
---   one when left out), the carry one undo entry. flash.nvim, for
---   instance — `S` on a
---   selection picks a label, the selection lands where it points
---   (flash's positions are 0-based, carry_to's are 1-based):
---
---   vim.keymap.set('x', 'S', function()
---     local v1, v2 = vim.fn.getpos('v'), vim.fn.getpos('.')
---     local kind = vim.fn.visualmode()
---     require('flash').jump({
---       action = function(match)
---         require('gliter.move').carry_to({ match.pos[1] + 1, match.pos[2] + 1 }, {
---           mode = kind, r1 = v1[2], c1 = v1[3], r2 = v2[2], c2 = v2[3],
---         })
---       end,
---     })
---   end)
---
--- Requires Neovim 0.10+ (vim.keycode, charidx).

local M = {}

if vim.fn.has('nvim-0.10') == 0 then
  function M.setup()
    vim.notify('[gliter] move needs Neovim 0.10+ (vim.keycode, charidx)', vim.log.levels.WARN)
  end
  return M
end

M.did_setup = false

M.defaults = {
  keys = {
    mode = '<C-m>', -- x: enter the move mode on the selection
    normal = '<C-m>', -- n: the mode — C-h C-j C-k C-l transpose the
    -- adjacent words in that direction (once), C-o/C-i walk this
    -- file's jumps, repeatable (false keeps Enter)
    confirm = '<C-t>', -- in-mode: keep the moves
    exchange = '<C-x>', -- in-mode / x: exchange — first press marks, second swaps (a pending wait also takes C-x{motion} from normal mode)
  },
  hint = true, -- echo the keys while the mode runs; false silences it
  reindent = false, -- gomove's option: reindent lines after a vertical line move
  move_past_end_col = true, -- gomove's option: a block may slide past the end of the shortest row it covers (the hug)
  jumps = {
    scope = 'file', -- C-m C-o/C-i: 'file' walks Vim's own jump list, only the
    -- current file's entries — a jump that went to another file is
    -- skipped, never taken; 'own' keeps a separate jump list per file
    -- (Vim's own jump records, bucketed per file, each file's list its
    -- own — a list outlives Vim's hundred-shared-entries window list)
    max = 100, -- 'own' only: each file's list depth
  },
}

M.options = vim.deepcopy(M.defaults)


local BLOCK = '\22' -- what visualmode() returns for a blockwise selection

---@class MoveRegion the selection a session carries: rows 1-based, the
---columns byte columns 1-based (what getpos()/setpos() speak)
---@field mode string 'v' | 'V' | '\22'
---@field r1 integer
---@field c1 integer
---@field r2 integer
---@field c2 integer

---------------------------------------------------------------------------
-- characters, pure and testable
---------------------------------------------------------------------------

--- The characters of `line`, plus the byte offset each one starts at
--- (1-based; one sentinel past the end).
---@param line string
---@return string[] cs
---@return integer[] starts
local function char_map(line)
  local cs = vim.fn.split(line, '\\zs')
  local starts = {}
  local off = 1
  for i, ch in ipairs(cs) do
    starts[i] = off
    off = off + #ch
  end
  starts[#cs + 1] = off
  return cs, starts
end

--- Byte column (1-based) of char column `c` in `line`.
---@param line string
---@param c integer
---@return integer
local function byte_col(line, c)
  if c <= 1 then
    return 1
  end
  local b = vim.fn.byteidx(line, c - 1)
  if b < 0 then
    return #line + 1
  end
  return b + 1
end

--- Char column (1-based) of byte column `b` in `line`, rounded down to
--- the character boundary it sits in.
---@param line string
---@param b integer
---@return integer
local function char_col(line, b)
  if b <= 1 then
    return 1
  end
  local c = vim.fn.charidx(line, b - 1)
  while c < 0 and b > 1 do
    b = b - 1
    c = vim.fn.charidx(line, b - 1)
  end
  return c + 1
end

--- Replace `line`'s byte range [from..to] (1-based, inclusive) with `repl`.
---@param line string
---@param from integer
---@param to integer
---@param repl string
---@return string
local function splice(line, from, to, repl)
  return line:sub(1, from - 1) .. repl .. line:sub(to + 1)
end

--- Take back the spaces a block dragged through: when everything from
--- byte offset `from` on is spaces, they go.
---@param line string
---@param from integer
---@return string
local function reclaim(line, from)
  if from > #line then
    return line:sub(1, from - 1)
  end
  if line:sub(from):match('^ +$') then
    return line:sub(1, from - 1)
  end
  return line
end

--- The char column of the block's left edge on `line`, past-the-end
--- when the edge sits beyond the line: a row that short holds no piece.
---@param line string
---@param b integer byte column (1-based)
---@return integer
local function left_char(line, b)
  local ncs = vim.fn.strchars(line)
  if b > #line then
    return ncs + 1
  end
  return char_col(line, b)
end

--- Cut the block's characters out of every selected row of `lines` and
--- fill the cuts with spaces (trailing space reclaimed). Rows too short
--- to hold the block contribute an empty piece and stay as they are.
--- `keep` (vertical moves): fill but never reclaim — a row whose whole
--- tail was the block keeps the width as spaces instead of vanishing,
--- so a block dragged up or down never deletes a line.
---@param lines string[]
---@param region MoveRegion
---@param keep? boolean
---@return string[] pieces per row, the cut text ('' when nothing was there)
---@return string[] rows the source rows after the cut
function M.cut_block(lines, region, keep)
  local pieces, rows = {}, {}
  for r = region.r1, region.r2 do
    local line = lines[r] or ''
    local ncs = vim.fn.strchars(line)
    -- the left edge is judged BYTE-wise: char_col() clamps a past-the-end
    -- column down to the last character, and a row shorter than the edge
    -- would then lose that character as a "piece"
    local c1c = region.c1 > #line and (ncs + 1) or char_col(line, region.c1)
    if c1c > ncs then
      pieces[#pieces + 1] = ''
      rows[#rows + 1] = line
    else
      local finc = math.min(char_col(line, region.c2), ncs)
      local piece = vim.fn.strcharpart(line, c1c - 1, finc - c1c + 1)
      local from = byte_col(line, c1c)
      local to = byte_col(line, finc + 1) - 1
      local filled = splice(line, from, to, string.rep(' ', vim.fn.strchars(piece)))
      rows[#rows + 1] = keep and filled or reclaim(filled, from)
      pieces[#pieces + 1] = piece
    end
  end
  return pieces, rows
end

--- Paste block `pieces` onto rows r1.. of `lines` at char column `cols[i]`
--- (one per piece): short rows are padded up to the column, the pieces
--- overwrite what is there — blockwise-put semantics. Empty pieces
--- (rows that had nothing under the block) paste nothing.
---@param lines string[]
---@param r1 integer
---@param pieces string[]
---@param cols integer[]
---@return string[] lines
function M.paste_block(lines, r1, pieces, cols)
  for i, piece in ipairs(pieces) do
    if piece ~= '' then
      local r = r1 + i - 1
      local line = lines[r] or ''
      local ncs = vim.fn.strchars(line)
      local col = cols[i]
      if ncs < col - 1 then
        line = line .. string.rep(' ', col - 1 - ncs)
        ncs = col - 1
      end
      local from = byte_col(line, col)
      local finc = math.min(col + vim.fn.strchars(piece) - 1, ncs)
      local to = byte_col(line, finc + 1) - 1
      lines[r] = splice(line, from, to, piece)
    end
  end
  return lines
end

--- Region from getpos() values, corners normalized.
---@param vmode string
---@param r1 integer
---@param c1 integer
---@param r2 integer
---@param c2 integer
---@return MoveRegion
local function normalize(vmode, r1, c1, r2, c2)
  if vmode == BLOCK then
    if r1 > r2 then r1, r2 = r2, r1 end
    if c1 > c2 then c1, c2 = c2, c1 end
    return { mode = BLOCK, r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
  elseif vmode == 'V' then
    if r1 > r2 then r1, r2 = r2, r1 end
    return { mode = 'V', r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
  end
  if r1 > r2 or (r1 == r2 and c1 > c2) then
    r1, c1, r2, c2 = r2, c2, r1, c1
  end
  -- a charwise span's edges are whole characters: getpos()'s column is
  -- the FIRST byte of the character the cursor sits on, so a span whose
  -- last character is multibyte (汉字 selected with v1l reads c2 as the
  -- first byte of 字) would tear it at its midpoint — the run trades and
  -- the carries would scramble the bytes. The left edge snaps down to
  -- its character's first byte, the right edge out to its last.
  do
    local first = vim.fn.getline(r1) or ''
    if c1 >= 1 and c1 <= #first then
      c1 = byte_col(first, char_col(first, c1))
    end
    local last = vim.fn.getline(r2) or ''
    if c2 >= 1 and c2 <= #last then
      local cc = char_col(last, c2)
      local e = byte_col(last, cc + 1) - 1
      if e >= c2 then
        c2 = e
      end
    end
  end
  return { mode = 'v', r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
end

-- the exchange (C-x inside the mode): the first area is remembered as an
-- extmark — the highlight that also TRACKS the buffer, so edits between the
-- two C-x presses cannot desync it — and the second area is the selection
-- the next session confirms. Esc, at any point before that, cancels.
---------------------------------------------------------------------------


local XNS = vim.api.nvim_create_namespace('gliter.move.exchange')
local XCH = { buf = nil, ids = nil, mode = nil, mapped = nil, saved = nil, aus = nil }

-- forward: the aim keys (xch_arm's maps) speak them, and they are
-- defined further down (the swap and its reader)
local xch_region, xch_swap

--- '<C-t>' -> 'C-t': keys read as their notation, not their raw bytes.
local function keyname(s)
  return (s:gsub('^<(.+)>$', '%1'))
end

--- The width a printed line may safely reach: the screen's, less the
--- room Vim keeps for itself — the ruler, the showcmd digits, the mode
--- name — and a margin for whatever else the tail of a line can carry
--- (a "Press ENTER" would park the getchar loop under a prompt the mode
--- never asked for; a wide terminal shows everything regardless).
local function echo_width()
  return math.max(20, vim.o.columns - 20)
end

--- Put the SCREEN cursor back in the buffer after a message: an
--- echoed hint parks it on the message line — the bottom of the
--- screen — and a getchar() that waits with a message outstanding
--- keeps it there (the wait "automagically" picking the message area
--- over the buffer), so the cursor the user watches while a mode runs
--- would sit under the hint instead of on the selection, the jump,
--- the text being carried. The internal redraw with cursor = true
--- flushes the screen with the cursor at its buffer position; an
--- older nvim keeps the plain redraw (and its cursor on the message
--- line, the way a getchar() always has)
local function cursor_home()
  local ok = pcall(vim.api.nvim__redraw, { cursor = true, flush = true })
  if not ok then
    pcall(vim.cmd, 'redraw')
  end
end

--- Echo a one-line message that can never wrap: the parts are joined,
--- measured (display width, multibyte-safe) and truncated at the safe
--- edge, the cut part dropped, the highlight of the last kept part
--- carried onto the ellipsis-free remainder.
local function echo(parts)
  local w = echo_width()
  local used = 0
  local fit = {}
  for _, p in ipairs(parts) do
    local text, hl = p[1], p[2]
    local len = vim.fn.strdisplaywidth(text)
    if used + len > w then
      local room = w - used
      if room > 1 then
        -- truncate on a display boundary: keep whole characters
        local keep = ''
        for _, ch in ipairs(vim.fn.split(text, '\\zs')) do
          if vim.fn.strdisplaywidth(keep) + vim.fn.strdisplaywidth(ch) > room - 1 then
            break
          end
          keep = keep .. ch
        end
        if keep ~= '' then
          fit[#fit + 1] = { keep, hl }
        end
      end
      break
    end
    fit[#fit + 1] = { text, hl }
    used = used + len
  end
  pcall(vim.api.nvim_echo, fit, true, {})
  cursor_home() -- an echoed message parks the SCREEN cursor on the
  -- message line (the bottom of the screen); every message — a hint,
  -- a mark, an exchange's outcome — puts it back in the buffer, on
  -- the text, where the cursor belongs
end


--- Read one key, blocking, as a string — the mode's loops' own read:
--- with the SCREEN cursor kept where cursor_home() put it, in the
--- buffer (0.11+'s {cursor = 'keep'} — the wait stops deciding for
--- itself that the message line is where a cursor waits; an older
--- nvim gets the plain read). Returns nil when interrupted (<C-c>)
local KEYOPTS = vim.fn.has('nvim-0.11') == 1 and { cursor = 'keep' } or nil
local function read_char()
  local ok, k
  if KEYOPTS then
    ok, k = pcall(vim.fn.getcharstr, -1, KEYOPTS)
  else
    ok, k = pcall(vim.fn.getcharstr)
  end
  if not ok then
    return nil
  end
  return k
end

local function xch_hl()
  if vim.fn.hlexists('GliterExchange') == 0 then
    pcall(vim.api.nvim_set_hl, 0, 'GliterExchange', { link = 'IncSearch' })
  end
end

--- Drop the pending exchange: the highlight, the normal/visual Esc and
--- C-c keys that cancel it, the watchers that clear it when anything
--- else touches the buffer — and the maps that were shadowed for the
--- wait, put back exactly as they were.
local function xch_clear()
  if XCH.buf and vim.api.nvim_buf_is_valid(XCH.buf) then
    if XCH.ids then
      for _, id in ipairs(XCH.ids) do
        pcall(vim.api.nvim_buf_del_extmark, XCH.buf, XNS, id)
      end
    end
    if XCH.mapped then
      for _, mk in ipairs(XCH.mapped) do
        pcall(vim.keymap.del, mk[1], mk[2], { buffer = XCH.buf })
      end
    end
    -- the buffer-local maps that were ours to shadow come back; global
    -- maps were never touched (a buffer-local map only ever sat ABOVE
    -- one, deleting ours re-exposes theirs)
    if XCH.saved then
      for _, info in ipairs(XCH.saved) do
        pcall(vim.fn.mapset, info.mode, false, info)
      end
    end
    if XCH.aus then
      for _, id in ipairs(XCH.aus) do
        pcall(vim.api.nvim_del_autocmd, id)
      end
    end
  end
  XCH.buf, XCH.ids, XCH.mode, XCH.mapped, XCH.saved, XCH.aus = nil, nil, nil, nil, nil, nil
end

--- Remember `region` as the exchange's first area and arm everything
--- that can cancel it: Esc and C-c (normal AND visual — abandoning the
--- second selection is a cancellation too), and the watchers that clear
--- the exchange when anything else touches the buffer or changes the
--- mode — a text change (an edit, a paste, one of the user's own
--- move-line maps), a jump into insert: the wait is over, the marked
--- area is stale. Motions never cancel it — operator-pending is how
--- the second area is aimed. Keys are shadowed for the wait only,
--- and a buffer-local map that was already there is put back on clear.
local function xch_arm(buf, region)
  xch_hl()
  xch_clear()
  -- the marked area's highlight: a span or a line range is ONE mark,
  -- its whole diagonal — and a BLOCK is the RECTANGLE it selected, one
  -- mark per row, each that row's own slice of the rectangle. A single
  -- mark on a block would light the diagonal instead — every row whole
  -- between the corners — and the marked block would read as turned
  -- into a plain Visual selection the moment C-x is pressed on it
  XCH.ids = {}
  if region.mode == BLOCK then
    local lastrow = math.min(region.r2, vim.api.nvim_buf_line_count(buf))
    for r = region.r1, lastrow do
      local line = vim.api.nvim_buf_get_lines(buf, r - 1, r, false)[1] or ''
      XCH.ids[#XCH.ids + 1] = vim.api.nvim_buf_set_extmark(buf, XNS, r - 1, math.min(region.c1 - 1, #line), {
        end_col = math.min(region.c2, #line),
        hl_group = 'GliterExchange',
        hl_mode = 'combine',
        priority = 200,
      })
    end
  else
    local start_col = region.mode == 'V' and 0 or region.c1 - 1
    local end_col
    if region.mode == 'V' then
      local last = vim.api.nvim_buf_get_lines(buf, region.r2 - 1, region.r2, false)[1] or ''
      end_col = #last
    else
      end_col = region.c2
    end
    XCH.ids[#XCH.ids + 1] = vim.api.nvim_buf_set_extmark(buf, XNS, region.r1 - 1, start_col, {
      end_line = region.r2 - 1,
      end_col = end_col,
      hl_group = 'GliterExchange',
      hl_mode = 'combine',
      priority = 200,
    })
  end
  XCH.buf, XCH.mode = buf, region.mode
  XCH.mapped, XCH.saved = {}, {}
  -- THE AIM KEYS — C-x C-h/j/k/l. While the wait lasts, the second
  -- area is aimed from normal mode with C-x{motion} — and the four
  -- DIRECTION keys are spelled with the Ctrl on: C-h C-j C-k C-l,
  -- not the plain h j k l. The plain ones are freed — pressed right
  -- after C-x they just MOVE (an accidental hjkl never swaps a
  -- sliver); the Ctrl ones trade the marked area with what the
  -- direction names off the LIVE cursor, the mode's own directions —
  -- C-h the word before, C-l the word after (iskeyword's own, the
  -- way C-m h/l transpose them), C-j the line below, C-k the line
  -- above (transpose-lines' own targets). Every other motion aims
  -- natively — C-x w, C-x f{char}, C-x $, C-x gg and the rest, the
  -- motion's own span — armed as Vim's own operator with the aim key
  -- re-fed as if typed (remaps and all). The aim key is read by the
  -- C-x map itself (the wait keeps the screen cursor in the buffer);
  --- One direction's exchange: the marked area trades with `region`
  local function aim(region)
    local pending = xch_region()
    if not (pending and XCH.buf == buf) then
      echo({ { 'exchange: nothing marked', 'WarningMsg' } })
      return
    end
    xch_clear() -- before the swap: the swap's own changes must not
    -- read as somebody else's edit clearing it
    local err = xch_swap(buf, pending, region)
    if err then
      echo({ { 'exchange: ' .. err, 'WarningMsg' } })
    else
      echo({ { 'exchanged', 'Comment' } })
    end
  end
  --- The word spans of `line` as {start, end} byte cols (1-based,
  --- ends inclusive) — iskeyword's own, the way `w` reads them
  local function words_of(line)
    local out = {}
    local from = 0
    while true do
      local _, s0, e0 = unpack(vim.fn.matchstrpos(line, '\\k\\+', from))
      if not s0 or s0 < 0 then
        break
      end
      out[#out + 1] = { s0 + 1, e0 }
      from = e0
    end
    return out
  end
  --- The word the cursor sits on (or the last one before it): its
  --- index into `ws`, 0 when there is none
  local function word_at(ws, c)
    local on = 0
    for i, w in ipairs(ws) do
      if w[1] <= c and c <= w[2] then
        return i
      end
      if w[2] < c then
        on = i
      end
    end
    return on
  end
  --- The span a direction names, off the LIVE cursor: j/k the line
  --- below/above (linewise), h/l the word before/after the cursor's
  --- own. nil (with a message) when the direction is dead
  local function dir_region(d)
    local r, c0 = unpack(vim.api.nvim_win_get_cursor(0)) -- row 1-based, col 0-based
    if d == 'j' or d == 'k' then
      local t = (d == 'j') and (r + 1) or (r - 1)
      if t < 1 or t > vim.fn.line('$') then
        echo({ { 'exchange: no line ' .. (d == 'j' and 'below' or 'above')
          .. ' to exchange with', 'WarningMsg' } })
        return nil
      end
      return { mode = 'V', r1 = t, c1 = 1, r2 = t, c2 = 1 }
    end
    local line = vim.fn.getline(r) or ''
    local ws = words_of(line)
    local on = word_at(ws, c0 + 1)
    local w
    if d == 'l' then
      w = ws[on + 1] -- the word after the cursor's own (the first, off a gap)
      if not w then
        echo({ { 'exchange: no word after the cursor to exchange with', 'WarningMsg' } })
        return nil
      end
    else -- 'h'
      w = on > 0 and ws[on - 1] or nil -- the word before the cursor's own
      if not w then
        echo({ { 'exchange: no word before the cursor to exchange with', 'WarningMsg' } })
        return nil
      end
    end
    return { mode = 'v', r1 = r, c1 = w[1], r2 = r, c2 = w[2] }
  end
  -- the normal-mode <C-x> shadowed for the wait is the AIM form:
  -- the key reads the aim key itself and dispatches — the four
  -- Ctrl directions handled on the spot, the plain h j k l freed,
  -- anything else armed as Vim's own operator (the motion's span the
  -- second area). The key is only ours while the wait lasts — outside
  -- it, normal mode's <C-x> (the decrement) is never touched
  local xkey = M.options.keys.exchange and vim.keycode(M.options.keys.exchange) or nil
  local DKEYS = {
    [vim.keycode('<C-h>')] = 'h', [vim.keycode('<C-j>')] = 'j',
    [vim.keycode('<C-k>')] = 'k', [vim.keycode('<C-l>')] = 'l',
  }
  for _, mode in ipairs({ 'n', 'x' }) do
    local keys = { '<Esc>', '<C-c>' }
    if mode == 'n' and xkey then
      keys[#keys + 1] = M.options.keys.exchange
    end
    for _, k in ipairs(keys) do
      local info = vim.fn.maparg(k, mode, false, true)
      if type(info) == 'table' and info.buffer == 1 then
        XCH.saved[#XCH.saved + 1] = info -- ours to shadow, theirs to restore
      end
      local mine
      local desc = 'gliter.move: cancel the pending exchange'
      if mode == 'n' and k == M.options.keys.exchange then
        desc = 'gliter.move: exchange — C-x C-h/j/k/l (the word/line the direction names) or C-x{motion} swaps the marked area'
        mine = function()
          -- the aim key is read HERE, the mode's own read (the wait
          -- keeps the screen cursor in the buffer): the four Ctrl
          -- DIRECTIONS swap on the spot — no operator, no motion, the
          -- span computed off the live cursor — the plain h j k l are
          -- not aims at all (fed back alone they just move), and
          -- anything else arms Vim's own operator with the key re-fed
          -- as if typed: C-x w, C-x f{char}, C-x $, C-x gg and the
          -- rest, the motion's span the second area, remaps and all
          -- (g@ fed first and raw — it is ours; the aim key fed after
          -- it, remapped — it is the user's)
          local key = read_char()
          if not key or key == '\27' or key == '\3' then
            return -- let go: the wait stays exactly as it was
          end
          local d = DKEYS[key]
          if d then
            local region = dir_region(d)
            if region then
              aim(region)
            end
            return -- a dead direction is let go too; the wait stays
          end
          if key == 'h' or key == 'j' or key == 'k' or key == 'l' then
            -- the plain directions are FREE: the key moves, nothing swaps
            vim.api.nvim_feedkeys(key, 'm', false)
            return
          end
          vim.o.operatorfunc = "v:lua.require'gliter.move'._xopfunc"
          vim.api.nvim_feedkeys('g@', 'n', false)
          vim.api.nvim_feedkeys(key, 'm', false)
        end
      else
        mine = function()
          xch_clear()
          echo({ { 'exchange cancelled', 'Comment' } })
          if mode == 'x' then
            -- Esc in Visual also leaves Visual — the mapping swallowed the
            -- key, so the leaving is done here, mapping-free
            pcall(vim.cmd, [[execute "normal! \<Esc>"]])
          end
        end
      end
      vim.keymap.set(mode, k, mine, {
        buffer = buf,
        silent = true,
        desc = desc,
      })
      XCH.mapped[#XCH.mapped + 1] = { mode, k } -- the pair, exactly: a
      -- user's buffer-local map under the same key in the OTHER mode is
      -- never ours to delete
    end
  end
  -- anything that touches the buffer or leaves the (n|v) modes ends the
  -- wait: the marked area is a snapshot, and edits make it a lie. The
  -- buffer's changedtick at arm time tells the watchers what is really
  -- a touch: a TextChanged that lands with the tick unmoved is a STALE
  -- delivery from before the wait began (events can arrive late), not
  -- somebody else's edit — the marked area is exactly what it was
  -- marked on.
  local ct0 = vim.api.nvim_buf_get_var(buf, 'changedtick')
  XCH.aus = {}
  local function au(events)
    local ok, id = pcall(vim.api.nvim_create_autocmd, events, {
      buffer = buf,
      callback = function(ev)
        -- our own swap never gets here (the exchange is cleared before
        -- it runs); this is somebody else's change
        if XCH.buf == buf and XCH.ids then
          if ev.event == 'ModeChanged' then
            local m = vim.v.event.new_mode or ''
            -- picking the second area: selections, and the MOTIONS
            -- that aim one — operator-pending ('no', 'nov', 'noV',
            -- 'no\22') is <C-m>{motion} and <C-m>m C-x{motion} taking
            -- aim; an operator that edits still ends the wait through
            -- the changedtick below
            if m == 'n' or m == 'v' or m == 'V' or m == '\22'
              or vim.startswith(m, 'no') then
              return
            end
          else
            local ok2, ct = pcall(vim.api.nvim_buf_get_var, buf, 'changedtick')
            if ok2 and ct == ct0 then
              return -- stale delivery: the buffer never changed since the mark
            end
          end
          xch_clear()
          echo({ { 'exchange cancelled', 'Comment' } })
        end
      end,
    })
    if ok then
      XCH.aus[#XCH.aus + 1] = id
    end
  end
  au({ 'TextChanged', 'TextChangedI', 'TextChangedP' })
  au({ 'ModeChanged' })
end

--- The first area back from its extmarks: the marks followed the
--- buffer, so these are its CURRENT positions. A block's rectangle
--- is read off its per-row marks — the top mark's left edge, the
--- bottom mark's row, the right edge the farthest any row's slice
--- still reaches (a row the buffer has since shortened reads its
--- mark short, the rectangle honest about what is there now).
---@return MoveRegion?
xch_region = function()
  if not (XCH.buf and XCH.ids and vim.api.nvim_buf_is_valid(XCH.buf)) then
    return nil
  end
  if XCH.mode == BLOCK then
    local top, bottom, right
    for _, id in ipairs(XCH.ids) do
      local ok, m = pcall(vim.api.nvim_buf_get_extmark_by_id, XCH.buf, XNS, id, { details = true })
      if ok and type(m) == 'table' and type(m[1]) == 'number' then
        if not top then
          top = { m[1] + 1, m[2] + 1 }
        end
        bottom = m[1] + 1
        right = math.max(right or 0, (m[3] or {}).end_col or m[2])
      end
    end
    if not top or not bottom or bottom < top[1] then
      return nil
    end
    return { mode = BLOCK, r1 = top[1], c1 = top[2], r2 = bottom, c2 = right }
  end
  local ok, m = pcall(vim.api.nvim_buf_get_extmark_by_id, XCH.buf, XNS, XCH.ids[1], { details = true })
  if not ok or type(m) ~= 'table' or type(m[1]) ~= 'number' then
    return nil
  end
  local d = m[3] or {}
  local r1, c1 = m[1] + 1, m[2] + 1
  local r2 = (d.end_row or m[1]) + 1
  local c2 = d.end_col or m[2]
  if r2 < r1 or (r2 == r1 and c2 < c1) then
    return nil
  end
  return { mode = XCH.mode, r1 = r1, c1 = c1, r2 = r2, c2 = c2 }
end

--- The charwise text of region `x` on `lines`: its first row from c1, the
--- rows between whole, its last row up to c2 (byte cols, inclusive).
local function span_text(lines, x)
  local t = {}
  if x.r1 == x.r2 then
    return { (lines[x.r1] or ''):sub(x.c1, x.c2) }
  end
  t[#t + 1] = (lines[x.r1] or ''):sub(x.c1)
  for r = x.r1 + 1, x.r2 - 1 do
    t[#t + 1] = lines[r] or ''
  end
  t[#t + 1] = (lines[x.r2] or ''):sub(1, x.c2)
  return t
end

--- The rows `lines[x.r1..x.r2]` become when the region's text is replaced
--- by `t` (a span_text-style list): the surroundings on the first and last
--- row are kept, the row count follows `t`.
local function span_replace(lines, x, t)
  local first = (lines[x.r1] or ''):sub(1, x.c1 - 1)
  local post = (lines[x.r2] or ''):sub(x.c2 + 1)
  if #t == 1 then
    return { first .. t[1] .. post }
  end
  local rows = { first .. t[1] }
  for i = 2, #t - 1 do
    rows[#rows + 1] = t[i]
  end
  rows[#rows + 1] = t[#t] .. post
  return rows
end

--- Replace the byte range [c1..c2] (1-based, inclusive; the block
--- convention: c2 clamped to the row's end, c1 past it means append)
--- of `row` with `text` — the row growing or shrinking by the
--- difference, the text past the range shifting, never clobbered.
--- A mixed swap's blockwise landing: the other side's row takes the
--- rectangle's own place on this row, exactly the range it selected.
---@param row string
---@param c1 integer
---@param c2 integer
---@param text string
---@return string
local function splice_slice(row, c1, c2, text)
  local ncs = vim.fn.strchars(row)
  local lc = left_char(row, c1)
  if lc > ncs then
    return row .. text -- the row does not reach the left edge: appended
  end
  local from = byte_col(row, lc)
  local finc = math.min(char_col(row, c2), ncs)
  local to = finc >= 1 and (byte_col(row, finc + 1) - 1) or 0
  return splice(row, from, to, text)
end

--- Swap the two areas — whatever each side SELECTED, however it was
--- selected. Same-kind pairs keep their exact semantics (lines, spans,
--- rectangles); a line + span pair swaps as spans (the line's whole width
--- is its span); and a MIXED pair — a block against a span or a line —
--- trades the two texts with each side keeping its own shape: the
--- rectangle takes the other text's rows in its own place, top-left
--- first (rows the text does not reach keep the blank the cut leaves;
--- a text taller than the rectangle grows it, the extra rows landing
--- below, nothing under them clobbered), and the span/line slot takes
--- the rectangle's rows the way its own kind writes them (a span's row
--- count follows the text — the row splits; a line range's rows are
--- the text). Both on one row, the swap happens inside that row. One
--- write, one undo entry.
---@param buf integer
---@param a MoveRegion
---@param b MoveRegion
---@return string? err
xch_swap = function(buf, a, b)
  -- order: a strictly before b, or the naming is swapped
  if a.r1 > b.r1 or (a.r1 == b.r1 and a.c1 > b.c1) then
    a, b = b, a
  end

  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  if a.mode == 'V' and b.mode == 'V' then
    -- two line ranges: each takes the other's rows, everything between
    -- and around stays
    if a.r2 >= b.r1 then
      return 'the two areas overlap'
    end
    local ta, tb = {}, {}
    for i = a.r1, a.r2 do
      ta[#ta + 1] = lines[i]
    end
    for i = b.r1, b.r2 do
      tb[#tb + 1] = lines[i]
    end
    local out = {}
    for i = 1, a.r1 - 1 do
      out[#out + 1] = lines[i]
    end
    for _, l in ipairs(tb) do
      out[#out + 1] = l
    end
    for i = a.r2 + 1, b.r1 - 1 do
      out[#out + 1] = lines[i]
    end
    for _, l in ipairs(ta) do
      out[#out + 1] = l
    end
    for i = b.r2 + 1, #lines do
      out[#out + 1] = lines[i]
    end
    lines = out
  elseif a.mode == BLOCK and b.mode == BLOCK then
    -- rectangles: the space-filling cut moves nothing, so both are cut
    -- first, then each pastes into the other's slot. The cuts run
    -- SEQUENTIALLY — a's first, b's cut out of the rows a's cut already
    -- left (two rectangles on the SAME rows would otherwise each
    -- restore what the other had cut) — and each paste lands in the
    -- OTHER's slot, the slot's own rows and its own left edge: the two
    -- texts trade places, the whole rectangle trading
    if a.r2 >= b.r1 and a.c1 <= b.c2 and b.c1 <= a.c2 then
      return 'the two blocks overlap'
    end
    local pa, ra = M.cut_block(lines, a, true)
    for i, row in ipairs(ra) do
      lines[a.r1 + i - 1] = row
    end
    local pb, rb = M.cut_block(lines, b, true)
    for i, row in ipairs(rb) do
      lines[b.r1 + i - 1] = row
    end
    local na, nb = #pa, #pb
    for _ = na + 1, nb do
      pa[#pa + 1] = ''
    end
    for _ = nb + 1, na do
      pb[#pb + 1] = ''
    end
    local ca, cb = {}, {}
    for i = 1, #pa do
      ca[i] = char_col(lines[a.r1 + i - 1] or '', a.c1)
      cb[i] = char_col(lines[b.r1 + i - 1] or '', b.c1)
    end
    M.paste_block(lines, a.r1, pb, ca) -- b's text into a's slot
    M.paste_block(lines, b.r1, pa, cb) -- a's text into b's slot
  elseif a.mode == BLOCK or b.mode == BLOCK then
    -- a MIXED pair: a block's rectangle against the other's own kind —
    -- a word, a span, a line — the two texts trading anyway, each slot
    -- written the way its own kind writes (the doc above speaks it)
    local blk = (a.mode == BLOCK) and a or b
    local oth = (a.mode == BLOCK) and b or a
    if oth.mode == 'v' and oth.r1 == oth.r2 and blk.r1 == oth.r1 then
      -- the other area a one-row span on the block's own top row — the
      -- common aim (C-x C-h/C-l off the corner the mark parks the
      -- cursor on): the two trade INSIDE that row, the span path's own
      -- shape. The rectangle is its one segment there — clamped to the
      -- row's end the way Vim's own block reads a row too short for
      -- its right edge — and the block's other rows ride along: their
      -- pieces join the span's slot (the row splitting under them),
      -- their own slices keeping the blank the cut leaves
      local row = lines[blk.r1] or ''
      local bc1, bc2 = math.min(blk.c1, #row + 1), math.min(blk.c2, #row)
      local oc1, oc2 = math.min(oth.c1, #row + 1), math.min(oth.c2, #row)
      if bc2 >= oc1 and oc2 >= bc1 then
        return 'the two areas overlap'
      end
      local pieces, cutrows = M.cut_block(lines, blk, true)
      local word = row:sub(oc1, oc2)
      -- the word's span takes the pieces (the row splitting under
      -- them), and the word lands in the slice's own place — on the
      -- first row the pieces carry, the slice inside the text before
      -- the word's span (the word right of the slice) or after it (the
      -- word left of the slice, the byte columns shifted past the span)
      local first = cutrows[1]:sub(1, oc1 - 1)
      local post = cutrows[1]:sub(oc2 + 1)
      if bc2 < oc1 then -- the slice left of the word: inside `first`
        first = splice_slice(first, blk.c1, blk.c2, word)
      else -- the slice right of the word: inside `post`, past the span
        post = splice_slice(post, blk.c1 - oc2, blk.c2 - oc2, word)
      end
      local repl = {} -- the word's slot rows: the pieces, span-style
      if #pieces <= 1 then
        repl[#repl + 1] = first .. (pieces[1] or '') .. post
      else
        repl[#repl + 1] = first .. pieces[1]
        for i = 2, #pieces - 1 do
          repl[#repl + 1] = pieces[i]
        end
        repl[#repl + 1] = pieces[#pieces] .. post
      end
      local out = {}
      for i = 1, blk.r1 - 1 do
        out[#out + 1] = lines[i]
      end
      for _, l in ipairs(repl) do
        out[#out + 1] = l
      end
      for i = 2, #cutrows do -- the rectangle's other rows: blanks kept
        out[#out + 1] = cutrows[i]
      end
      for i = blk.r2 + 1, #lines do
        out[#out + 1] = lines[i]
      end
      lines = out
    elseif blk.r2 >= oth.r1 and oth.r2 >= blk.r1 then
      return 'the two areas overlap'
    else
      -- separate rows: both slots are rebuilt from the original rows
      -- and the table written once — the row counts may change on
      -- either side, the rows around them staying put
      -- the rectangle's own text, and its rows with the piece cut out
      -- (the blank stays: the space-filling cut)
      local pieces, cutrows = M.cut_block(lines, blk, true)
      -- the other's selected text, and the rows that take its slot
      local oth_text, oth_rows
      if oth.mode == 'V' then
        oth_text = {}
        for r = oth.r1, oth.r2 do
          oth_text[#oth_text + 1] = lines[r] or ''
        end
        oth_rows = pieces -- a line range's slot: the text IS its rows
      else
        oth_text = span_text(lines, oth)
        -- a span's slot: the row count follows the text, the way a
        -- span's own swaps take a taller one
        oth_rows = span_replace(lines, oth, pieces)
      end
      -- the rectangle's slot: the other's rows in its own place,
      -- top-left first — a row the text does not reach keeps the blank
      -- the cut leaves, and a text taller than the rectangle grows it:
      -- the extra rows land below, padded to the left edge, nothing
      -- clobbered
      local slot = {}
      for i = 1, math.max(#cutrows, #oth_text) do
        slot[i] = cutrows[i] or ''
      end
      local cols = {} -- the left edge's char column, each row its own
      for i = 1, #slot do
        cols[i] = left_char(cutrows[i] or lines[blk.r2 + i - #cutrows] or '', blk.c1)
      end
      for i, text in ipairs(oth_text) do
        if cutrows[i] then
          slot[i] = splice_slice(slot[i], blk.c1, blk.c2, text)
        else
          slot[i] = string.rep(' ', math.max(0, cols[i] - 1)) .. text
        end
      end
      local out = {}
      if blk.r2 < oth.r1 then
        for i = 1, blk.r1 - 1 do
          out[#out + 1] = lines[i]
        end
        for _, l in ipairs(slot) do
          out[#out + 1] = l
        end
        for i = blk.r2 + 1, oth.r1 - 1 do
          out[#out + 1] = lines[i]
        end
        for _, l in ipairs(oth_rows) do
          out[#out + 1] = l
        end
        for i = oth.r2 + 1, #lines do
          out[#out + 1] = lines[i]
        end
      else
        for i = 1, oth.r1 - 1 do
          out[#out + 1] = lines[i]
        end
        for _, l in ipairs(oth_rows) do
          out[#out + 1] = l
        end
        for i = oth.r2 + 1, blk.r1 - 1 do
          out[#out + 1] = lines[i]
        end
        for _, l in ipairs(slot) do
          out[#out + 1] = l
        end
        for i = blk.r2 + 1, #lines do
          out[#out + 1] = lines[i]
        end
      end
      lines = out
    end
  else
    -- spans (a line selection is its whole-line span when mixed with one)
    local function widen(x)
      if x.mode ~= 'V' then
        return x
      end
      local last = vim.api.nvim_buf_get_lines(buf, x.r2 - 1, x.r2, false)[1] or ''
      return { mode = 'v', r1 = x.r1, c1 = 1, r2 = x.r2, c2 = #last }
    end
    a, b = widen(a), widen(b)
    -- Both areas on the SAME ROW: the swap happens inside that one row —
    -- a's text goes where b's was and back, the text between them stays
    -- between them. (Rebuilt by the row-range path below instead, the
    -- two whole-row replacements land as two separate rows — the line
    -- duplicated, each copy carrying one of the swapped pieces.)
    if a.r1 == b.r1 and a.r2 == b.r2 and a.r1 == a.r2 then
      if a.c2 >= b.c1 then
        return 'the two areas overlap'
      end
      local row = lines[a.r1] or ''
      local ta = row:sub(a.c1, a.c2)
      local tb = row:sub(b.c1, b.c2)
      lines[a.r1] = row:sub(1, a.c1 - 1) .. tb .. row:sub(a.c2 + 1, b.c1 - 1) .. ta .. row:sub(b.c2 + 1)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      return nil
    end
    -- refuse overlaps, then rebuild the table around the two
    -- replacements — a's slot takes b's text and vice versa, everything
    -- between and around stays. Rows shared any other way than the
    -- same-row case above cannot be rebuilt honestly (the two slots'
    -- row counts change against a row both of them are on).
    if a.r2 >= b.r1 then
      return 'the two areas overlap'
    end
    local ta = span_text(lines, a)
    local tb = span_text(lines, b)
    local rowsa = span_replace(lines, a, tb)
    local rowsb = span_replace(lines, b, ta)
    local out = {}
    for i = 1, a.r1 - 1 do
      out[#out + 1] = lines[i]
    end
    for _, l in ipairs(rowsa) do
      out[#out + 1] = l
    end
    for i = a.r2 + 1, b.r1 - 1 do
      out[#out + 1] = lines[i]
    end
    for _, l in ipairs(rowsb) do
      out[#out + 1] = l
    end
    for i = b.r2 + 1, #lines do
      out[#out + 1] = lines[i]
    end
    lines = out
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return nil
end
---------------------------------------------------------------------------
-- the session: gomove's engine under a getchar() loop
---------------------------------------------------------------------------

local gomove = require('gliter.move.gomove')

--- The mode's own key for each selection kind — what re-select uses.
local MODEKEY = { v = 'v', V = 'V', [BLOCK] = vim.keycode('<C-v>') }

--- The region's corners, in a stable order: for charwise and linewise
--- the two ends, for a block all four. The corner the cursor sits on
--- is an INDEX into this list — `o` and `O` change it, moves keep it.
---@param region MoveRegion
---@return [integer, integer][]
local function corners(region)
  if region.mode == BLOCK then
    return {
      { region.r1, region.c1 },
      { region.r1, region.c2 },
      { region.r2, region.c1 },
      { region.r2, region.c2 },
    }
  end
  return { { region.r1, region.c1 }, { region.r2, region.c2 } }
end

--- Which corner index the position (r, c) sits on (0 when it is on
--- none — the caller falls back to the last corner). The cursor reads
--- as the FIRST byte of its character while a charwise region's right
--- edge is the LAST byte of its closing character, so the position is
--- extended to its whole character before matching.
local function corner_index(region, r, c)
  local line = vim.fn.getline(r) or ''
  if c >= 1 and c <= #line then
    local cc = char_col(line, c)
    local e = byte_col(line, cc + 1) - 1
    if e >= c then
      c = e
    end
  end
  for i, corner in ipairs(corners(region)) do
    if corner[1] == r and corner[2] == c then
      return i
    end
  end
  return 0
end

--- Re-select `region` with the cursor on corner `idx`. The anchor is put
--- where the selection starts and the mode key pressed there, then the
--- cursor is moved to the moving corner — the selection follows the
--- cursor, as in Visual mode itself. Never through the '</'> marks:
--- setpos() on them FAILS silently. Cursor positions via nvim_win_set_cursor,
--- which cannot fail quietly — except a BLOCK's corner, which can sit
--- past the end of its row (the hug pads rows as the block lands):
--- under virtualedit the cursor can be placed there, and the selection
--- follows — so a block is re-selected through fn.cursor() with
--- virtualedit on, and the option restored once the selection is made.
--- Ends in Visual mode, cursor on the moving corner.
---@param region MoveRegion
---@param idx integer
local function reselect(region, idx)
  local cs = corners(region)
  local cur = cs[idx] or cs[#cs]
  local opp = cs[#cs + 1 - idx] or cs[#cs] -- 1<->2; a block's 1<->4, 2<->3
  vim.cmd('normal! ' .. vim.keycode('<Esc>'))
  if region.mode == BLOCK then
    -- the session holds virtualedit on: fn.cursor can place the cursor
    -- past a row's end, and the blockwise selection keeps that corner
    vim.fn.cursor(opp[1], opp[2])
    vim.cmd('normal! ' .. MODEKEY[BLOCK])
    vim.fn.cursor(cur[1], cur[2])
  else
    vim.api.nvim_win_set_cursor(0, { opp[1], math.max(0, opp[2] - 1) })
    vim.cmd('normal! ' .. MODEKEY[region.mode])
    local rowlen = #(vim.api.nvim_buf_get_lines(0, cur[1] - 1, cur[1], false)[1] or '')
    vim.api.nvim_win_set_cursor(0, { cur[1], math.min(math.max(0, cur[2] - 1), rowlen > 0 and rowlen - 1 or 0) })
  end
end

--- The keys that move: gomove's four — the goto motions are
--- dispatched ahead of these in the loop.
local MOVE_KEYS = {
  h = true, j = true, k = true, l = true,
}

--- gomove's dispatch: V moves as lines; a charwise span that starts at
--- the line's left edge and covers several rows is lines too (gomove's
--- own rule — such a span reads as whole rows); everything else is the
--- rectangle of the corners.
local function as_lines(region)
  if region.mode == 'V' then
    return true
  end
  return region.mode == 'v' and region.r1 ~= region.r2 and region.c1 <= 1
end

--- One move of the session: `key` (one of MOVE_KEYS) by `n` units, on
--- the live buffer, through the ported gomove engine (the selection
--- must be live — and BLOCKWISE for the block ops; the caller sees to
--- both). Returns the updated region, or nil when the move could not
--- be made (nothing changed then).
---@param region MoveRegion
---@param key string
---@param n integer
---@return MoveRegion?
local function do_move(region, key, n)
  if key == 'j' or key == 'k' then
    local d = (key == 'j') and n or -n
    if as_lines(region) then
      local r1, r2 = gomove.line_vertical_move(region.r1, region.r2, d)
      if not r1 then
        return nil
      end
      region.r1, region.r2 = r1, r2
      return region
    end
    local r1, r2, c1, c2 = gomove.block_vertical_move(region.r1, region.r2, region.c1, region.c2, d)
    if not r1 then
      return nil
    end
    region.r1, region.r2, region.c1, region.c2 = r1, r2, c1, c2
    return region
  end
  local d = (key == 'l') and n or -n
  if region.mode == 'V' then
    local r1, r2 = gomove.line_horizontal_move(region.r1, region.r2, d)
    if not r1 then
      return nil
    end
    return region -- the rows stayed; the text inside them shifted
  end
  local r1, r2, c1, c2 = gomove.block_horizontal_move(region.r1, region.r2, region.c1, region.c2, d)
  if not r1 then
    return nil
  end
  region.r1, region.r2, region.c1, region.c2 = r1, r2, c1, c2
  return region
end

--- One hjkl-shaped leg of a move or a goto carry: gomove's block ops
--- cut a BLOCKWISE selection, so a charwise span is re-selected as the
--- rectangle of its corners first — gomove's own `g`<C-v>g`>` before
--- every block move. Returns the updated region, or nil.
---@param region MoveRegion
---@param key string 'h' 'j' 'k' or 'l'
---@param n integer
---@return MoveRegion?
local function leg(region, key, n)
  if region.mode ~= BLOCK and not as_lines(region) then
    reselect({ mode = BLOCK, r1 = region.r1, c1 = region.c1, r2 = region.r2, c2 = region.c2 }, 1)
  end
  return do_move(region, key, n)
end

--- One goto-shaped carry to an absolute place — rows first, then
--- columns, the two legs hjkl speak. `join0` tells whether an undo
--- entry to join onto already exists (a session's earlier moves, or
--- a caller that made one); the second leg joins onto the first, so
--- a carry is one undo entry. The region is updated in place;
--- returns whether anything moved.
---@param region MoveRegion
---@param row integer
---@param col integer
---@param join0 boolean
---@return boolean moved
local function carry_region(region, row, col, join0)
  local last = vim.fn.line('$')
  local t = math.max(1, math.min(row, last - (region.r2 - region.r1)))
  local dr = t - region.r1
  local dc = 0
  if region.mode ~= 'V' then
    dc = col - region.c1
  end
  local moved = false
  gomove.join = join0
  if dr ~= 0 then
    local nr = leg(region, dr > 0 and 'j' or 'k', math.abs(dr))
    if nr then
      region, moved = nr, true
    end
  end
  if dc ~= 0 then
    gomove.join = moved or join0
    local nr = leg(region, dc > 0 and 'l' or 'h', math.abs(dc))
    if nr then
      region, moved = nr, true
    end
  end
  return moved
end

--- The last occurrence of `ch` in `line` starting at byte column <=
--- `from` (plain text, whole characters).
---@param line string
---@param ch string
---@param from integer
---@return integer? byte col
local function rfind_plain(line, ch, from)
  local best
  local pos = 1
  while true do
    local s = line:find(ch, pos, true)
    if not s or s > from then
      break
    end
    best = s
    pos = s + 1
  end
  return best
end


--- The next word target past `edge`, the ROW-FIRST way the word
--- motions read a multi-row selection: the rows are scanned starting
--- from the cursor's own (`crow` — the first line, where the cursor
--- was), then the selection's rows top down; the first scanned row
--- that still has a target past the edge gives it — its SMALLEST, the
--- leftmost — so the walk does the first line's words to that line's
--- end and only then crosses onto the NEXT BIGGEST LINE: the next row
--- that still reaches past the edge, the selection's own
--- expanding-to-the-right shape, walking on until the right end of
--- the LONGEST line covered — its last word is the walk's last
--- target, past it the key is dead. `pat` speaks word starts or ends
--- (goto_carry's own patterns); all columns are 1-based bytes.
---@param pat string
---@param starts boolean word starts (w/W) when true, ends (e/E) when false
---@param edge integer the column the target must sit past
---@param r1 integer
---@param r2 integer
---@param crow integer the cursor's row — where the walk starts
---@return integer? column
local function word_target(pat, starts, edge, r1, r2, crow)
  local scan = { crow } -- the cursor's row first, then top down
  for r = r1, r2 do
    if r ~= crow then
      scan[#scan + 1] = r
    end
  end
  for _, r in ipairs(scan) do
    local line = vim.fn.getline(r) or ''
    local best
    local from = 0
    while true do
      -- s0/e0: 0-based bytes, e0 just past the word's last byte — so
      -- s0+1 is the word's first character and e0 its last, both
      -- 1-based the way the region speaks
      local _, s0, e0 = unpack(vim.fn.matchstrpos(line, pat, from))
      if not s0 or s0 < 0 then
        break -- this row's words are done
      end
      local hit = starts and (s0 + 1) or e0
      if hit > edge and (not best or hit < best) then
        best = hit
      end
      from = e0
    end
    if best then
      return best
    end
  end
  return nil
end


--- The goto motions — 0 $ gg G f t F T w e b W E B — read a target off
--- the buffer and turn it into the same two carries hjkl speak: rows
--- (dr) and columns (dc), each leg run through `leg`. Forward motions
--- bind the selection's RIGHT edge (f lands it ON the char, t just
--- short of its target — Vim's inclusive/exclusive truth), the
--- backward ones the LEFT (F on the char, T just past it), `0` the
--- left edge, gg/G the top/bottom rows. The word motions — w e and
--- their WORD twins W E — are LINE-WISE and ROW-FIRST: the cursor's
--- own line's words are walked before any other's, and a selection
--- that goes VERTICAL goes on to the NEXT BIGGEST LINE — the next row
--- that still reaches past the edge — walking all the way to the
--- right end of the longest line covered, past which the key is dead.
--- b is the backward
--- twin, right to left, and its walk has a FLOOR: the beginning of
--- the line — b keeps moving back until column 1, all the way to 0,
--- and past it is dead. On a charwise/blockwise selection the carry
--- is the slide (dr is 0); on a line selection (V) it is the COLUMN
--- shift — every line moves together by exact columns, the walking
--- edge the cursor row's own first word, and b's floor the full
--- dedent (every line to its own beginning). `read` supplies the
--- pending char (Esc or C-c aborts the input, not the mode).
--- Returns dr, dc and a message for the dead cases (dr nil; a
--- message of '' is a quiet dead key).
---@param region MoveRegion
---@param k string 'gg' 'G' '0' '$' 'f' 't' 'F' 'T' 'w' 'e' 'b' 'W' 'E' 'B'
---@param cnt integer the pending count
---@param read? fun(): string?
---@param crow? integer the cursor's row — where the word walk starts
---@return integer? dr
---@return integer dc
---@return string msg
local function goto_carry(region, k, cnt, read, crow)
  local r1, r2, c1, c2 = region.r1, region.r2, region.c1, region.c2
  local last = vim.fn.line('$')
  crow = math.max(r1, math.min(r2, crow or r1)) -- where the walk starts

  if k == 'gg' or k == 'G' then
    if k == 'G' and cnt == 0 then
      return last - r2, 0, '' -- the bottom flush: the last row to the last
    end
    local t = math.max(1, math.min(cnt > 0 and cnt or 1, last))
    return t - r1, 0, '' -- the top row lands on t
  end

  if k == '0' then
    if region.mode == 'V' then
      -- a line selection has no column to slide to; its 0 is the
      -- classic full dedent: every line to its own beginning, all the
      -- way to 0 — the column shift's own floor (b's last stop)
      local mi = 0
      for r = r1, r2 do
        mi = math.max(mi, vim.fn.indent(r))
      end
      if mi == 0 then
        return nil, 0, ''
      end
      return 0, -mi, ''
    end
    return 0, 1 - c1, ''
  end

  if k == '$' then
    if region.mode == 'V' then
      return nil, 0, 'a line selection has no right edge — j/k/gg/G move it'
    end
    local longest = 0
    for r = r1, r2 do
      longest = math.max(longest, #(vim.fn.getline(r) or ''))
    end
    if longest == 0 then
      return nil, 0, ''
    end
    return 0, longest - c2, ''
  end

  if k == 'f' or k == 't' then
    -- the char is read FIRST, even when the shape will refuse the
    -- motion — a pending char left unread would leak into the loop as
    -- an unknown key and cancel the session
    local ch = read and read() or nil
    if not ch or ch == '' or ch == '\27' or ch == '\3' then
      return nil, 0, '' -- the pending char let go: the mode stays
    end
    if region.mode == 'V' then
      return nil, 0, 'a line selection has no columns to find in'
    end
    local nth = cnt > 0 and cnt or 1
    local n = 0
    for r = r1, r2 do
      local line = vim.fn.getline(r) or ''
      local from = c2 + 1
      while from <= #line do
        local s, e = line:find(ch, from, true)
        if not s then
          break
        end
        n = n + 1
        if n == nth then
          -- f is inclusive (the right edge lands ON the char), t
          -- exclusive (just before it)
          return 0, (k == 'f') and (s - c2) or (s - 1 - c2), ''
        end
        from = e + 1
      end
    end
    return nil, 0, ('no %s%s past the selection'):format(nth > 1 and (nth .. 'th ') or '', ch)
  end

  if k == 'F' or k == 'T' then
    -- the backward twins: the char read FIRST the same way
    local ch = read and read() or nil
    if not ch or ch == '' or ch == '\27' or ch == '\3' then
      return nil, 0, '' -- the pending char let go: the mode stays
    end
    if region.mode == 'V' then
      return nil, 0, 'a line selection has no columns to find in'
    end
    local nth = cnt > 0 and cnt or 1
    local n = 0
    for r = r2, r1, -1 do -- backward: the bottom row up, each row right to left
      local line = vim.fn.getline(r) or ''
      local from = c1 - 1
      while from >= 1 do
        local s = rfind_plain(line, ch, from)
        if not s then
          break
        end
        n = n + 1
        if n == nth then
          -- F is inclusive (the left edge lands ON the char), T
          -- exclusive (just past it) — Vim's backward truth
          return 0, (k == 'F') and (s - c1) or (s + #ch - c1), ''
        end
        from = s - 1
      end
    end
    return nil, 0, ('no %s%s before the selection'):format(nth > 1 and (nth .. 'th ') or '', ch)
  end

  if k == 'w' or k == 'e' or k == 'W' or k == 'E' then
    -- the word motions, forward — w e and their WORD twins W E —
    -- LINE-WISE and ROW-FIRST: the targets are words of the
    -- selection's own rows (never a row the selection does not
    -- cover), and the row the CURSOR is on — the first line, where
    -- the cursor was — is walked before any other's: a vertical
    -- selection (several rows, V or <C-v> alike) moves forward by
    -- the words in the first line, and only after reaching its end
    -- goes on to the NEXT BIGGEST LINE — the next row that still
    -- reaches past the edge, the walk continuing from there, visual
    -- mode's own expanding-to-the-right shape — walking all the way
    -- to the RIGHT END of the LONGEST LINE covered: the longest
    -- row's last word is the last target, and past it the key is
    -- dead (a one-line selection reduces to its own row's words
    -- past the edge). On a
    -- charwise/blockwise selection the carry is the slide alone — dr
    -- is 0, a word never takes the selection to another row — and
    -- the RIGHT edge binds: w/W land it on the target's FIRST
    -- character (f's inclusive landing, a word's shape), e/E on its
    -- LAST (the same word's end when the edge sits inside it, Vim's
    -- `e` truth). On a line selection (V) the carry is the COLUMN
    -- shift: every line moves together and the words ride them, so
    -- the walking edge is the cursor row's own first word — it sits
    -- exactly on the last target it took — landing on each target in
    -- turn, the line advancing one word per press. A word is keyword
    -- characters, `iskeyword`'s own — a WORD is a non-blank run,
    -- `W`'s own truth, punctuation riding along; matchstrpos speaks
    -- both, its columns honest bytes. w/W count word STARTS only (a
    -- begun-mid-word run is not a word: the boundary pattern needs
    -- the text behind the match to tell, the way `w` from inside a
    -- word skips to the next one); e/E count ENDS, and a
    -- begun-mid-word run ends where the word does, which is `e`'s
    -- own truth
    local starts = (k == 'w' or k == 'W')
    local pat = (k == 'W' or k == 'E')
        and (starts and '\\S\\@<!\\S\\S*' or '\\S\\+')
      or (starts and '\\k\\@<!\\k\\k*' or '\\k\\+')
    local nth = cnt > 0 and cnt or 1
    local edge = c2
    if region.mode == 'V' then
      local line = vim.fn.getline(crow) or ''
      edge = line:find('%S') or 1 -- the cursor row's own first word
    end
    local e0 = edge
    local target
    for _ = 1, nth do -- the walk's own composition: one word a step
      target = word_target(pat, starts, edge, r1, r2, crow)
      if not target then
        break
      end
      edge = target
    end
    if target then
      return 0, target - e0, '' -- the walking edge lands ON it
    end
    return nil, 0, (starts and 'no word' or 'no word end')
      .. ' past the selection'
  end

  if k == 'b' or k == 'B' then
    -- the word motion, backward — LINE-WISE the same way: the words
    -- of the selection's own rows alone. BACKWARD is Vim's own too,
    -- RIGHT TO LEFT: the targets are the word STARTS before the
    -- walking edge, read from every row the selection covers, one
    -- target per distinct column, walked from the rightmost down —
    -- and the walk has a FLOOR: the beginning of the line. b keeps
    -- moving back until column 1 — all the way to 0, Vim's own `b`
    -- reaching the line's start the same way — and past it the key
    -- is dead. On a charwise or blockwise selection the LEFT edge
    -- binds (F's truth), landing ON the word's first character; on
    -- a line selection (V) the carry is the COLUMN shift, the
    -- walking edge the cursor row's own first word — and the floor
    -- there is the FULL dedent, every line taken to its own
    -- beginning, all the way to 0. B is the WORD twin (non-blank
    -- runs)
    local pat = (k == 'B') and '\\S\\@<!\\S\\S*' or '\\k\\@<!\\k\\k*'
    local nth = cnt > 0 and cnt or 1
    local edge, floor_dc
    if region.mode == 'V' then
      local line = vim.fn.getline(crow) or ''
      edge = line:find('%S') or 1 -- the cursor row's own first word
      -- the floor: the full dedent — every line to its own beginning
      -- (indent() speaks display columns, tabs and all, the way the
      -- column shift's own arithmetic does)
      local deepest = 0
      for r = r1, r2 do
        deepest = math.max(deepest, vim.fn.indent(r))
      end
      floor_dc = (deepest > 0) and (-deepest) or nil
    else
      edge = c1
      floor_dc = (c1 > 1) and (1 - c1) or nil
    end
    local cols = {} -- the distinct word starts before the edge
    for r = r1, r2 do
      local line = vim.fn.getline(r) or ''
      local from = 0
      while true do
        local _, s0, e0 = unpack(vim.fn.matchstrpos(line, pat, from))
        if not s0 or s0 < 0 then
          break
        end
        if s0 + 1 < edge then
          cols[s0 + 1] = true
        end
        from = e0
      end
    end
    local sorted = {}
    for c in pairs(cols) do
      sorted[#sorted + 1] = c
    end
    table.sort(sorted)
    if nth <= #sorted then
      local s1 = sorted[#sorted - nth + 1] -- the line read backwards
      return 0, s1 - edge, '' -- the walking edge lands ON it
    end
    if floor_dc then
      return 0, floor_dc, '' -- the floor: all the way to 0
    end
    return nil, 0, 'no word before the selection'
  end

  return nil, 0, '' -- unreachable; the keys are dispatched above
end

--- The move session: entered on a Visual selection (x-mode <C-m>).
--- Runs a getchar() loop that answers the gomove keys with the ported
--- gomove operations and the goto motions with their carries. Three
--- ways out: <C-t> keeps the moves and drops the selection; <C-x> hands
--- the region to the exchange (or completes one already waiting) — and
--- first UNDOES the session's moves when there were any, the selection
--- restored to where it was entered: the exchange trades what was
--- SELECTED, not where a session carried it; everything else — <Esc>,
--- <C-c>, an interrupt, or any key the mode does not know — is a
--- cancellation: the buffer is taken
--- back to the state it had at entry with ONE `:undo {seq}` — the undo
--- sequence number the session started from, remembered before the
--- first move — and the cursor returns to where the mode was entered.
--- Every move but the first is undojoin-ed onto the one before, so a
--- user's `u` after a KEPT session takes the whole session back too.
--- The screen cursor stays in the buffer for the whole ride — every
--- hint is flushed with the cursor back at its buffer position, and
--- the waits read their keys with it kept there.
---@param buf integer
---@param region MoveRegion
---@param home {[1]: integer, [2]: integer} where a cancellation returns the cursor
---@param corner integer the region corner the cursor moves
local function core(buf, region, home, corner)
  -- Keys the user typed AHEAD of the mode live in Vim's typeahead, and
  -- nvim_feedkeys('x') would run them as raw Visual keys — past this
  -- loop, its counts and its endings. They are pulled out first and
  -- handed to the loop in order instead, so a fast `jjj` is three moves
  -- the way a slow one is.
  local queue = {} ---@type string[]
  local function read_key()
    if #queue > 0 then
      return table.remove(queue, 1)
    end
    return read_char() -- the mode's own read: the SCREEN cursor stays
    -- in the buffer while the wait goes on, never on the message line
  end

  local function drain()
    while #queue < 128 do
      local ok, head = pcall(vim.fn.getcharstr, 1)
      if not ok or head == '' or head == nil or head == 0 then
        break
      end
      queue[#queue + 1] = vim.fn.getcharstr() -- consume what the peek saw
    end
  end

  local function show()
    if M.options.hint ~= false then
      local k = {
        c = M.options.keys.confirm and keyname(M.options.keys.confirm) or '',
        x = M.options.keys.exchange and keyname(M.options.keys.exchange) or '',
      }
      local parts = {
        { 'move: ', 'Comment' },
        { 'h j k l  0 $ gg G f t F T w e b W E B  [count]', 'None' },
      }
      if k.c ~= '' then
        parts[#parts + 1] = { '  ' .. k.c .. ' keep', 'Comment' }
      end
      parts[#parts + 1] = { '  Esc undo', 'Comment' }
      if k.x ~= '' then
        parts[#parts + 1] = { '  ' .. k.x .. ' exchange', 'Comment' }
      end
      echo(parts) -- one screen line, never a "Press ENTER" under the loop
    end
    cursor_home() -- the screen cursor back in the buffer, on the
    -- selection — never parked on the message line under the hint
  end

  -- a block's corner can sit past the end of its row (the hug pads
  -- rows as the block lands): virtualedit carries the cursor there, and
  -- the selection keeps that corner only while the option is ON — so it
  -- stays on for the whole session and goes back to the user's value at
  -- every exit
  local old_ve = vim.o.virtualedit
  vim.o.virtualedit = 'all'

  reselect(region, corner)
  show()

  local confirm = M.options.keys.confirm and vim.keycode(M.options.keys.confirm) or '\255'
  local exchange = M.options.keys.exchange and vim.keycode(M.options.keys.exchange) or '\254'
  local toggle = M.options.keys.mode and vim.keycode(M.options.keys.mode) or nil
  local changed = false
  local count = 0
  local outcome = 'cancel' -- 'confirm' | 'exchange1' | 'exchange2' | 'cancel'
  local xch_rewound = false -- C-x after moves: they are undone first

  -- where the session starts from, in undo steps: a cancellation is one
  -- `:undo {seq}` back to this number — exact from any depth, never past
  -- the entry — and the SNAPSHOT below is the text truth that undo's
  -- own landing (which proved able to come up garbled from inside a
  -- mapping, E438's territory) cannot contradict
  local seq0 = vim.fn.undotree().seq_cur
  local snap = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local region0 = vim.deepcopy(region) -- the entry shape: what an undo
  -- restores the selection to — the exchange's areas are the SELECTED
  -- text, not where a session carried it

  -- the session's own undo entry: without the sync the moves disappear
  -- into whatever change came before
  vim.cmd('let &undolevels = &undolevels')

  --- Land a goto-shaped carry: the dead cases echo their message (a
  --- quiet one just re-shows the hint), the live ones run the two legs
  --- the goto motions speak — rows first, then the slide. Returns
  --- whether anything moved (nil for the dead cases).
  local function land(dr, dc, msg)
    if not dr then
      if msg and msg ~= '' then
        echo({ { 'move: ' .. msg, 'WarningMsg' } })
        cursor_home()
      else
        show()
      end
      return nil
    end
    gomove.join = changed
    local moved = false
    if dr ~= 0 then -- the vertical leg first: cut and paste
      local nr = leg(region, dr > 0 and 'j' or 'k', math.abs(dr))
      if nr then
        region, moved = nr, true
      end
    end
    if dc ~= 0 then -- then the slide
      if region.mode == 'V' then
        -- a line selection's horizontal goto carry is the COLUMN shift:
        -- the word walk's carry (and 0's full dedent) — every line
        -- moves together by exact columns, a row never losing text
        gomove.join = moved or changed
        if gomove.line_indent_cols(region.r1, region.r2, dc) then
          moved = true
        end
      else
        gomove.join = moved or changed -- the slide joins the landing
        local nr = leg(region, dc > 0 and 'l' or 'h', math.abs(dc))
        if nr then
          region, moved = nr, true
        end
      end
    end
    if moved then
      changed = true
    end
    reselect(region, corner)
    show()
    return moved
  end

  while true do
    local key = read_key()
    if not key then
      break -- interrupted (<C-c>): a cancellation
    end
    if key == confirm then
      outcome = 'confirm'
      break
    elseif key == exchange then
      -- the second press completes a waiting exchange; the first marks.
      -- Moves made first are UNDONE by the press — the exchange trades
      -- what was SELECTED, not where a session carried it (the rewind
      -- runs in the outcome below, the region restored to its entry
      -- shape before anything is marked or swapped)
      local pending = xch_region()
      outcome = (pending and XCH.buf == buf) and 'exchange2' or 'exchange1'
      xch_rewound = changed
      break
    elseif toggle and key == toggle then
      -- the old prefix spelling survives as an alias: <C-m><C-t> keeps,
      -- <C-m><C-x> exchanges. Anything else after it cancels.
      local k2 = read_key()
      if k2 == confirm then
        outcome = 'confirm'
        break
      elseif k2 == exchange then
        local pending = xch_region()
        outcome = (pending and XCH.buf == buf) and 'exchange2' or 'exchange1'
        xch_rewound = changed
        break
      elseif k2 then
        break -- a key the mode does not know: leaving is a cancellation
      else
        break -- interrupted (<C-c>): a cancellation
      end
    elseif key == '\27' or key == '\3' then
      break -- the plain cancellations
    elseif key == 'o' or key == 'O' then
      -- Vim's own corner keys: the cursor walks to another corner, the
      -- selection does not move — which corner moves is now that one
      count = 0
      drain()
      vim.api.nvim_feedkeys(key, 'x', false)
      if vim.fn.mode() ~= region.mode then
        break
      end
      local r, c = unpack(vim.api.nvim_win_get_cursor(0))
      local idx = corner_index(region, r, c + 1) -- nvim_win_get_cursor: 0-based col
      if idx > 0 then
        corner = idx
      end
      reselect(region, corner)
      show()
    elseif key:match('^%d$') and (count > 0 or key ~= '0') then
      count = math.min(count * 10 + tonumber(key), 999)
      if M.options.hint ~= false then
        echo({ { ('move: %d_'):format(count), 'None' } })
        cursor_home()
      end
    elseif key == 'g' or key == 'G' or key == '0' or key == '$'
        or key == 'f' or key == 't' or key == 'F' or key == 'T'
        or key == 'w' or key == 'e' or key == 'b'
        or key == 'W' or key == 'E' or key == 'B' then
      -- the goto motions: a target read off the buffer, carried as the
      -- same rows and columns hjkl speak — the finds take a char, the
      -- word motions walk the selection's rows ROW-FIRST (the
      -- cursor's line's words first, then the next biggest line, all
      -- the way to the right end of the longest line; b back to the
      -- line's own beginning, a line selection carried by columns)
      drain()
      local k, stay = key, false
      if key == 'g' then
        local k2 = read_key()
        if k2 == 'g' then
          k = 'gg'
        elseif k2 == '\27' or k2 == '\3' then
          stay = true -- the pending g let go: the mode stays
        else
          break -- a key the mode does not know: leaving is a cancellation
        end
      end
      if stay then
        count = 0
        show()
      else
        -- the cursor's row is where the word walk starts (the first
        -- line, re-read live every press — o/O re-anchor it)
        local crow = vim.api.nvim_win_get_cursor(0)[1]
        local dr, dc, msg = goto_carry(region, k, count, read_key, crow)
        count = 0
        land(dr, dc, msg)
      end
    elseif not MOVE_KEYS[key] then
      break -- a key the mode does not know: leaving is a cancellation
    else
      local n = (count > 0) and count or 1
      count = 0
      drain() -- typed-ahead keys must not run as raw Visual keys
      gomove.join = changed
      local nr = leg(region, key, n) -- re-selects a charwise span as its
      -- corner rectangle first, gomove's own `g`<C-v>g`>`
      if nr then
        region = nr
        changed = true
      end
      reselect(region, corner)
      show()
    end
  end

  -- out of the loop: the keys the loop drained from the typeahead but
  -- never consumed are not the mode's to eat — they belong to whatever
  -- comes after it, so they go back in. Visual goes too, always — a
  -- kept move ends in normal mode on what moved, an exchange needs
  -- normal mode to pick the second area, a cancellation has nothing to
  -- keep selected
  if #queue > 0 then
    vim.api.nvim_feedkeys(table.concat(queue), 'm', false)
  end

  vim.cmd('normal! ' .. vim.keycode('<Esc>'))
  vim.o.virtualedit = old_ve
  if M.options.hint ~= false then
    -- the hint goes WITHOUT a 'Press ENTER': the session fed keys as if
    -- typed (the jumps, the carries), and any :echo-style output while
    -- their output is pending parks the mapping under a hit-enter
    -- prompt. :redraw first — a screen command, no output — drops that
    -- pending state; the empty echo line then wipes the hint cleanly
    pcall(vim.cmd, 'redraw')
    pcall(vim.api.nvim_echo, { { '' } }, true, {})
  end

  if (outcome == 'exchange1' or outcome == 'exchange2') and xch_rewound then
    -- C-x with moves made: THE MOVES ARE UNDONE — the same one-step
    -- rewind a cancellation is, `:undo {seq}` back to the entry's own
    -- sequence number — and the selection goes back to the shape it
    -- was entered with, the exchange trading what was SELECTED and
    -- not where the session carried it
    pcall(vim.cmd, 'undo ' .. seq0)
    region = vim.deepcopy(region0)
  end

  if outcome == 'exchange2' then
    -- the SECOND area (restored to its entry shape when moves were
    -- made): the two areas swap
    local pending = xch_region()
    local r2start = { region.r1, region.c1 }
    xch_clear()
    local err = pending and xch_swap(buf, pending, region)
    pcall(vim.fn.setpos, '.', { 0, r2start[1], math.max(r2start[2], 1), 0 })
    if err then
      echo({ { 'exchange: ' .. err, 'WarningMsg' } })
    else
      echo({ { 'exchanged', 'Comment' } })
    end
  elseif outcome == 'exchange1' then
    -- the FIRST area (a pending one from another buffer is dropped —
    -- its buffer may even be gone; this selection is the new start);
    -- after moves it is the RESTORED selection — the entry shape, the
    -- moves undone by the press that started this
    if XCH.buf and XCH.buf ~= buf then
      xch_clear()
    end
    xch_arm(buf, region)
    -- park the cursor on the marked area's first corner — a predictable
    -- place for the motions that pick the second area
    pcall(vim.fn.setpos, '.', {
      0,
      region.r1,
      region.mode == 'V' and 1 or math.max(region.c1, 1),
      0,
    })
    echo({
      { (xch_rewound and 'moves undone — ' or '')
          .. 'exchange: first area marked — select the next one, ', 'None' },
      { keyname(M.options.keys.exchange) .. ' or '
          .. keyname(M.options.keys.exchange) .. 'C-h/j/k/l swaps, ', 'Comment' },
      { 'Esc cancels', 'Comment' },
    })
  elseif outcome == 'confirm' then
    -- the moves stay; the cursor sits on the region's first corner
    pcall(vim.fn.setpos, '.', { 0, region.r1, math.max(region.c1, 1), 0 })
  else
    -- cancellation: everything the session did goes, in one step — the
    -- rewind to the sequence number the session started from, exact
    -- from any depth, never past the entry — and the cursor returns
    -- to where the mode was entered
    if changed then
      pcall(vim.cmd, 'undo ' .. seq0)
    end
    pcall(vim.fn.setpos, '.', { 0, home[1], home[2], 0 })
    -- a pending exchange on this buffer is cancelled with it
    if XCH.buf == buf then
      xch_clear()
      echo({ { 'exchange cancelled', 'Comment' } })
    end
  end
end

--- x-mode entry: the selection is live — read it and carry it.
function M._session()
  local buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not vim.bo[buf].modifiable then
    vim.notify('[gliter] move: the buffer is not modifiable', vim.log.levels.WARN)
    return
  end
  local vmode = vim.fn.mode()
  if vmode ~= 'v' and vmode ~= 'V' and vmode ~= BLOCK then
    return
  end
  local p1, p2 = vim.fn.getpos('v'), vim.fn.getpos('.')
  if p1[2] == 0 or p2[2] == 0 then
    return
  end
  local nlines = vim.api.nvim_buf_line_count(buf)
  local region = normalize(vmode, p1[2], p1[3], p2[2], p2[3])
  region.r1 = math.min(region.r1, nlines)
  region.r2 = math.min(region.r2, nlines)
  if region.mode == 'v' then
    local last = vim.api.nvim_buf_get_lines(buf, region.r2 - 1, region.r2, false)[1] or ''
    if region.c2 > #last then
      region.c2 = #last
    end
  end
  local corner = corner_index(region, p2[2], p2[3])
  core(buf, region, { p2[2], p2[3] }, corner > 0 and corner or #corners(region))
end

---------------------------------------------------------------------------
-- the jumps — C-m o/i (the old C-o/C-i spellings too), this file's
-- trail walked alone
---------------------------------------------------------------------------

--- Land on a jump entry, the cursor on the location: the entry's line
--- and column clamped to the file as it stands now (a jump list
--- remembers where jumps happened, and Vim adjusts its own entries as
--- the text changes — the walk lands on what the entry says, inside
--- the file's current shape).
local function jump_land(e)
  local lnum = math.max(1, math.min(e.lnum, vim.fn.line('$')))
  local text = vim.fn.getline(lnum) or ''
  local col = math.max(0, math.min(e.col or 0, math.max(0, #text - 1)))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, col })
end

--- The walk on VIM'S OWN JUMP LIST — only the current file's entries:
--- a jump that went to another file is skipped, never taken, the
--- file's trail walked alone (the list of a session that went
--- file1 > file2 > file1 has file2's visits in it; on file1, the walk
--- steps on file1's positions only). The step itself is NATIVE: the
--- entries between the walk and its target are counted — foreign
--- files included, they are passed over, never taken — and that many
--- C-o/C-i are fed as if typed, so the CURSOR lands the way it always
--- lands, Vim's own pointer walks its own list (a jump made inside a
--- mapping records nothing — the fed key jumps OUTSIDE the mapping,
--- where everything records: the first step back leaves the newest
--- position remembered the native way, and a step forward returns to
--- it; no phantoms either — the list cleans itself exactly when and
--- how Vim cleans it). `dir` is -1 for <C-o> (older) and 1 for <C-i>
--- (newer), `n` this-file locations at a time, Vim's all-or-nothing
--- count: fewer than n in the direction and nothing moves.
local function jump_file(n, dir)
  local list, cur = unpack(vim.fn.getjumplist())
  if type(list) ~= 'table' then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  -- the nearest n-th entry of THIS file in the walk's direction,
  -- counting every entry it must pass over — foreign files included
  local nth, i = 0, cur -- cur is 0-based; == #list is the virtual
  -- newest, the position of the last jump, not an entry
  while nth < n do
    i = i + dir
    if i < 0 or i >= #list then
      break
    end
    local e = list[i + 1]
    if type(e) == 'table' and e.bufnr == buf and e.lnum and e.lnum > 0 then
      nth = nth + 1
    end
  end
  if nth < n then
    echo({
      { 'move: ', 'Comment' },
      {
        (#list == 0 and 'the jump list is empty')
          or (dir < 0 and 'no older jump in this file' or 'no newer jump in this file'),
        'WarningMsg',
      },
    })
    return
  end
  -- the distance in ENTRIES — foreign ones ride inside it, passed
  -- over without their buffers ever being taken. Fed 'n' (never
  -- remapped): <C-i> is the Tab byte, and a user's normal-mode <Tab>
  -- map — buffer switching, window walking, anything — would eat the
  -- walk's step and the jump never happens (C-o has no such twin, which
  -- is why only C-i ever broke); 'n' keeps the fed key native, the
  -- jump Vim's own, whoever owns Tab. 'x' executes it ON THE SPOT:
  -- the n-mode's loop is still holding the mapping, and keys left in
  -- the typeahead would instead be read back by the loop's own
  -- getchar as if the user had pressed them — the loop drains the
  -- typeahead into its queue first, so the 'x' pass runs the fed jump
  -- alone
  vim.api.nvim_feedkeys(tostring(math.abs(i - cur))
    .. (dir < 0 and vim.keycode('<C-o>') or vim.keycode('<C-i>')), 'nx', false)
end

-- A separate jump list per file (jumps.scope = 'own'): Vim's own jump
-- records — the positions jumps leave — bucketed per file as they
-- appear, every file's list its own. Vim keeps one list per window, a
-- hundred entries shared between every file the window visited, the
-- oldest rotated away; a file's own list keeps its jumps whatever the
-- window does elsewhere, and survives the file's closing (the list
-- lives under the file's name; reopening the file finds it again).
-- The lists live in memory — a session's worth, not shada's forever.
local OWN = { lists = {}, seen = {} }

--- The key a file's own list lives under: the file's name when it has
--- one, the buffer number when it does not.
local function own_key(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= '' then
    return name
  end
  return '#' .. buf
end

--- Bucket Vim's new jump records into their files' lists — the
--- records this window's list gained since the last look. A record
--- lands in the list of the file it happened in, in Vim's own order;
--- a list that gained an entry stands at its newest end, Vim's way
--- (a new jump makes the newest position where you are). A position
--- already in a list is not kept again — a revisit walks to the place
--- either way, once is enough to find it.
local function own_sync()
  local win = vim.api.nvim_get_current_win()
  local list = vim.fn.getjumplist()
  if type(list) ~= 'table' or type(list[1]) ~= 'table' then
    return
  end
  local seen = OWN.seen[win] or {}
  local max = 100
  if type(M.options.jumps) == 'table' and tonumber(M.options.jumps.max) then
    max = math.max(1, math.floor(tonumber(M.options.jumps.max)))
  end
  for _, e in ipairs(list[1]) do
    if type(e) == 'table' and e.bufnr and e.bufnr > 0 and e.lnum and e.lnum > 0 then
      local m = e.bufnr .. ':' .. e.lnum .. ':' .. e.col
      if not seen[m] then
        seen[m] = true
        local key = own_key(e.bufnr)
        local L = OWN.lists[key]
        if not L then
          L = { list = {}, pos = 1 }
          OWN.lists[key] = L
        end
        L.list[#L.list + 1] = { e.lnum, e.col or 0 }
        if #L.list > max then
          table.remove(L.list, 1) -- the oldest rotated away, Vim's way
          L.pos = math.max(1, L.pos - 1)
        end
        L.pos = #L.list + 1 -- the list's newest end, standing there
      end
    end
  end
  OWN.seen[win] = seen
end

--- The walk on the FILE'S OWN list — the same shape as the walk on
--- Vim's: `n` steps at a time, older (<C-o>) or newer (<C-i>), every
--- step a landing (the entry clamped to the file's current shape).
--- The file's place in its own list is only the walk's to move: jumps
--- elsewhere leave it exactly where it was, and the file's next jump
--- stands it at the newest end again.
local function jump_own(n, dir)
  own_sync()
  local L = OWN.lists[own_key(vim.api.nvim_get_current_buf())]
  if not L or #L.list == 0 then
    echo({ { 'move: no jumps in this file yet', 'WarningMsg' } })
    return
  end
  local target = L.pos + dir * n
  if target < 1 or target > #L.list then
    echo({
      { 'move: ', 'Comment' },
      {
        dir < 0 and 'no older jump in this file' or 'no newer jump in this file',
        'WarningMsg',
      },
    })
    return
  end
  jump_land({ lnum = L.list[target][1], col = L.list[target][2] })
  L.pos = target
end

--- C-m C-o / C-m C-i — the walk, on Vim's own jump list (only this
--- file's entries) or on the file's own list, as jumps.scope says.
--- `dir` is -1 for the back key and 1 for the forward one.
M._jump = function(dir, n0)
  local n = math.max(1, n0 or vim.v.count)
  if type(M.options.jumps) == 'table' and M.options.jumps.scope == 'own' then
    jump_own(n, dir)
  else
    jump_file(n, dir)
  end
end

--- n-mode <C-m> — THE MODE (the mapping is a <Cmd> that lands here).
--- A getchar() loop, the visual session's own shape: C-h C-j C-k C-l
--- — the Ctrl is ON — transpose the ADJACENT words in that direction
--- — ONCE, and the mode is done with it — while C-o/C-i walk THIS
--- FILE'S jump trail, every press another step, the keys mixed
--- freely (C-i C-o C-o steps forward one and back two), the cursor
--- landing on each jump. [count] works typed before <C-m> or
--- between the mode's keys. The old spelling — <C-t> before the
--- direction — still works, prefix and all; the plain h j k l o i
--- are REPLACED, not aliased (C-m C-o is not the same as C-m o), a
--- plain letter a key the mode does not know. <Esc> and <C-c> leave
--- quietly; anything else — a letter, an operator — is let go with a
--- short notice (the mode spells its family, nothing else). Buffers
--- whose <CR> is their own never see the mode: netrw's open, the
--- quickfix's select and help's follow are buffer-local <CR> maps,
--- and a local map beats a global one — Enter keeps opening what it
--- always opened.
function M._nmode()
  -- keys the user typed AHEAD live in Vim's typeahead and are pulled
  -- out into a queue first (core()'s own dance): a jump is FED as
  -- native keys and executed on the spot, and anything still sitting
  -- in the typeahead at that moment would run with them as raw
  -- normal keys — the queue keeps them the mode's instead
  local queue = {} ---@type string[]
  local function read_key()
    if #queue > 0 then
      return table.remove(queue, 1)
    end
    return read_char() -- the mode's own read: the SCREEN cursor stays
    -- in the buffer while the wait goes on — on the jump o/i just
    -- landed on, never on the message line under the hint
  end
  local function drain()
    while #queue < 128 do
      local ok, head = pcall(vim.fn.getcharstr, 1)
      if not ok or head == '' or head == nil or head == 0 then
        break
      end
      queue[#queue + 1] = vim.fn.getcharstr() -- consume what the peek saw
    end
  end
  local function show()
    if M.options.hint ~= false then
      echo({
        { 'move: ', 'Comment' },
        { 'C-h C-j C-k C-l transpose  C-o/C-i jump (repeatable)  [count]', 'None' },
        { '  Esc done', 'Comment' },
      })
    end
    cursor_home() -- the screen cursor back in the buffer — on the
    -- jump, on the text — never parked on the message line
  end
  -- the mode's keys are spelled with the Ctrl ON: C-h C-j C-k C-l
  -- transpose, C-o/C-i walk the jumps. The plain h j k l o i are
  -- REPLACED, not aliased — C-m C-o is not the same as C-m o — a
  -- plain letter is a key the mode does not know, let go the way
  -- anything else is (the old <C-t>{dir} spelling still transposes,
  -- prefix and all)
  local dkeys = {
    [vim.keycode('<C-h>')] = 'h', [vim.keycode('<C-j>')] = 'j',
    [vim.keycode('<C-k>')] = 'k', [vim.keycode('<C-l>')] = 'l',
  }
  local ctrlt = vim.keycode('<C-t>')
  local ctrlo = vim.keycode('<C-o>')
  local ctrli = vim.keycode('<C-i>')
  local count = tonumber(vim.v.count) or 0
  show()
  while true do
    local key = read_key()
    if not key then
      break -- interrupted (<C-c>): done
    elseif key == '\27' or key == '\3' then
      break -- the plain exits
    elseif dkeys[key] then
      -- transpose the adjacent words in this direction, ONCE: the
      -- trade made, the mode is done — a second trade takes another
      -- <C-m> (the old <C-t>{dir} spelling works the same)
      local n = (count > 0) and count or 1
      count = 0
      M._transpose(n, dkeys[key])
      break
    elseif key == ctrlo or key == ctrli then
      -- the jump walk: C-o back, C-i forward — repeatable, mixed
      -- freely (the cursor lands on each jump)
      local n = (count > 0) and count or 1
      count = 0
      drain() -- typed-ahead keys must not run with the fed jump
      M._jump(key == ctrlo and -1 or 1, n)
      show()
    elseif key == ctrlt then
      -- the old spelling: C-t then the direction transposes too
      local d = read_key()
      if d == 'h' or d == 'j' or d == 'k' or d == 'l' then
        local n = (count > 0) and count or 1
        count = 0
        M._transpose(n, d)
        break
      elseif not d or d == '\27' or d == '\3' then
        count = 0
        if not d then
          break -- interrupted while the direction was read
        end
        show() -- the direction let go: the mode stays (f/t's own rule)
      else
        -- a key the mode does not know after C-t: done, with a notice
        echo({ { 'move: C-t takes a direction — h j k l', 'Comment' } })
        break
      end
    elseif key:match('^%d$') and (count > 0 or key ~= '0') then
      count = math.min(count * 10 + tonumber(key), 999)
      if M.options.hint ~= false then
        echo({ { ('move: %d_'):format(count), 'None' } })
        cursor_home()
      end
    else
      -- a key the mode does not know: leaving, with a short notice
      echo({ { 'move: C-h C-j C-k C-l transposes, C-o/C-i jump — anything else is let go', 'Comment' } })
      break
    end
  end
  -- the keys the loop drained but never consumed are not the mode's to
  -- eat — they belong to whatever comes after it
  if #queue > 0 then
    vim.api.nvim_feedkeys(table.concat(queue), 'm', false)
  end
  if M.options.hint ~= false then
    -- the hint goes WITHOUT a 'Press ENTER': the walk fed <C-o>/<C-i>
    -- as if typed, and any :echo-style output while that output is
    -- pending parks the loop's exit under a hit-enter prompt (the
    -- message machinery still owes the user an acknowledgement). :redraw
    -- first — a screen command, no output — drops the pending state; the
    -- empty echo line then wipes the hint cleanly
    pcall(vim.cmd, 'redraw')
    pcall(vim.api.nvim_echo, { { '' } }, true, {})
  end
end

--- <C-m>{C-h C-j C-k C-l} — TRANSPOSE WORDS, Emacs' M-t with Vim's own
--- words, in a DIRECTION: the word at the cursor trades places with
--- the ADJACENT word the direction names — `l` the one after it
--- (Emacs' own M-t), `h` the one before, `j` the word below, `k` the
--- word above (the old <C-m><C-t>{dir} spelling works the same).
--- 'iskeyword' decides what a word is, the way `w` does,
--- so in `foo(bar, baz)` the cursor on `bar` and `l` is
--- `foo(baz, bar)`: the args trade places, the punctuation does not
--- move. On a gap — whitespace, a comma — the words AROUND it are the
--- pair (Emacs' rule), `h` and `l` reading the same pair from either
--- side; `j`/`k` take the word whose span sits nearest the cursor
--- word's column on the next line that has words (blank lines
--- crossed, the way `w` crosses them). [count] bubbles the word along
--- in that direction: the swap repeats, the cursor riding the word.
--- The cursor ends on the word that moved — the one the key started
--- on. The text between the two words never changes; only the words
--- trade places, the whitespace between them staying exactly what it
--- was. The whole transpose is one undo entry.
---@param n0? integer the count ([count] bubbles the word along)
---@param dir? 'h'|'j'|'k'|'l' the adjacent word to trade with (default 'l')
M._transpose = function(n0, dir)
  local buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
    vim.notify('[gliter] move: the buffer is not modifiable', vim.log.levels.WARN)
    return
  end
  local n = math.max(1, n0 or vim.v.count)
  dir = (dir == 'h' or dir == 'j' or dir == 'k') and dir or 'l'
  -- the words are found with Vim's own machinery — searchpos and
  -- matchend, both byte-honest and both fluent in 'iskeyword'. A word's
  -- first char is a keyword char no keyword char precedes; the backward
  -- search takes it from ON a word (the word's own start) or from a gap
  -- (the last word before it), and never wraps around the buffer
  local WSTART = '\\k\\@<!\\k'
  -- the words of a line as {start, end} byte spans, 1-based, the end
  -- inclusive
  local function line_words(r)
    local out = {}
    local line = vim.fn.getline(r) or ''
    local from = 0
    while true do
      local _, s0, e0 = unpack(vim.fn.matchstrpos(line, '\\k\\+', from))
      if not s0 or s0 < 0 then
        break
      end
      out[#out + 1] = { s0 + 1, e0 }
      from = e0
    end
    return out
  end
  -- the word on the next line that has any (`step` +1 for down, -1 for
  -- up, blank and word-less lines crossed) whose span sits nearest
  -- `col`; ties go to the left one. {line, start, end}, or nil
  local function nearest_word(from, col, step)
    local last = vim.fn.line('$')
    local r = from + step
    while r >= 1 and r <= last do
      local words = line_words(r)
      if #words > 0 then
        local best, bestd
        for _, w in ipairs(words) do
          local d = col < w[1] and (w[1] - col)
            or (col > w[2] and (col - w[2]) or 0)
          if not bestd or d < bestd then
            best, bestd = w, d
          end
        end
        return { r, best[1], best[2] }
      end
      r = r + step
    end
    return nil
  end
  local save = vim.api.nvim_win_get_cursor(0)
  local done = 0
  -- the transpose's own undo entry, the sessions' fresh-start trick
  vim.cmd('let &undolevels = &undolevels')
  for _ = 1, n do
    -- the pair, a before b in the buffer, and RIDE — the member the
    -- cursor ends on (the word that moved: a's text lands where b
    -- began, b's where a did):
    --   l: a = the word at the cursor (or the last before it),
    --      b = the first word after a          — the cursor rides a
    --   h: b = the word at the cursor (or the first at/after it),
    --      a = the last word before b          — the cursor rides b
    --   j: a = the word at the cursor (or the last before it),
    --      b = the nearest word below          — the cursor rides a
    --   k: b = the word at the cursor (or the first at/after it),
    --      a = the nearest word above          — the cursor rides b
    local a, b, ride
    local dead = 'no word to transpose'
    if dir == 'l' then
      a = vim.fn.searchpos(WSTART, 'bcnW')
      if a[1] ~= 0 then
        local ea = vim.fn.matchend(vim.fn.getline(a[1]) or '', '\\k\\+', a[2] - 1)
        if ea >= a[2] then
          vim.api.nvim_win_set_cursor(0, { a[1], ea }) -- just past a (0-based)
          b = vim.fn.searchpos('\\k\\+', 'nW')
          dead = 'no next word to transpose with'
          ride = 'a'
        end
      end
    elseif dir == 'h' then
      -- b: the word at the cursor, or the first at/after it — a gap
      -- reads the words AROUND it, the same pair `l` reads
      b = vim.fn.searchpos('\\k\\+', 'cnW')
      if b[1] == 0 then
        -- nothing at/after the cursor: the last word before it is b
        b = vim.fn.searchpos(WSTART, 'bcnW')
      end
      if b[1] ~= 0 then
        -- a: the last word that ends before b starts, crossing lines
        -- the way `b` does — searched from just before b's first byte
        if b[2] > 1 then
          vim.api.nvim_win_set_cursor(0, { b[1], b[2] - 2 })
        elseif b[1] > 1 then
          local plen = #(vim.fn.getline(b[1] - 1) or '')
          vim.api.nvim_win_set_cursor(0, { b[1] - 1, math.max(0, plen - 1) })
        end
        a = vim.fn.searchpos(WSTART, 'bcnW')
        dead = 'no previous word to transpose with'
        ride = 'b'
      end
    elseif dir == 'j' then
      a = vim.fn.searchpos(WSTART, 'bcnW')
      if a[1] ~= 0 then
        b = nearest_word(a[1], a[2], 1)
        dead = 'no word below to transpose with'
        ride = 'a'
      end
    else -- 'k'
      b = vim.fn.searchpos('\\k\\+', 'cnW')
      if b[1] == 0 then
        b = vim.fn.searchpos(WSTART, 'bcnW')
      end
      if b[1] ~= 0 then
        a = nearest_word(b[1], b[2], -1)
        dead = 'no word above to transpose with'
        ride = 'b'
      end
    end
    if not a or not b or a[1] == 0 or b[1] == 0 then
      echo({ { 'move: ' .. dead, 'WarningMsg' } })
      break
    end
    local la = vim.fn.getline(a[1]) or ''
    local ea = vim.fn.matchend(la, '\\k\\+', a[2] - 1)
    if ea < a[2] then
      break -- an unreadable end: no honest word here
    end
    local lb = vim.fn.getline(b[1]) or ''
    local eb = vim.fn.matchend(lb, '\\k\\+', b[2] - 1)
    if eb < b[2] then
      break
    end
    -- the trade: A's text and B's text exchange IN PLACE — everything
    -- around them (the words before and after on both lines, the
    -- indentation, the punctuation) staying exactly what it was
    local ta = la:sub(a[2], ea)
    local tb = lb:sub(b[2], eb)
    local ok
    if a[1] == b[1] then
      ok = pcall(vim.api.nvim_buf_set_lines, buf, a[1] - 1, a[1], false, {
        la:sub(1, a[2] - 1) .. tb .. la:sub(ea + 1, b[2] - 1) .. ta .. la:sub(eb + 1),
      })
    else
      -- the two lines are set one for one: they may be several rows
      -- apart (blank lines crossed by h/j/k), and the rows between
      -- them are nobody's to touch
      ok = pcall(vim.api.nvim_buf_set_lines, buf, a[1] - 1, a[1], false, {
        la:sub(1, a[2] - 1) .. tb .. la:sub(ea + 1),
      })
      if ok then
        pcall(vim.cmd, 'undojoin') -- the two halves are ONE trade
        ok = pcall(vim.api.nvim_buf_set_lines, buf, b[1] - 1, b[1], false, {
          lb:sub(1, b[2] - 1) .. ta .. lb:sub(eb + 1),
        })
      end
    end
    if not ok then
      break
    end
    done = done + 1
    -- the cursor rides the word that moved, ONTO ITS NEW START: a's
    -- text takes b's slot and b's takes a's — cross-line that is
    -- exactly the other slot's column, same-line the lengths differ
    -- and the start shifts by how much (the old landing assumed equal
    -- lengths and left the cursor on the gap before the word, so a
    -- [count] bubble paired the WRONG word on its second trade)
    local rrow, rcol
    if ride == 'a' then
      rrow = b[1]
      rcol = (a[1] == b[1]) and (a[2] + #tb + (b[2] - 1 - ea)) or b[2]
    else
      rrow, rcol = a[1], a[2]
    end
    vim.api.nvim_win_set_cursor(0, { rrow, rcol - 1 })
    if _ < n then
      pcall(vim.cmd, 'undojoin') -- the bubbles are one undo entry
    end
  end
  if done == 0 then
    pcall(vim.api.nvim_win_set_cursor, 0, save) -- nothing traded: no move either
  end
end

--- n-mode <C-x> DURING a pending exchange — the operator's callback:
--- the second area is the MOTION's span, '[, '], its kind (char/line/
--- block) the motion's own — C-x{motion} swaps it with the marked
--- area, the way <C-x> on a Visual selection swaps with what the
--- selection covers (the second exchange could be a motion).
M._xopfunc = function(mtype)
  local buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local pending = xch_region()
  if not (pending and XCH.buf == buf) then
    echo({ { 'exchange: nothing marked', 'WarningMsg' } })
    return
  end
  local r1, c1 = vim.fn.line("'["), vim.fn.col("'[")
  local r2, c2 = vim.fn.line("']"), vim.fn.col("']")
  if r1 == 0 or r2 == 0 then
    return
  end
  local vmode = mtype == 'line' and 'V' or (mtype == 'block' and BLOCK or 'v')
  local nlines = vim.api.nvim_buf_line_count(buf)
  local region = normalize(vmode, r1, c1, r2, c2)
  region.r1 = math.min(region.r1, nlines)
  region.r2 = math.min(region.r2, nlines)
  if region.mode == 'v' then
    local last = vim.api.nvim_buf_get_lines(buf, region.r2 - 1, region.r2, false)[1] or ''
    if region.c2 > #last then
      region.c2 = #last
    end
    local first = vim.api.nvim_buf_get_lines(buf, region.r1 - 1, region.r1, false)[1] or ''
    if region.c1 > #first then
      region.c1 = #first
    end
  end
  xch_clear() -- before the swap: the swap's own changes must not read
  -- as somebody else's edit clearing it
  local err = xch_swap(buf, pending, region)
  pcall(vim.fn.setpos, '.', { 0, region.r1, math.max(region.c1, 1), 0 })
  if err then
    echo({ { 'exchange: ' .. err, 'WarningMsg' } })
  else
    echo({ { 'exchanged', 'Comment' } })
  end
end

--- x-mode <C-x> outside the mode: complete a waiting exchange with the
--- live selection, or mark the selection as an exchange's first area —
--- the same key does the same thing a session's <C-x> does. Either way
--- Visual mode is left behind when the key is done: a kept mark parks
--- the cursor in normal mode (that is where the second area is picked
--- from — a Visual selection, or a motion after the normal-mode <C-x>
--- the wait shadows in), and a finished swap has nothing left to select
--- — the same "Visual goes, always" the in-mode endings follow.
function M._exchange()
  local buf = vim.api.nvim_get_current_buf()
  local vmode = vim.fn.mode()
  if vmode ~= 'v' and vmode ~= 'V' and vmode ~= BLOCK then
    return
  end
  local p1, p2 = vim.fn.getpos('v'), vim.fn.getpos('.')
  if p1[2] == 0 or p2[2] == 0 then
    return
  end
  local nlines = vim.api.nvim_buf_line_count(buf)
  local region = normalize(vmode, p1[2], p1[3], p2[2], p2[3])
  region.r1 = math.min(region.r1, nlines)
  region.r2 = math.min(region.r2, nlines)
  if region.mode == 'v' then
    local last = vim.api.nvim_buf_get_lines(buf, region.r2 - 1, region.r2, false)[1] or ''
    if region.c2 > #last then
      region.c2 = #last
    end
  end
  vim.cmd('normal! ' .. vim.keycode('<Esc>'))
  local pending = xch_region()
  if pending and XCH.buf == buf then
    xch_clear() -- before the swap: the swap's own changes must not read
    -- as somebody else's edit clearing it
    local err = xch_swap(buf, pending, region)
    if err then
      echo({ { 'exchange: ' .. err, 'WarningMsg' } })
    else
      echo({ { 'exchanged', 'Comment' } })
    end
  else
    if XCH.buf and XCH.buf ~= buf then
      xch_clear()
    end
    xch_arm(buf, region)
    -- park the cursor on the marked area's first corner — a predictable
    -- place for the motions that pick the second area
    pcall(vim.fn.setpos, '.', {
      0,
      region.r1,
      region.mode == 'V' and 1 or math.max(region.c1, 1),
      0,
    })
    echo({
      { 'exchange: first area marked — select the next one, ', 'None' },
      { keyname(M.options.keys.exchange) .. ' or '
          .. keyname(M.options.keys.exchange)
          .. ' C-h/j/k/l (or any motion) swaps, ', 'Comment' },
      { 'Esc cancels', 'Comment' },
    })
  end
end

--- Carry a region — the live Visual selection, or `region` when
--- given ({ mode = 'v'|'V'|'\22', r1, c1, r2, c2 }) — to `pos`
--- ({ row, col }, 1-based byte columns): the goto motions' two legs,
--- rows then columns, exposed as an API for other plugins to aim (a
--- flash.nvim jump, a treehopper node, your own maps — see the
--- USAGE block up top for a flash.nvim example). The selection is
--- left selected where it lands; the carry is one undo entry.
--- Returns true when something moved.
---@param pos {[1]: integer, [2]: integer}
---@param region? MoveRegion
---@return boolean
function M.carry_to(pos, region)
  local buf = vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].modifiable then
    return false
  end
  if type(pos) ~= 'table' or type(pos[1]) ~= 'number' or type(pos[2]) ~= 'number' then
    return false
  end
  if region then
    if type(region.mode) ~= 'string' or type(region.r1) ~= 'number'
      or type(region.c1) ~= 'number' or type(region.r2) ~= 'number'
      or type(region.c2) ~= 'number' then
      return false
    end
    region = normalize(region.mode, region.r1, region.c1, region.r2, region.c2)
  else
    local vmode = vim.fn.mode()
    if vmode ~= 'v' and vmode ~= 'V' and vmode ~= BLOCK then
      return false
    end
    local p1, p2 = vim.fn.getpos('v'), vim.fn.getpos('.')
    if p1[2] == 0 or p2[2] == 0 then
      return false
    end
    region = normalize(vmode, p1[2], p1[3], p2[2], p2[3])
  end
  local nlines = vim.api.nvim_buf_line_count(buf)
  region.r1 = math.min(region.r1, nlines)
  region.r2 = math.min(region.r2, nlines)
  if region.mode == 'v' then
    local last = vim.api.nvim_buf_get_lines(buf, region.r2 - 1, region.r2, false)[1] or ''
    if region.c2 > #last then
      region.c2 = #last
    end
    local first = vim.api.nvim_buf_get_lines(buf, region.r1 - 1, region.r1, false)[1] or ''
    if region.c1 > #first then
      region.c1 = #first
    end
  end
  local old_ve = vim.o.virtualedit
  vim.o.virtualedit = 'all'
  -- the carry's own undo entry, and the same fresh-start the sessions
  -- get: without the sync the legs disappear into an earlier change
  vim.cmd('let &undolevels = &undolevels')
  local moved = carry_region(region, pos[1], pos[2], false)
  reselect(region, #corners(region))
  vim.o.virtualedit = old_ve
  return moved
end

---------------------------------------------------------------------------
-- setup
---------------------------------------------------------------------------

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  M.did_setup = true
  -- a second setup() with a key turned off (or moved) must not leave the
  -- first one's maps behind: what we mapped and no longer want goes,
  -- but only while it is still OURS — a map the user took over in the
  -- meantime is theirs
  for _, key in ipairs({ 'normal', 'exchange' }) do
    local old = M._mapped and M._mapped[key]
    local want = M.options.keys and M.options.keys[key]
    if old and old ~= want then
      local info = vim.fn.maparg(old, key == 'exchange' and 'x' or 'n', false, true)
      if type(info) == 'table' and type(info.desc) == 'string'
        and vim.startswith(info.desc, 'gliter.move:') then
        pcall(vim.keymap.del, key == 'exchange' and 'x' or 'n', old)
      end
    end
  end
  M._mapped = {}
  -- the engine's own options travel with the mode's
  gomove.opts.reindent = M.options.reindent == true
  gomove.opts.move_past_end_col = M.options.move_past_end_col ~= false
  local mode = M.options.keys and M.options.keys.mode
  if mode then
    vim.keymap.set('x', mode, '<Cmd>lua require("gliter.move")._session()<CR>', {
      silent = true,
      desc = 'gliter.move: carry the selection with h j k l and the goto motions (C-t keeps, Esc undoes, C-x exchanges)',
    })
  end
  local normal = M.options.keys and M.options.keys.normal
  if normal then
    -- the MODE from normal mode: C-h C-j C-k C-l transpose the
    -- adjacent words in that direction (once), C-o/C-i walk Vim's
    -- own jump list — every press another step, the keys mixed
    -- freely — and anything else is let go (the old C-t{dir}
    -- spelling still works; the plain h j k l o i are replaced, not
    -- aliased). A <Cmd> mapping, not an
    -- expr one: an expr mapping's evaluation SNAPS THE CURSOR BACK to
    -- where the key was pressed. <C-m> and <CR> are the same key on
    -- most terminals; buffers whose <CR> is their own (netrw, the
    -- quickfix, help) never see the mode — their <CR> maps are
    -- buffer-local and a local map beats a global one — and
    -- keys.normal = false gives Enter back
    vim.keymap.set('n', normal, '<Cmd>lua require("gliter.move")._nmode()<CR>', {
      silent = true,
      desc = 'gliter.move: a mode — C-hjkl transposes words, C-o/C-i walk the jump list (repeatable)',
    })
    M._mapped.normal = normal
  end
  local exchange = M.options.keys and M.options.keys.exchange
  if exchange and vim.fn.maparg(exchange, 'x') == '' then
    -- only when the key is free: a user's own visual <C-x> is never
    -- shadowed — and normal mode's <C-x> (decrement) is not touched
    -- either: the exchange lives inside the mode and on the visual key,
    -- and the motion form (C-x{motion}) is a buffer-local shadow that
    -- exists only while an exchange is waiting
    vim.keymap.set('x', exchange, '<Cmd>lua require("gliter.move")._exchange()<CR>', {
      silent = true,
      desc = 'gliter.move: exchange — mark this area, or swap with the marked one',
    })
    M._mapped.exchange = exchange
  end
end

return M
