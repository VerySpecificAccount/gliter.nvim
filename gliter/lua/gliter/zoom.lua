--- gliter.zoom — text-scale for the terminal, per buffer/window.
---
--- Emacs' text-scale (C-x C-+ / C-x C-- / C-x C-0) grows the font of
--- the current buffer because a GUI Emacs draws every face itself. A
--- terminal draws its whole grid with one font, and the "remote
--- control" ways of changing it always size more than the one nvim
--- window you meant: an OS window, a pane, the whole terminal. So
--- gliter.zoom zooms the only way that stays inside the buffer — and
--- it now ships TWO engines:
---
---   1. THE STYLE ZOOM  — <Leader>= in, <Leader>- out, <Leader>0 off.
---      The current BUFFER's lines are redrawn, character by
---      character, in the Unicode "Mathematical Alphanumeric Symbols"
---      (U+1D400–U+1D7FF) and their cousins — the same trick the
---      fancy-font sites use. One step in, every letter goes 𝐁𝐨𝐥𝐝 (and
---      the real ANSI bold on top of it, colors kept); another step
---      makes them 𝙼𝚘𝚗𝚘𝚜𝚙𝚊𝚌𝚎; one step out they shrink to Sᴍᴀʟʟ Cᴀᴩꜱ.
---
---      The ladder is TWO TABLES, one per direction, that you add
---      entries to or remove them from — no level indexes:
---
---        require('gliter.zoom').setup {
---          styles = {
---            zoom_in  = { 'bold', 'underlined', 'mono', 'fullwidth' },
---            zoom_out = { 'smallcaps' },
---          },
---        }
---
---      Entry 1 of zoom_in is level 1, entry 2 is level 2, and so on;
---      entry 1 of zoom_out is level -1. Remove 'mono' and the ladder
---      is one step shorter; put 'squared' first and the first step in
---      goes 🅱🅻🅾𝅲🅺🆂. :GliterZoomStyles prints EVERY style with a
---      live example, and the defaults below list them all.
---
---   2. THE GLYPH ZOOM  — <Leader>z, a toggle. The buffer's lines are
---      drawn again with a 5x6 SUB-PIXEL bitmap font — five drawing
---      rows and a blank sixth one (the line gap), so every letter
---      gets its bottom strokes AND its breathing room — spelled in
---      the braille dot characters by default (one bitmap pixel is
---      half a cell wide, half a cell tall; swap the dots for the
---      solid half-blocks or the shades in opts.glyph.quads, redraw
---      or extend the letters in opts.glyph.font), keeping the
---      treesitter / :syntax colors: real big letters, any terminal,
---      over ssh, inside tmux — and THIN, the | look: braille dots,
---      one dot-column per stroke. Every scale grows each font pixel
---      to s×s sub-pixels, so the letters resize without stretching:
---      scale 1 is the small size, 3 columns by 3 rows per letter
---      (2 1/2 of them letter, the rest the gap), 2 = 6x6, 3 = 9x9,
---      ... (a count sets the size: 1<Leader>z or plain <Leader>z =
---      the small size, 2<Leader>z = 6x6, 3<Leader>z bigger, ...).
---      The cursor line is transformed like every other line (set
---      glyph.skip_cursor_line = true to keep it real instead — the
---      cursor keeps its column but some terminals draw it under
---      overlay extmarks), and the cursor itself is drawn BIG: the
---      letter under it is painted in the cursor's colors across
---      all of its rows — one zoomed-letter-sized cursor, because
---      the terminal's own 1-cell cursor cannot show which
---      3-cells-wide (at x1) letter it is standing on (set
---      glyph.cursor = false for the plain small one). The Visual
---      selection paints big too — the selected letters in the
---      Visual colors, charwise/linewise/blockwise, following the
---      selection as it extends — and so does every built-in
---      multicursor (Neovim 0.13: the extmarks in the
---      "nvim.multicursor" namespace) in the MCursor colors; and
---      none of it bleeds: a cursor on a run of spaces covers
---      exactly its own letter, the spaces after it keep their
---      color. Like the
---      style zoom it is BUFFER-specific: every other buffer on
---      screen keeps its normal size, and each WINDOW showing the
---      zoomed buffer gets its own viewport rendered. With the glyph
---      zoom on, <Leader>= / <Leader>- grow / shrink it.
---
--- The two engines are mutually exclusive per buffer — turning one on
--- turns the other off.
---
--- The style zoom's redraw is an overlay extmark per line (the buffer
--- text is never touched), with hl_mode "combine": the buffer's own
--- treesitter / :syntax colors shine through the styled glyphs, and
--- the bold levels add the terminal's real bold on top. If nui.nvim
--- is around, every zoomed line is composed as a NuiText component
--- (require('nui.text')) — the same primitive noice and the nui
--- popups render with; without it the overlay is built from plain
--- virt_text tuples. Set nui = false to force the plain path.
---
--- Commands: :GliterZoomIn / :GliterZoomOut / :GliterZoomReset /
--- :GliterZoomSet / :GliterZoomState / :GliterZoomGlyph [scale] /
--- :GliterZoomStyles. statusline() turns into ` Z2` (style level 2)
--- or ` G3` (glyph scale 3) for a zoomed buffer.
---
--- USAGE (from your init.lua)
---   require('gliter.zoom').setup()                     -- defaults
---   require('gliter.zoom').setup { glyph = { max_scale = 5 } }
---   require('gliter.zoom').setup { glyph = { font = { ['→'] = '010/111/010/000' } } }
---   require('gliter').setup { zoom = true }             -- through gliter

local M = {}

M.did_setup = false

local defaults = {
  keys = {
    increase = '<Leader>=', -- grow: the glyph scale while the glyph
    -- zoom is on, the style level otherwise (this buffer only)
    decrease = '<Leader>-', -- shrink: the glyph scale while the glyph
    -- zoom is on (past the smallest it turns the glyphs off), the
    -- style level otherwise (negative = smaller)
    reset = '<Leader>0', -- both engines off, 'wrap' restored
    glyph = '<Leader>z', -- glyph zoom: toggle (a count sets the scale)
  },
  echo = true, -- say the state on every change
  -- ── engine 1: the style zoom ──────────────────────────────────────
  styles = {
    -- The zoom-IN ladder: entry 1 = level 1, entry 2 = level 2, ...
    -- and the zoom-OUT ladder: entry 1 = level -1, ... ADD, REMOVE or
    -- REORDER entries freely — the number of entries IS the number of
    -- levels; there are no indexes to keep in sync. By default EVERY
    -- font that ships is in a ladder — trim the lists to taste.
    zoom_in = {
      'bold', -- 𝐛𝐨𝐥𝐝 — level 1
      'italic', -- 𝑖𝑡𝑎𝑙𝑖𝑐
      'bold_italic', -- 𝒃𝒐𝒍𝒅 𝒊𝒕𝒂𝒍𝒊𝒄
      'script', -- 𝓈𝒸𝓇𝒾𝓅𝓉
      'bold_script', -- 𝓫𝓸𝓵𝓭 𝓼𝓬𝓻𝓲𝓹𝓽
      'fraktur', -- 𝔣𝔯𝔞𝔨𝔱𝔲𝔯
      'bold_fraktur', -- 𝖋𝖗𝖆𝖐𝖙𝖚𝖗 𝖇𝖔𝖑𝖉
      'double_struck', -- 𝕕𝕠𝕦𝕓𝕝𝕖 𝕤𝕥𝕣𝕦𝕔𝕜
      'sans', -- 𝗌𝖺𝗇𝗌
      'sans_bold', -- 𝘀𝗮𝗻𝘀 𝗯𝗼𝗹𝗱
      'sans_italic', -- 𝘴𝘢𝘯𝘴 𝘪𝘵𝘢𝘭𝘪𝘤
      'sans_bold_italic', -- 𝙨𝙖𝙣𝙨 𝙗𝙤𝙡𝙙 𝙞𝙩𝙖𝙡𝙞𝙘
      'mono', -- 𝚖𝚘𝚗𝚘
      'underlined', -- 𝘂̲𝗻̲𝗱̲𝗲̲𝗿̲𝗹̲𝗶̲𝗻̲𝗲̲𝗱̲
      'circled', -- Ⓒⓘⓡⓒⓛⓔⓓ (ambiguous width in some terminals)
      'squared', -- 🅢🅠🅤🅐🅡🅔🅓 (2 cells per char)
      'fullwidth', -- ｆｕｌｌｗｉｄｔｈ — 2 cells per char, the huge one
    },
    zoom_out = {
      'smallcaps', -- ꜱᴍᴀʟʟ ᴄᴀᴩꜱ — level -1
      'superscript', -- ˢᵘᵖᵉʳˢᶜʳⁱᵖᵗ — level -2
    },
    -- EVERY style that ships (use any name in the two ladders above;
    -- :GliterZoomStyles prints them all with a live example):
    --   bold, serif              𝐚𝐬𝐝𝐟 𝟏𝟐𝟑   serif bold
    --   italic                   𝑎𝑠𝑑𝑓
    --   bold_italic              𝒂𝒔𝒅𝒇
    --   script, cursive          𝒶𝓈𝒹𝒻
    --   bold_script              𝓪𝓼𝓭𝓯
    --   fraktur, gothic          𝔞𝔰𝔡𝔣
    --   bold_fraktur, fraktur_bold, gothic_bold   𝖆𝖘𝖉𝖋
    --   double_struck            𝕒𝕤𝕕𝕗
    --   sans                     𝖺𝗌𝖽𝖿
    --   sans_bold                𝗮𝘀𝗱𝗳
    --   sans_italic              𝘢𝘴𝘥𝘧
    --   sans_bold_italic         𝙖𝙨𝙙𝙛
    --   mono                     𝚊𝚜𝖉𝚏
    --   smallcaps                ꜱᴍᴀʟʟ ᴄᴀᴩꜱ
    --   superscript              ᵃˢᵈᶠ ¹²³
    --   circled                  ⓐⓑⓒ ①②③
    --   squared, blocks          🅰🅱🅲 (negative squared)
    --   underlined               𝗮̲𝗯̲𝗰̲ (sans bold + combining low line)
    --   fullwidth                ａｓ𝖉𝖋 (2 cells wide)
  },
  margin = 20, -- lines rendered above/below each window's viewport
  nui = 'auto', -- 'auto' | true | false: NuiText components when
  -- nui.nvim is installed ('auto' uses them when found; true insists,
  -- false never)
  hl_mode = 'combine', -- 'combine' keeps the buffer's colors under
  -- the styled glyphs; 'replace' paints them flat
  -- ── engine 2: the glyph zoom ──────────────────────────────────────
  glyph = {
    max_scale = 4, -- deepest scale: 1 = the small thin letters (a
    -- letter + its gap 3 cells wide, 3 rows per line), 2 = 6x6,
    -- 3 = 9x9, 4 = 12x12 — every scale grows the letters
    -- UNIFORMLY (s×s sub-pixels per font pixel — no stretching)
    hl_group = 'Normal', -- the color of unhighlighted glyph cells
    skip_cursor_line = false, -- true keeps the cursor line real text
    -- (the cursor keeps its column; some terminals draw it under
    -- overlay extmarks) — false, the default, transforms the cursor
    -- line like every other line
    cursor = true, -- draw the cursor BIG: the letter under the
    -- cursor is painted in the cursor's colors across all of its
    -- rows — the terminal's own 1-cell cursor cannot show which
    -- 3-cells-wide (at x1) letter it is on; false = the plain small
    -- cursor. The Visual selection and every multicursor paint big
    -- the same way. No effect while skip_cursor_line = true
    -- The 16 sub-pixel characters by bitmask (TL*8 + TR*4 + BL*2 +
    -- BR*1). Braille dots by default — the lightest, most readable
    -- spelling; the solid half-blocks are denser, the shades sit in
    -- between:
    --   quads = { ' ', '▗', '▖', '▄', '▝', '▐', '▞', '▟', '▘', '▚', '▌', '▙', '▀', '▜', '▛', '█' },
    quads = { '⠀', '⢠', '⡄', '⣤', '⠘', '⢸', '⡜', '⣼', '⠃', '⢣', '⡇', '⣧', '⠛', '⢻', '⡟', '⣿' },
    --   quads = { ' ', '░', '░', '▒', '░', '▒', '▒', '▓', '░', '▒', '▒', '▓', '▒', '▓', '▓', '█' },
    -- Your own glyphs, merged over the built-in 5x6 SUB-PIXEL font
    -- (one bitmap pixel = half a cell wide, half a cell tall — the
    -- thin strokes, the | look; five drawing rows plus the blank
    -- sixth one that keeps a gap between the lines): bitmap rows
    -- separated by '/', 1 = pixel on. Redraw a letter —
    --   font = { ['A'] = '01110/10001/11111/10001/10001/00000' }
    -- add one the font lacks (unknown characters draw as O) —
    --   font = { ['→'] = '00010/00100/01110/00100/00000/00000' }
    -- or spell a whole font of your own. Every glyph is padded to
    -- the widest one's width; the letter gap is one font pixel, the
    -- line gap the last blank font row.
    font = {},
  },
}
local cfg = vim.deepcopy(defaults)

local ns = vim.api.nvim_create_namespace('gliter-zoom')

local function say(msg)
  if cfg.echo then
    vim.api.nvim_echo({ { '[gliter] ' .. msg, 'None' } }, false, {})
  end
end

------------------------------------------------------------- the styles --
-- Mathematical Alphanumeric Symbols (U+1D400–U+1D7FF) are a parallel
-- alphabet: every letter and digit has bold, italic, script, fraktur,
-- double-struck, sans-serif and monospace twins. A style is three
-- codepoint bases (uppercase, lowercase, digits) plus the handful of
-- letters that were already assigned elsewhere and live outside the
-- block. Small caps, superscripts, circled and negative squared have
-- no arithmetic — explicit maps. 'underlined' is a base style plus a
-- combining character. Characters a style cannot spell stay untouched.

local styles = {}

local function math_style(name, u, l, d, exc)
  styles[name] = { u = u, l = l, d = d, exc = exc or {} }
end

math_style('bold', 0x1D400, 0x1D41A, 0x1D7CE)
math_style('italic', 0x1D434, 0x1D44E, nil, { h = 0x210E })
math_style('bold_italic', 0x1D468, 0x1D482)
math_style('script', 0x1D49C, 0x1D4B6, nil, {
  B = 0x212C, E = 0x2130, F = 0x2131, H = 0x210B, I = 0x2110,
  L = 0x2112, M = 0x2133, R = 0x211B, e = 0x212F, g = 0x210A, o = 0x2134,
})
math_style('bold_script', 0x1D4D0, 0x1D4EA)
math_style('fraktur', 0x1D504, 0x1D51E, nil, {
  C = 0x212D, H = 0x210C, I = 0x2111, R = 0x211C, Z = 0x2128,
})
math_style('double_struck', 0x1D538, 0x1D552, 0x1D7D8, {
  C = 0x2102, H = 0x210D, N = 0x2115, P = 0x2119, Q = 0x211A,
  R = 0x211D, Z = 0x2124,
})
math_style('bold_fraktur', 0x1D56C, 0x1D586)
math_style('sans', 0x1D5A0, 0x1D5BA, 0x1D7E2)
math_style('sans_bold', 0x1D5D4, 0x1D5EE, 0x1D7EC)
math_style('sans_italic', 0x1D608, 0x1D622)
math_style('sans_bold_italic', 0x1D63C, 0x1D656)
math_style('mono', 0x1D670, 0x1D68A, 0x1D7F6)

styles.smallcaps = { map = { -- Sᴍᴀʟʟ Cᴀᴩꜱ — x has no small cap
  a = 0x1D00, b = 0x0299, c = 0x1D04, d = 0x1D05, e = 0x1D07, f = 0xA730,
  g = 0x0262, h = 0x029C, i = 0x026A, j = 0x1D0A, k = 0x1D0B, l = 0x029F,
  m = 0x1D0D, n = 0x0274, o = 0x1D0F, p = 0x1D18, q = 0xA7AF, r = 0x0280,
  s = 0xA731, t = 0x1D1B, u = 0x1D1C, v = 0x1D20, w = 0x1D21,
  y = 0x028F, z = 0x1D22,
} }

styles.superscript = { map = { -- ˢᵘᵖᵉʳˢᶜʳⁱᵖᵗ — the letters that exist
  a = 0x1D43, b = 0x1D47, c = 0x1D9C, d = 0x1D48, e = 0x1D49, f = 0x1DA0,
  g = 0x1D4D, h = 0x02B0, i = 0x2071, j = 0x02B2, k = 0x1D4F, l = 0x02E1,
  m = 0x1D50, n = 0x207F, o = 0x1D52, p = 0x1D56, r = 0x02B3, s = 0x02E2,
  t = 0x1D57, u = 0x1D58, v = 0x1D5B, w = 0x02B7, x = 0x02E3, y = 0x02B8,
  z = 0x1DBB,
  A = 0x1D2C, B = 0x1D2E, D = 0x1D30, E = 0x1D31, G = 0x1D33, H = 0x1D34,
  I = 0x1D35, J = 0x1D36, K = 0x1D37, L = 0x1D38, M = 0x1D39, N = 0x1D3A,
  O = 0x1D3C, P = 0x1D3E, R = 0x1D3F, T = 0x1D40, U = 0x1D41, V = 0x2C7D,
  W = 0x1D42,
  ['0'] = 0x2070, ['1'] = 0x00B9, ['2'] = 0x00B2, ['3'] = 0x00B3,
  ['4'] = 0x2074, ['5'] = 0x2075, ['6'] = 0x2076, ['7'] = 0x2077,
  ['8'] = 0x2078, ['9'] = 0x2079,
} }

styles.circled = { map = {} } -- Ⓐ ⓑ Ⓒ — ambiguous width in some terminals
do
  for b = 0x41, 0x5A do
    styles.circled.map[string.char(b)] = 0x24B6 + (b - 0x41)
  end
  for b = 0x61, 0x7A do
    styles.circled.map[string.char(b)] = 0x24D0 + (b - 0x61)
  end
  for d = 0x31, 0x39 do
    styles.circled.map[string.char(d)] = 0x2460 + (d - 0x31)
  end
  styles.circled.map['0'] = 0x24EA
end

-- 🅱🅻🅾𝅲🅺🆂 — NEGATIVE SQUARED LATIN CAPITAL LETTERS. Only capitals
-- exist (U+1F170–U+1F189), so lowercase folds up to them, the way the
-- fancy-font sites spell it; digits have no squared twins and stay.
styles.squared = { map = {} }
do
  for b = 0x41, 0x5A do
    local ch = string.char(b)
    styles.squared.map[ch] = 0x1F170 + (b - 0x41)
  end
  for b = 0x61, 0x7A do
    styles.squared.map[string.char(b)] = 0x1F170 + (b - 0x61)
  end
end

-- 𝘂̲𝗻̲𝗱̲𝗲̲𝗿̲𝗹̲𝗶̲𝗻̲𝗲̲𝗱̲ — a base style (sans bold) plus U+0332 COMBINING
-- LOW LINE after every character the base could spell.
styles.underlined = { base = 'sans_bold', decor = 0x0332 }

styles.fullwidth = { map = {} } -- ｆｕｌｌｗｉｄｔｈ — 2 cells per character
do
  local fw = styles.fullwidth.map
  for b = 0x41, 0x5A do
    fw[string.char(b)] = 0xFF21 + (b - 0x41)
  end
  for b = 0x61, 0x7A do
    fw[string.char(b)] = 0xFF41 + (b - 0x61)
  end
  for d = 0x30, 0x39 do
    fw[string.char(d)] = 0xFF10 + (d - 0x30)
  end
  local punct = {
    ['!'] = 0xFF01, ['"'] = 0xFF02, ['#'] = 0xFF03, ['$'] = 0xFF04,
    ['%'] = 0xFF05, ['&'] = 0xFF06, ["'"] = 0xFF07, ['('] = 0xFF08,
    [')'] = 0xFF09, ['*'] = 0xFF0A, ['+'] = 0xFF0B, [','] = 0xFF0C,
    ['-'] = 0xFF0D, ['.'] = 0xFF0E, ['/'] = 0xFF0F, [':'] = 0xFF1A,
    [';'] = 0xFF1B, ['<'] = 0xFF1C, ['='] = 0xFF1D, ['>'] = 0xFF1E,
    ['?'] = 0xFF1F, ['@'] = 0xFF20, ['['] = 0xFF3B, ['\\'] = 0xFF3C,
    [']'] = 0xFF3D, ['^'] = 0xFF3E, ['_'] = 0xFF3F, ['`'] = 0xFF40,
    ['{'] = 0xFF5B, ['|'] = 0xFF5C, ['}'] = 0xFF5D, ['~'] = 0xFF5E,
  }
  for ch, cp in pairs(punct) do
    fw[ch] = cp
  end
end

-- the aliases the fancy-font sites use — every one names its target
local aliases = {
  serif = 'bold',
  cursive = 'script',
  gothic = 'fraktur',
  fraktur_bold = 'bold_fraktur',
  gothic_bold = 'bold_fraktur',
  double = 'double_struck',
  monospace = 'mono',
  blocks = 'squared',
}

--- A style name — alias or canonical — to its table and its canonical
--- name; nil when no such style exists.
---@param name string
---@return table? style
---@return string? canonical
local function resolve_style(name)
  local canonical = aliases[name] or name
  return styles[canonical], canonical
end

--- One character spelled in a style: the twin as a string, or nil when
--- the style has nothing for it (the character passes through).
---@param ch string
---@param st table
---@return string?
local function spell(ch, st)
  if st.map then
    local cp = st.map[ch]
    return cp and vim.fn.nr2char(cp)
  end
  local b = ch:byte()
  if not b or b >= 0x80 then
    return nil -- non-ASCII passes through untouched
  end
  local exc = st.exc and st.exc[ch]
  if exc then
    return vim.fn.nr2char(exc)
  end
  local base, off
  if b >= 0x41 and b <= 0x5A and st.u then
    base, off = st.u, b - 0x41
  elseif b >= 0x61 and b <= 0x7A and st.l then
    base, off = st.l, b - 0x61
  elseif b >= 0x30 and b <= 0x39 and st.d then
    base, off = st.d, b - 0x30
  end
  if base then
    return vim.fn.nr2char(base + off)
  end
  return nil
end

--- One line spelled in a style: every character the style can spell is
--- replaced by its twin (an 'underlined' style appends its combining
--- character after each one it spells), tabs are expanded to the
--- tabstop, and everything else passes through untouched.
---@param line string
---@param style string the style's name
---@param tabstop integer
---@return string
local function transform_line(line, style, tabstop)
  local st = resolve_style(style)
  if not st then
    return line
  end
  local base, decor = st, nil
  if st.base then -- 'underlined': a base style plus a combining char
    base = resolve_style(st.base)
    decor = st.decor
  end
  local out, col = {}, 0
  for _, ch in ipairs(vim.fn.split(line, '\\zs')) do
    if ch == '\t' then
      local reps = tabstop - (col % tabstop)
      out[#out + 1] = (' '):rep(reps)
      col = col + reps
    else
      local spelled = spell(ch, base)
      if spelled then
        out[#out + 1] = spelled
        if decor then
          out[#out + 1] = vim.fn.nr2char(decor)
        end
      else
        out[#out + 1] = ch
      end
      col = col + math.max(vim.fn.strdisplaywidth(ch), 1)
    end
  end
  return table.concat(out)
end

--- The style NAME a level maps to: zoom_in[l] for l > 0,
--- zoom_out[-l] for l < 0 — nil when the ladder has no such entry.
---@param level integer
---@return string?
local function style_for_level(level)
  if level > 0 then
    return cfg.styles.zoom_in[level]
  end
  if level < 0 then
    return cfg.styles.zoom_out[-level]
  end
  return nil
end

-------------------------------------------------------- the glyph font --
-- 5x6 SUB-PIXEL font, rows separated by "/", 1 = pixel on: one bitmap
-- pixel is HALF a cell wide and HALF a cell tall (a terminal cell is
-- about twice as tall as wide, so a sub-pixel is a thin vertical bar
-- of dots — that is the `|` look), a letter is 3 cells + its one-
-- pixel gap wide at scale 1, and 5 font rows tall with the SIXTH row
-- blank — the line gap, so stacked lines keep a strip of air between
-- them and every letter keeps its bottom strokes. At scale s every
-- bitmap pixel grows to s x s sub-pixels — the SAME thin shape at
-- every scale, which is why the letters resize without stretching
-- (the v10 rule, kept).
--   * scale 1 — <Leader>z's first size: hairline letters, 3 columns
--     + gap by 3 rows per line (2 1/2 rows of letter, the rest gap);
--   * scale n — 3n columns + gap by 3n rows: 2 = 6x6, 3 = 9x9,
--     4 = 12x12 — the same letters, bigger, just as thin.

local raw = {
  A = '01110/10001/11111/10001/10001/00000', B = '11110/10001/11110/10001/11110/00000', C = '01110/10001/10000/10001/01110/00000',
  D = '11110/10001/10001/10001/11110/00000', E = '11111/10000/11110/10000/11111/00000', F = '11111/10000/11110/10000/10000/00000',
  G = '01110/10000/10011/10001/01110/00000', H = '10001/10001/11111/10001/10001/00000', I = '01110/00100/00100/00100/01110/00000',
  J = '00111/00010/00010/00010/01100/00000', K = '10001/10010/11100/10010/10001/00000', L = '10000/10000/10000/10000/11111/00000',
  M = '10001/11011/10101/10001/10001/00000', N = '10001/11001/10101/10011/10001/00000', O = '01110/10001/10001/10001/01110/00000',
  P = '11110/10001/11110/10000/10000/00000', Q = '01110/10001/10001/10011/01101/00000', R = '11110/10001/11110/10010/10001/00000',
  S = '01111/10000/01110/00001/11110/00000', T = '11111/00100/00100/00100/00100/00000', U = '10001/10001/10001/10001/01110/00000',
  V = '10001/10001/10001/01010/00100/00000', W = '10001/10001/10101/10101/01010/00000', X = '10001/01010/00100/01010/10001/00000',
  Y = '10001/10001/01010/00100/00100/00000', Z = '11111/00010/00100/01000/11111/00000',
  ['0'] = '01110/10011/10101/11001/01110/00000', ['1'] = '00100/01100/00100/00100/01110/00000', ['2'] = '01110/00001/00110/01000/11111/00000',
  ['3'] = '11110/00001/01110/00001/11110/00000', ['4'] = '00010/00110/01010/11111/00010/00000', ['5'] = '11111/10000/11110/00001/11110/00000',
  ['6'] = '01110/10000/11110/10001/01110/00000', ['7'] = '11111/00010/00100/01000/01000/00000', ['8'] = '01110/10001/01110/10001/01110/00000',
  ['9'] = '01110/10001/01111/00001/01110/00000',
  [' '] = '00000/00000/00000/00000/00000/00000', ['.'] = '00000/00000/00000/00000/00100/00000', [','] = '00000/00000/00000/00100/01000/00000',
  [':'] = '00000/00000/00100/00000/00100/00000', [';'] = '00000/00100/00000/00100/01000/00000', ['!'] = '00100/00100/00100/00000/00100/00000',
  ['?'] = '01110/00010/00100/00000/00100/00000', ['-'] = '00000/00000/00000/01110/00000/00000', ['_'] = '00000/00000/00000/00000/11111/00000',
  ['+'] = '00000/00000/00100/01110/00100/00000', ['='] = '00000/00000/01110/00000/01110/00000', ['*'] = '00100/01010/00100/00000/00000/00000',
  ['/'] = '00001/00010/00100/01000/10000/00000', ['\\'] = '10000/01000/00100/00010/00001/00000', ['('] = '00010/00100/00100/00100/00010/00000',
  [')'] = '01000/00100/00100/00100/01000/00000', ['['] = '01110/00100/00100/00100/01110/00000', [']'] = '01110/00010/00010/00010/01110/00000',
  ['{'] = '00110/00100/01100/00100/00110/00000', ['}'] = '01100/00100/00110/00100/01100/00000', ['<'] = '00010/00100/01000/00100/00010/00000',
  ['>'] = '01000/00100/00010/00100/01000/00000', ['"'] = '01010/01010/00000/00000/00000/00000', ["'"] = '00100/00100/00000/00000/00000/00000',
  ['`'] = '00100/01000/00000/00000/00000/00000', ['#'] = '01010/11111/01010/11111/01010/00000', ['$'] = '00100/01111/11000/00111/00100/00000',
  ['%'] = '11001/11010/00100/01011/10011/00000', ['&'] = '01100/10010/01100/10100/01010/00000', ['@'] = '01110/10001/10111/10101/01110/00000',
  ['^'] = '00100/01010/00000/00000/00000/00000', ['~'] = '00000/00000/01001/10110/00000/00000', ['|'] = '00100/00100/00100/00100/00100/00000',
}

-- glyphs = raw + cfg.glyph.font, rebuilt by setup(); FONT_W/FONT_H the
-- box every glyph is padded into (the widest/tallest bitmap seen)
local glyphs = {}
local FONT_W, FONT_H = 5, 6
local box = nil -- unknown characters (the O glyph)
local glyph_cache = {}
local glyph_built = {} -- [buf] = { tick, scale, ts, rows = { [lnum] } }

local function build_font()
  glyphs = {}
  local w, h = 1, 1
  local function add(spec)
    local rows = vim.split(spec, '/', { plain = true })
    h = math.max(h, #rows)
    for _, r in ipairs(rows) do
      w = math.max(w, #r)
    end
    return rows
  end
  for ch, spec in pairs(raw) do
    glyphs[ch] = add(spec)
  end
  for ch, spec in pairs(cfg.glyph.font or {}) do
    if type(spec) == 'string' and spec:find('[01]') then
      glyphs[ch] = add(spec)
    end
  end
  FONT_W, FONT_H = w, h
  box = glyphs.O -- unknown characters draw as O; redraw it as font = { O = ... }
  glyph_cache = {} -- a new font means every cached glyph is stale
  glyph_built = {} -- ... and every line built from the old one too
end

build_font() -- the built-in font stands even before setup() runs

--- The cell dimensions of scale `s`: cols (cells per letter, the letter
--- gap of one font pixel INCLUDED) and rows (text rows per line — the
--- last font row is the blank one, the line gap). At scale s a font
--- pixel is s x s sub-pixels — the shape is preserved, no stretching
--- at any scale.
---@param s integer scale
---@return integer cols
---@return integer rows
local function glyph_dims(s)
  return math.ceil((FONT_W + 1) * s / 2), math.ceil(FONT_H * s / 2)
end

--- One character at scale `s`: one string per text row, the letter's
--- cells (gap included — the blank sub-columns past the bitmap are the
--- gap, so every letter's advance is a whole number of cells and the
--- letters stay on one grid at every scale).
---@param ch string
---@param s integer scale
---@return string[]
local function glyph_lines(ch, s)
  local key = ch .. 'x' .. s
  if glyph_cache[key] then
    return glyph_cache[key]
  end
  local g = glyphs[ch] or glyphs[ch:upper()] or box
  local cols = math.ceil((FONT_W + 1) * s / 2)
  local rows = math.ceil(FONT_H * s / 2)
  local out = {}
  for r = 0, rows - 1 do
    local cells = {}
    for c = 0, cols - 1 do
      local q = 0
      for qr = 0, 1 do
        local line = g[math.floor((r * 2 + qr) / s) + 1] or ''
        for qc = 0, 1 do
          local px = math.floor((c * 2 + qc) / s) + 1
          if px <= FONT_W and line:sub(px, px) == '1' then
            q = q + (qr == 0 and (qc == 0 and 8 or 4) or (qc == 0 and 2 or 1))
          end
        end
      end
      cells[#cells + 1] = cfg.glyph.quads[q + 1] or cfg.glyph.quads[16] or '█'
    end
    out[r + 1] = table.concat(cells)
  end
  glyph_cache[key] = out
  return out
end

------------------------------------------------------------- highlights --

-- the highlight groups: bold levels get the terminal's real bold; the
-- rest carry nothing — hl_mode 'combine' lets the buffer's own colors
-- through either way
local function define_hl()
  vim.api.nvim_set_hl(0, 'GliterZoomBold', { bold = true, default = true })
  vim.api.nvim_set_hl(0, 'GliterZoomText', { default = true })
  -- the big glyph cursor: the letter under the cursor, painted in
  -- the cursor's colors across all of its rows
  vim.api.nvim_set_hl(0, 'GliterZoomCursor', { link = 'Cursor', default = true })
  -- the Visual selection spelled into the glyph rows
  vim.api.nvim_set_hl(0, 'GliterZoomVisual', { link = 'Visual', default = true })
  -- every multicursor drawn big: the built-in 0.13 group when it is
  -- around, the plain cursor before that
  if vim.fn.hlexists('MCursor') == 1 then
    vim.api.nvim_set_hl(0, 'GliterZoomMCursor', { link = 'MCursor', default = true })
  else
    vim.api.nvim_set_hl(0, 'GliterZoomMCursor', { link = 'Cursor', default = true })
  end
end

local function style_hl(style)
  local s, name = resolve_style(style)
  local n = name or style
  local base = s and s.base
  return (n:find('bold') or (base and base:find('bold')))
    and 'GliterZoomBold' or 'GliterZoomText'
end

-- '@keyword.function.lua' -> the first of itself, '@keyword.function',
-- '@keyword' that exists.
local hl_cache = {}

local function resolve_hl(name)
  if not name then
    return nil
  end
  local cached = hl_cache[name]
  if cached ~= nil then
    return cached or nil
  end
  local n, found = name, nil
  while n and n ~= '' do
    if vim.fn.hlexists(n) == 1 then
      found = n
      break
    end
    n = n:match('^(.+)%.[^.]+$')
  end
  hl_cache[name] = found or false
  return found
end

-- Treesitter highlights for rows [s, e) (0-based): map[row][byte] = group.
local function ts_highlights(buf, s, e, lines)
  local map = {}
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return map, false
  end
  pcall(function()
    parser:parse({ s, e })
  end)
  local used = false
  parser:for_each_tree(function(tree, ltree)
    local lang = ltree:lang()
    local qok, query = pcall(vim.treesitter.query.get, lang, 'highlights')
    if not qok or not query then
      return
    end
    used = true
    for id, node in query:iter_captures(tree:root(), buf, s, e) do
      local name = query.captures[id]
      if name:sub(1, 1) ~= '_' and name ~= 'spell' and name ~= 'nospell' then
        local hl = '@' .. name .. '.' .. lang
        local r1, c1, r2, c2 = node:range()
        for row = math.max(r1, s), math.min(r2, e - 1) do
          local line = lines[row - s + 1] or ''
          local from = (row == r1) and c1 or 0
          local to = (row == r2) and (c2 - 1) or #line
          local m = map[row]
          if not m then
            m = {}
            map[row] = m
          end
          for b = from, to do
            m[b] = hl -- later captures override earlier ones
          end
        end
      end
    end
  end)
  return map, used
end

-- :syntax fallback for one line: map[byte] = group.
local function syn_row(lnum, line)
  local m, byte = {}, 0
  for _, ch in ipairs(vim.fn.split(line, '\\zs')) do
    local id = vim.fn.synID(lnum, byte + 1, 1)
    if id ~= 0 then
      m[byte] = vim.fn.synIDattr(id, 'name')
    end
    byte = byte + #ch
  end
  return m
end

---------------------------------------------------------------- state --

local levels = {} -- [buf] = style zoom level (absent = off)
local glyph_levels = {} -- [buf] = glyph zoom scale (absent = off)
local glyph_last = {} -- [buf] = the scale <Leader>z comes back to
local glyph_sig = {} -- [buf] = the last glyph render's signature:
-- tick, scale, cursors, multicursors, selection and viewports folded
-- into one string — an event that changed none of them re-renders
-- nothing (the idle SafeState pass would otherwise re-render at
-- every pause)
-- Vim stashes window-local options per (window, buffer) pair: switching
-- a window away from a buffer and back re-applies the values the buffer
-- last saw there. So the zoom's 'wrap = false' must never be what the
-- stash captures — the entry is keyed by (window, buffer), and
-- BufWinLeave (below) puts the user's value back BEFORE the switch
-- takes its snapshot.
local saved_wrap = {} -- [win .. ':' .. buf] = that pair's original 'wrap'

local function wrap_key(win, buf)
  return win .. ':' .. buf
end

-- put 'wrap' back in every window that stopped showing a zoomed buffer.
-- A buffer whose zoom turned off while it was NOT displayed keeps its
-- entry: Vim's (window, buffer) option stash still holds the zoom's
-- false for it, and BufWinEnter (in setup) applies the entry when the
-- buffer comes back to the window.
local function restore_stray_wrap()
  for key, wrap in pairs(saved_wrap) do
    local win = tonumber(key:match('^(%d+):'))
    if not win or not vim.api.nvim_win_is_valid(win) then
      saved_wrap[key] = nil
    else
      local kbuf = tonumber(key:match(':(%d+)$'))
      local wbuf = vim.api.nvim_win_get_buf(win)
      if wbuf == kbuf then
        -- the window shows that buffer and its zoom is off: put the
        -- value back (the write also fixes Vim's option stash for the
        -- pair, which still holds the zoom's false)
        if not (levels[wbuf] or glyph_levels[wbuf]) then
          vim.wo[win].wrap = wrap
          saved_wrap[key] = nil
        end
      elseif not (levels[kbuf] or glyph_levels[kbuf]) and not vim.api.nvim_buf_is_valid(kbuf) then
        -- the buffer is gone; nothing will ever display it again
        saved_wrap[key] = nil
      end
      -- else: the buffer moved out of this window with its zoom off —
      -- KEEP the entry; BufWinEnter applies it when the buffer returns
    end
  end
end

------------------------------------------------- engine 1: style render --

-- nui.nvim's NuiText, when it is around (resolved lazily: plugins load
-- in any order). nil = compose plain virt_text tuples instead.
local NuiText = nil
local nui_state = 'unknown' -- 'unknown' | 'yes' | 'no'

local function resolve_nui()
  if nui_state ~= 'unknown' then
    return
  end
  if cfg.nui == false then
    nui_state = 'no'
    return
  end
  local ok, t = pcall(require, 'nui.text')
  if ok and type(t) == 'table' and type(t.new) == 'function' then
    NuiText = t
    nui_state = 'yes'
  elseif cfg.nui == true then
    nui_state = 'no'
    say('zoom: nui.nvim not found — plain rendering (install it or set nui = \'auto\')')
  else
    nui_state = 'no'
  end
end

-- One styled line over one buffer line: a single overlay extmark at
-- column 0, composed as a NuiText component when nui.nvim is around.
local function overlay(buf, lnum, text, hl)
  local seg
  if NuiText then
    local comp = NuiText(text, hl)
    seg = { comp:content(), comp.extmark and comp.extmark.hl_group or hl }
  else
    seg = { text, hl }
  end
  vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, {
    virt_text = { seg },
    virt_text_pos = 'overlay',
    hl_mode = cfg.hl_mode,
  })
end

local function render(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local level = levels[buf]
  if not level then
    return
  end
  local style = style_for_level(level)
  if not style or not resolve_style(style) then
    return
  end
  resolve_nui()
  define_hl()
  local hl = style_hl(style)
  local tabstop = vim.bo[buf].tabstop
  local total = vim.api.nvim_buf_line_count(buf)
  local done = {}

  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if saved_wrap[wrap_key(win, buf)] == nil then
      saved_wrap[wrap_key(win, buf)] = vim.wo[win].wrap
    end
    vim.wo[win].wrap = false -- the overlay cannot wrap

    local info = vim.api.nvim_win_call(win, function()
      return { vim.fn.line('w0'), vim.fn.line('w$') }
    end)
    local s = math.max(1, info[1] - cfg.margin)
    local e = math.min(total, info[2] + cfg.margin)
    local lines = vim.api.nvim_buf_get_lines(buf, s - 1, e, false)
    for idx, line in ipairs(lines) do
      local lnum = s + idx - 1
      if not done[lnum] and line ~= '' then
        done[lnum] = true
        local text = transform_line(line, style, tabstop)
        if text ~= line then
          overlay(buf, lnum, text, hl)
        end
      end
    end
  end
end

------------------------------------------------- engine 2: glyph render --

-- One line's glyph rows with per-character highlights: rows[r] is a
-- list of { text, hl } chunks. rowhl maps byte -> group. cursor_hls
-- maps byte -> group for the big cursors (the primary one, every
-- multicursor): that character's cells are painted in the cursor's
-- colors on EVERY row. sel, when the line crosses the Visual
-- selection, is { from, to } (0-based bytes, inclusive) — those
-- characters get the Visual colors instead. Whitespace inherits the
-- previous TOKEN color so chunks merge — never a cursor's or the
-- selection's, which is what keeps the big cursor one letter wide on
-- a run of spaces: the spaces after it keep the color of the token
-- before the cursor, not the cursor's color.
local function glyph_build(line, scale, tabstop, rowhl, cursor_hls, sel)
  local _, rows_n = glyph_dims(scale)
  local rows, last, carry = {}, {}, {}
  for r = 1, rows_n do
    rows[r] = {}
  end
  local function push(r, text, hl)
    local t = rows[r]
    if #t > 0 and last[r] == hl then
      t[#t][1] = t[#t][1] .. text
    else
      t[#t + 1] = { text, hl }
      last[r] = hl
    end
  end

  local col, byte = 0, 0
  for _, ch in ipairs(vim.fn.split(line, '\\zs')) do
    local nbytes = #ch
    local reps = 1
    if ch == '\t' then
      reps = tabstop - (col % tabstop)
      ch = ' '
      col = col + reps
    else
      col = col + math.max(vim.fn.strdisplaywidth(ch), 1)
    end
    local g = glyph_lines(ch, scale)
    local is_space = ch == ' '
    local cur_hl = cursor_hls and cursor_hls[byte]
    local in_sel = sel and byte >= sel[1] and byte <= sel[2]
    for r = 1, rows_n do
      local hl
      if cur_hl then
        hl = cur_hl
      elseif in_sel then
        hl = 'GliterZoomVisual'
      else
        if is_space and carry[r] then
          hl = carry[r]
        else
          hl = resolve_hl(rowhl and rowhl[byte]) or cfg.glyph.hl_group
        end
        carry[r] = hl -- only a token's color is inheritable
      end
      for _ = 1, reps do
        push(r, g[r], hl)
      end
    end
    byte = byte + nbytes
  end
  return rows
end

-- lines already built for this tick/scale are reused, so scrolling
-- only pays for the lines new to the viewport (build_font resets it;
-- the table itself is declared up with the font)

-- the built-in multicursors (Neovim 0.13) are extmarks in this
-- namespace — the same id the built-in uses, so its cursors are ours
local mc_ns = vim.api.nvim_create_namespace('nvim.multicursor')

-- the Visual selection while it is on (the current window's): the
-- mode plus the anchor (v) and the cursor as lnum / byte-col pairs;
-- nil outside Visual mode
local function visual_state()
  local m = vim.fn.mode()
  if m ~= 'v' and m ~= 'V' and m ~= '\22' then
    return nil
  end
  local v, c = vim.fn.getpos('v'), vim.fn.getpos('.')
  return { m = m, vl = v[2], vc = v[3], cl = c[2], cc = c[3] }
end

-- the 1-based virtual column of a 1-based byte column on `line`
-- (tabs expand to the tabstop, the way the renderer expands them)
local function byte_to_virtcol(line, byte1, tabstop)
  local c, b = 1, 0
  for _, ch in ipairs(vim.fn.split(line, '\\zs')) do
    if b >= byte1 - 1 then
      return c
    end
    local w = ch == '\t' and (tabstop - ((c - 1) % tabstop)) or math.max(vim.fn.strdisplaywidth(ch), 1)
    c = c + w
    b = b + #ch
  end
  return c
end

-- the byte range (0-based, inclusive) the Visual selection paints on
-- lnum: nil when the line is not part of it
local function visual_sel(vis, lnum, line, tabstop)
  local l1, l2 = math.min(vis.vl, vis.cl), math.max(vis.vl, vis.cl)
  if lnum < l1 or lnum > l2 then
    return nil
  end
  if vis.m == 'V' then -- linewise: the whole line
    return { 0, math.huge }
  end
  if vis.m == 'v' then -- charwise: anchor and cursor edges, inclusive
    local from, to = 0, math.huge
    if lnum == vis.vl and lnum == vis.cl then
      from, to = math.min(vis.vc, vis.cc) - 1, math.max(vis.vc, vis.cc) - 1
    elseif lnum == vis.cl then
      if vis.cl < vis.vl then from = vis.cc - 1 else to = vis.cc - 1 end
    elseif lnum == vis.vl then
      if vis.vl < vis.cl then from = vis.vc - 1 else to = vis.vc - 1 end
    end
    return { from, to }
  end
  -- blockwise: the column band between the anchor's and the cursor's
  -- virtual columns, on every line of the block
  local c1, c2 = math.min(vis.avc, vis.cvc), math.max(vis.avc, vis.cvc)
  local from, to, c, b = nil, nil, 1, 0
  for _, ch in ipairs(vim.fn.split(line, '\\zs')) do
    local w = ch == '\t' and (tabstop - ((c - 1) % tabstop)) or math.max(vim.fn.strdisplaywidth(ch), 1)
    if c + w - 1 >= c1 and c <= c2 then
      from = from or b
      to = b
    end
    c = c + w
    b = b + #ch
  end
  if not from then
    return nil
  end
  return { from, to }
end

local function render_glyph(buf, force)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local scale = glyph_levels[buf]
  if not scale then
    glyph_sig[buf] = nil
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    return
  end
  local ts = vim.bo[buf].tabstop
  local total = vim.api.nvim_buf_line_count(buf)
  local use_syntax = vim.bo[buf].syntax ~= ''
  local skip_cur = cfg.glyph.skip_cursor_line
  local _, rows_n = glyph_dims(scale)

  local cache = glyph_built[buf]
  if not cache or cache.tick ~= vim.b[buf].changedtick or cache.scale ~= scale or cache.ts ~= ts then
    cache = { tick = vim.b[buf].changedtick, scale = scale, ts = ts, rows = {} }
    glyph_built[buf] = cache
  end

  -- the current window (when it shows this buffer) goes FIRST: lines
  -- are rendered once per pass, so its cursor gets the big-cursor
  -- rendering when several windows share the buffer
  local wins = vim.fn.win_findbuf(buf)
  local first = vim.api.nvim_get_current_win()
  for i, w in ipairs(wins) do
    if w == first then
      table.remove(wins, i)
      table.insert(wins, 1, w)
      break
    end
  end

  -- what moves without a text change, collected up front: every
  -- multicursor (the extmarks in the built-in's namespace) and the
  -- Visual selection of the current window
  local mcurs = {} -- [lnum] = { [byte] = true }
  local mc_ok, mc_marks = pcall(vim.api.nvim_buf_get_extmarks, buf, mc_ns, 0, -1, {})
  if mc_ok then
    for _, m in ipairs(mc_marks or {}) do
      local l = mcurs[m[2] + 1] or {}
      mcurs[m[2] + 1] = l
      l[m[3]] = true
    end
  end
  local vis = visual_state()
  if vis and vim.api.nvim_win_get_buf(first) ~= buf then
    vis = nil -- the selection lives in another buffer's window
  end
  if vis and vis.m == '\22' then -- blockwise: the two column edges
    local aline = vim.api.nvim_buf_get_lines(buf, vis.vl - 1, vis.vl, false)[1] or ''
    local cline = vim.api.nvim_buf_get_lines(buf, vis.cl - 1, vis.cl, false)[1] or ''
    vis.avc = byte_to_virtcol(aline, vis.vc, ts)
    vis.cvc = byte_to_virtcol(cline, vis.cc, ts)
  end

  -- the render's signature: everything the pass depends on beyond the
  -- text itself. An event that changed none of it — the idle SafeState
  -- pass, say — re-renders nothing; the marks from the last identical
  -- pass are still exactly right
  local wininfo = {}
  local mckeys = {}
  for lnum, l in pairs(mcurs) do
    for b in pairs(l) do
      mckeys[#mckeys + 1] = lnum .. '.' .. b
    end
  end
  table.sort(mckeys)
  local sig = {
    vim.b[buf].changedtick, scale, ts, table.concat(mckeys, ','),
    vis and (vis.m .. vis.vl .. '.' .. vis.vc .. '.' .. vis.cl .. '.' .. vis.cc) or '',
  }
  for _, win in ipairs(wins) do
    local info = vim.api.nvim_win_call(win, function()
      return { vim.fn.line('w0'), vim.fn.line('w$'), vim.fn.line('.'), vim.fn.col('.') }
    end)
    wininfo[win] = info
    sig[#sig + 1] = table.concat(info, '.')
  end
  if not force and glyph_sig[buf] == table.concat(sig, '|') then
    return
  end
  glyph_sig[buf] = table.concat(sig, '|')

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  define_hl()
  local done = {}
  for _, win in ipairs(wins) do
    if saved_wrap[wrap_key(win, buf)] == nil then
      saved_wrap[wrap_key(win, buf)] = vim.wo[win].wrap
    end
    vim.wo[win].wrap = false -- overlays cannot wrap

    local info = wininfo[win]
    local s = math.max(1, info[1] - cfg.margin)
    local e = math.min(total, info[2] + cfg.margin)
    local cur = info[3]
    local curbyte = info[4] - 1 -- 0-based byte of the char under the cursor
    local lines = vim.api.nvim_buf_get_lines(buf, s - 1, e, false)

    local tsmap, ts_ok = ts_highlights(buf, s - 1, e, lines)

    vim.api.nvim_buf_call(buf, function()
      for i, line in ipairs(lines) do
        local lnum = s + i - 1
        -- empty lines keep their one-row height; separators should
        -- not grow with the text. The cursor line is transformed
        -- like every other line (glyph.skip_cursor_line keeps it
        -- real, reserving the height so nothing jumps).
        if not done[lnum] and line ~= '' then
          done[lnum] = true
          local opts = { hl_mode = 'replace' }
          if skip_cur and lnum == cur then
            local blank = {}
            for _ = 2, rows_n do
              blank[#blank + 1] = { { ' ', cfg.glyph.hl_group } }
            end
            opts.virt_lines = blank
          else
            local rowhl
            if ts_ok then
              rowhl = tsmap[lnum - 1]
            elseif use_syntax then
              rowhl = syn_row(lnum, line)
            end
            -- the big cursors — the primary one plus every
            -- multicursor on this line — and the Visual selection
            -- change with no text change, so their lines are rebuilt
            -- on every pass and never cached (the cached rows are
            -- the clean, cursor-less versions)
            local cursor_hls, sel = nil, nil
            if cfg.glyph.cursor then
              if lnum == cur then
                cursor_hls = { [curbyte] = 'GliterZoomCursor' }
              end
              if mcurs[lnum] then
                cursor_hls = cursor_hls or {}
                for b in pairs(mcurs[lnum]) do
                  if not cursor_hls[b] then
                    cursor_hls[b] = 'GliterZoomMCursor'
                  end
                end
              end
            end
            if vis then
              sel = visual_sel(vis, lnum, line, ts)
            end
            local rows
            if cursor_hls or sel then
              rows = glyph_build(line, scale, ts, rowhl, cursor_hls, sel)
            else
              rows = cache.rows[lnum]
              if not rows then
                rows = glyph_build(line, scale, ts, rowhl)
                cache.rows[lnum] = rows
              end
            end
            opts.virt_text = rows[1] -- the real line's cells become row 1
            opts.virt_text_pos = 'overlay'
            opts.virt_lines = vim.list_slice(rows, 2) -- text rows 2..n
          end
          vim.api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, opts)
        end
      end
    end)
  end
end

local function request_render(buf, moved)
  -- `moved` (a CursorMoved event): the glyph zoom must re-render — its
  -- big cursor walks with h/l; the style zoom skips the pass, nothing
  -- in it depends on the cursor
  if levels[buf] and not moved then
    render(buf)
  end
  if glyph_levels[buf] then
    render_glyph(buf)
  end
end

local function describe(level)
  if level == 0 then
    return 'off'
  end
  local style = style_for_level(level)
  if not style then
    return ('level %d (no style configured for it)'):format(level)
  end
  return ('%s (level %d, this buffer only)'):format(style, level)
end

---------------------------------------------------------------- api --

--- The style zoom level of the current buffer (0 = off, negative smaller).
---@return integer
function M.level()
  return levels[vim.api.nvim_get_current_buf()] or 0
end

--- Set the style zoom level of the current buffer, clamped to the
--- ladders' lengths; 0 turns it off and restores 'wrap'. Turning it
--- on turns the glyph zoom off (one engine at a time per buffer).
---@param level integer
function M.set_level(level)
  local buf = vim.api.nvim_get_current_buf()
  local max_l = #cfg.styles.zoom_in
  local min_l = -#cfg.styles.zoom_out
  level = math.max(min_l, math.min(max_l, level or 0))
  levels[buf] = level ~= 0 and level or nil
  if levels[buf] then
    glyph_levels[buf] = nil -- one engine at a time
  end

  if not (levels[buf] or glyph_levels[buf]) then
    restore_stray_wrap()
  end
  render(buf)
  vim.cmd('redraw!')
  say('zoom: ' .. describe(level))
end

--- <Leader>= / :GliterZoomIn — grow, following the engine that is
--- on: with the glyph zoom on, one glyph scale bigger (a count steps
--- that many); otherwise one style level in, this buffer only.
---@param count? integer how many steps (the mapping's count by default)
function M.increase(count)
  local buf = vim.api.nvim_get_current_buf()
  local n = math.max(1, tonumber(count) or tonumber(vim.v.count1) or 1)
  if glyph_levels[buf] then
    if glyph_levels[buf] >= cfg.glyph.max_scale then
      return say(('zoom: glyphs already at the biggest scale (x%d)'):format(cfg.glyph.max_scale))
    end
    return M.glyph_set(glyph_levels[buf] + n)
  end
  if M.level() >= #cfg.styles.zoom_in then
    return say('zoom: already at the biggest level')
  end
  M.set_level(M.level() + n)
end

--- <Leader>- / :GliterZoomOut — shrink, following the engine that is
--- on: with the glyph zoom on, one glyph scale smaller, and past the
--- small x1 it turns the glyphs off; otherwise one style level back
--- out (negative = the smaller styles, small caps by default).
---@param count? integer how many steps (the mapping's count by default)
function M.decrease(count)
  local buf = vim.api.nvim_get_current_buf()
  local n = math.max(1, tonumber(count) or tonumber(vim.v.count1) or 1)
  if glyph_levels[buf] then
    local target = glyph_levels[buf] - n
    if target < 1 then
      return M.glyph_set(0) -- shrink past x1 turns it off
    end
    return M.glyph_set(target)
  end
  if M.level() <= -#cfg.styles.zoom_out then
    return say('zoom: already at the smallest level')
  end
  M.set_level(M.level() - n)
end

--- <Leader>0 / :GliterZoomReset — off, 'wrap' restored.
function M.reset()
  if M.level() == 0 and M.glyph_level() == 0 then
    say('zoom: nothing to reset')
    return
  end
  if M.level() ~= 0 then
    M.set_level(0)
  end
  if M.glyph_level() ~= 0 then
    M.glyph_set(0)
  end
end

--- The glyph zoom scale of the current buffer (0 = off).
---@return integer
function M.glyph_level()
  return glyph_levels[vim.api.nvim_get_current_buf()] or 0
end

--- Set the glyph zoom scale of the current buffer (0 = off, 'wrap'
--- restored; otherwise clamped to [1, glyph.max_scale] — 1 is the
--- small thin size, 2 = 6x6, ...). Turning it on
--- turns the style zoom off (one engine at a time per buffer).
---@param scale integer
function M.glyph_set(scale)
  local buf = vim.api.nvim_get_current_buf()
  scale = tonumber(scale) or 0
  if scale > 0 then
    scale = math.max(1, math.min(cfg.glyph.max_scale, scale))
  end
  glyph_levels[buf] = scale > 0 and scale or nil
  if glyph_levels[buf] then
    glyph_last[buf] = scale
    levels[buf] = nil -- one engine at a time
    pcall(vim.cmd, 'normal! zz') -- keep the cursor line on screen
  end

  if not (levels[buf] or glyph_levels[buf]) then
    restore_stray_wrap()
  end
  render_glyph(buf)
  vim.cmd('redraw!')
  if scale > 0 then
    say(('zoom: glyphs x%d%s (this buffer only)'):format(scale,
      scale == 1 and ' (small)' or ''))
  else
    say('zoom: off')
  end
end

--- <Leader>z / :GliterZoomGlyph — toggle the glyph zoom: off goes
--- back to the buffer's last scale (1, the small size, by default);
--- on goes off. A count (2<Leader>z, 3<Leader>z) sets the scale
--- directly, and toggles off when it is already at that scale.
function M.glyph_toggle(count)
  count = (type(count) == 'number' and count > 0) and count or nil
  local buf = vim.api.nvim_get_current_buf()
  local cur = glyph_levels[buf]
  if not count then
    if cur then
      return M.glyph_set(0)
    end
    return M.glyph_set(glyph_last[buf] or 1)
  end
  if cur and cur == count then
    return M.glyph_set(0)
  end
  return M.glyph_set(count)
end

--- For the statusline: ` Z2` at style level 2, ` G3` at glyph scale 3,
--- '' when nothing is zoomed. Use from the buffer's own window.
function M.statusline()
  local buf = vim.api.nvim_get_current_buf()
  if glyph_levels[buf] then
    return (' G%d'):format(glyph_levels[buf])
  end
  if levels[buf] then
    return (' Z%d'):format(levels[buf])
  end
  return ''
end

---------------------------------------------------------------- setup --

---@param opts? table
function M.setup(opts)
  M.did_setup = true
  opts = opts or {}
  cfg = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts)
  -- the ladders are LISTS the user adds to or removes from: never
  -- merge old entries back in
  if opts.styles then
    if opts.styles.zoom_in then
      cfg.styles.zoom_in = opts.styles.zoom_in
    end
    if opts.styles.zoom_out then
      cfg.styles.zoom_out = opts.styles.zoom_out
    end
  end
  -- unknown style names say so once, at setup
  for _, ladder in ipairs({ cfg.styles.zoom_in, cfg.styles.zoom_out }) do
    for _, name in ipairs(ladder) do
      if not resolve_style(name) then
        say(('zoom: unknown style %q — see :GliterZoomStyles'):format(name))
      end
    end
  end
  nui_state = 'unknown'
  NuiText = nil
  define_hl()
  build_font() -- raw + cfg.glyph.font, and the glyph cache cleared

  if cfg.keys then
    if cfg.keys.increase then
      vim.keymap.set('n', cfg.keys.increase, M.increase,
        { desc = 'gliter.zoom: grow — the glyph scale while the glyph zoom is on, the style level otherwise' })
    end
    if cfg.keys.decrease then
      vim.keymap.set('n', cfg.keys.decrease, M.decrease,
        { desc = 'gliter.zoom: shrink — the glyph scale while the glyph zoom is on (past x1 off), the style level otherwise' })
    end
    if cfg.keys.reset then
      vim.keymap.set('n', cfg.keys.reset, M.reset,
        { desc = 'gliter.zoom: both engines off' })
    end
    if cfg.keys.glyph then
      vim.keymap.set('n', cfg.keys.glyph, function()
        M.glyph_toggle(vim.v.count1 > 1 and vim.v.count1 or nil)
      end, { desc = 'gliter.zoom: toggle the glyph zoom (count = scale: 1 = the small thin size, 2 = 6x6, .. — shape kept at every scale, no stretching)' })
    end
  end

  vim.api.nvim_create_user_command('GliterZoomIn', M.increase, { desc = 'gliter.zoom: grow — glyph scale while the glyph zoom is on, style level otherwise' })
  vim.api.nvim_create_user_command('GliterZoomOut', M.decrease, { desc = 'gliter.zoom: shrink — glyph scale while the glyph zoom is on, style level otherwise' })
  vim.api.nvim_create_user_command('GliterZoomReset', M.reset, { desc = 'gliter.zoom: off' })
  vim.api.nvim_create_user_command('GliterZoomSet', function(o)
    M.set_level(tonumber(o.args) or 0)
  end, { nargs = 1, desc = 'gliter.zoom: set the style level (0 = off, negative = smaller)' })
  vim.api.nvim_create_user_command('GliterZoomState', function()
    if M.glyph_level() > 0 then
      say(('zoom: glyphs x%d (this buffer only)'):format(M.glyph_level()))
    else
      say('zoom: ' .. describe(M.level()))
    end
  end, { desc = 'gliter.zoom: the current level' })
  vim.api.nvim_create_user_command('GliterZoomGlyph', function(o)
    local n = tonumber(o.args)
    if n and n <= 0 then
      M.glyph_set(0)
    elseif n then
      M.glyph_set(n)
    else
      M.glyph_toggle()
    end
  end, {
    nargs = '?',
    desc = 'gliter.zoom: toggle the glyph zoom (no arg), or set the scale (1 = the small thin size, 2 = 6x6, .. max, 0 = off)',
  })

  -- :GliterZoomStyles — every style that ships, with a live example:
  -- the whole menu of fonts the two ladders draw from
  vim.api.nvim_create_user_command('GliterZoomStyles', function()
    local word = vim.fn.expand('<cword>')
    if word == '' or not word:find('^[%w]+$') then
      word = 'Example'
    end
    local names = {
      'bold', 'italic', 'bold_italic', 'script', 'bold_script',
      'fraktur', 'bold_fraktur', 'double_struck', 'sans', 'sans_bold',
      'sans_italic', 'sans_bold_italic', 'mono', 'smallcaps',
      'superscript', 'circled', 'squared', 'underlined', 'fullwidth',
    }
    local alias_of = {}
    for a, target in pairs(aliases) do
      alias_of[target] = alias_of[target] or {}
      alias_of[target][#alias_of[target] + 1] = a
    end
    local lines = {
      ('gliter.zoom styles — %s, rendered live; put any name in styles.zoom_in / zoom_out:'):format(word),
      ('  zoom_in  = { %s }'):format(table.concat(
        vim.tbl_map(function(s) return ('%q'):format(s) end, cfg.styles.zoom_in), ', ')),
      ('  zoom_out = { %s }'):format(table.concat(
        vim.tbl_map(function(s) return ('%q'):format(s) end, cfg.styles.zoom_out), ', ')),
    }
    for _, name in ipairs(names) do
      local sample = transform_line(word .. ' 123', name, 8)
      local aka = alias_of[name]
      local suffix = aka and ('  (aka ' .. table.concat(aka, ', ') .. ')') or ''
      lines[#lines + 1] = ('  %-16s %s%s'):format(name, sample, suffix)
    end
    lines[#lines + 1] = '  fullwidth and squared are 2 cells per char — columns shift under them'
    vim.api.nvim_echo(vim.tbl_map(function(l)
      return { l, 'None' }
    end, lines), true, {})
  end, { desc = 'gliter.zoom: every style, with a live example' })

  -- keep the overlays in sync with the editor. ModeChanged catches
  -- the Visual selection turning on and off; CursorMoved follows it
  -- while it extends
  local group = vim.api.nvim_create_augroup('GliterZoom', { clear = true })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'WinScrolled', 'WinResized', 'BufWinEnter', 'CursorMoved', 'CursorMovedI', 'ModeChanged' }, {
    group = group,
    callback = function(a)
      if a.event == 'BufWinEnter' then
        -- a buffer coming back to a window whose zoom went off while it
        -- was away: Vim's option stash re-applied the zoom's 'wrap =
        -- false' — put the remembered value back now that it is shown
        local win = vim.api.nvim_get_current_win()
        local key = wrap_key(win, a.buf)
        if saved_wrap[key] ~= nil and not (levels[a.buf] or glyph_levels[a.buf]) then
          vim.wo[win].wrap = saved_wrap[key]
          saved_wrap[key] = nil
        end
      end
      local moved = a.event == 'CursorMoved' or a.event == 'CursorMovedI'
      local bufs = { a.buf }
      if a.event == 'WinScrolled' or a.event == 'WinResized' then
        bufs = { vim.api.nvim_get_current_buf() }
        local w = tonumber(a.match)
        if w and vim.api.nvim_win_is_valid(w) then
          bufs[#bufs + 1] = vim.api.nvim_win_get_buf(w)
        end
      end
      for _, buf in ipairs(bufs) do
        if levels[buf] or glyph_levels[buf] then
          request_render(buf, moved)
        end
      end
    end,
  })
  -- the built-in multicursor commands (Q, q=, zq, ]C, …) place or
  -- remove cursors without moving the primary one; CmdAtom — the
  -- built-in's plugin hook, Neovim 0.13+ — is the one event they all
  -- fire
  if vim.fn.exists('##CmdAtom') == 1 then
    vim.api.nvim_create_autocmd('CmdAtom', {
      group = group,
      callback = function(a)
        if glyph_levels[a.buf] then
          render_glyph(a.buf) -- sig-skips when nothing moved
        end
      end,
    })
  end
  -- anything else that touched the cursors (a mapping clearing the
  -- namespace, …) is caught where the keys settle: the idle pass
  -- re-renders, or skips itself when nothing it depends on changed
  vim.api.nvim_create_autocmd('SafeState', {
    group = group,
    callback = function()
      local buf = vim.api.nvim_get_current_buf()
      if glyph_levels[buf] then
        render_glyph(buf)
      end
    end,
  })
  -- a colorscheme may wipe the style groups; put them back
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      define_hl()
      hl_cache = {}
      for buf in pairs(levels) do
        render(buf)
      end
      for buf in pairs(glyph_levels) do
        render_glyph(buf)
      end
    end,
  })
  -- a filetype change invalidates parsers and resolved groups
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    callback = function(a)
      hl_cache = {}
      glyph_built[a.buf] = nil -- the cached rows were colored by the old parser
      if levels[a.buf] then
        render(a.buf)
      end
      if glyph_levels[a.buf] then
        render_glyph(a.buf, true)
      end
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(a)
      levels[a.buf] = nil
      glyph_levels[a.buf] = nil
      glyph_last[a.buf] = nil
      glyph_built[a.buf] = nil
      glyph_sig[a.buf] = nil
      for key in pairs(saved_wrap) do
        if key:match(':' .. a.buf .. '$') then
          saved_wrap[key] = nil
        end
      end
    end,
  })

  return M
end

return M
