--- Softened colors for netrw, Emacs-dired style (see netrw.lua's
--- `soft_colors` option). Two jobs:
---
---  * netrw's OWN listing colors: netrwDir, netrwExe, netrwSymLink, ...
---   are theme-bright — a saturated blue that shouts. They are re-pointed
---   at a curated, muted palette — dired's restraint: directories a calm
---   blue (bold, like dired-directory), symlinks a quiet cyan,
---   executables a settled green, metadata a gray that recedes.
---  * the custom listing's ANSI colors (color.lua): every color a
---   `--color=always` command sends is a terminal-bright one; the same
---   softening pass is run on each of them, so the listing a command
---   paints looks like it was painted for a colorscheme, not a console.
---
--- The softening itself is a background-aware HSV pass: saturation is
--- scaled down and value lifted into a comfortable band on dark
--- backgrounds (or lowered on light ones), so any color — xterm's,
--- truecolor, a theme's — comes out a pastel that keeps its hue. Pure
--- grays stay gray. `setup { soft_colors = false }` turns all of it off:
--- netrw's groups go back to the theme's, and the ANSI colors are shown
--- exactly the way the terminal would.
local M = {}

local config = require('gliter.netrw.config')

--- @param hex string #rrggbb
--- @return number h 0..360
--- @return number s 0..1
--- @return number v 0..1
local function hex2hsv(hex)
  local r = tonumber(hex:sub(2, 3), 16) / 255
  local g = tonumber(hex:sub(4, 5), 16) / 255
  local b = tonumber(hex:sub(6, 7), 16) / 255
  local mx = math.max(r, g, b)
  local mn = math.min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then
      h = ((g - b) / d) % 6
    elseif mx == g then
      h = (b - r) / d + 2
    else
      h = (r - g) / d + 4
    end
    h = h * 60
  end
  return h, mx == 0 and 0 or d / mx, mx
end

--- @param h number 0..360
--- @param s number 0..1
--- @param v number 0..1
--- @return string #rrggbb
local function hsv2hex(h, s, v)
  local c = v * s
  local x = c * (1 - math.abs((h / 60) % 2 - 1))
  local m = v - c
  local r, g, b
  if h < 60 then
    r, g, b = c, x, 0
  elseif h < 120 then
    r, g, b = x, c, 0
  elseif h < 180 then
    r, g, b = 0, c, x
  elseif h < 240 then
    r, g, b = 0, x, c
  elseif h < 300 then
    r, g, b = x, 0, c
  else
    r, g, b = c, 0, x
  end
  return ('#%02x%02x%02x'):format(
    math.floor((r + m) * 255 + 0.5),
    math.floor((g + m) * 255 + 0.5),
    math.floor((b + m) * 255 + 0.5)
  )
end

local function clamp(n, lo, hi)
  return math.max(lo, math.min(hi, n))
end

--- One color, softened for the current 'background': saturation scaled
--- down, value pulled into a band that sits comfortably against the
--- background — pastel on dark, deep-and-muted on light. Grays stay gray.
--- This is exposed for color.lua, which runs every ANSI color through it.
---@param hex string #rrggbb
---@return string #rrggbb
function M.color(hex)
  if config.options.soft_colors == false or not hex:match('^#%x%x%x%x%x%x$') then
    return hex
  end
  local h, s, v = hex2hsv(hex)
  if vim.o.background == 'light' then
    return hsv2hex(h, clamp(s * 0.60, 0, 0.55), clamp(0.28 + 0.20 * v, 0.28, 0.48))
  end
  return hsv2hex(h, clamp(s * 0.45, 0, 0.50), clamp(0.58 + 0.22 * v, 0.58, 0.80))
end

-- The curated palette for netrw's own groups: identity hues at medium
-- strength; `color()` adapts each to the background. Missing groups keep
-- whatever the colorscheme gave them.
--   directories  dired-directory's calm blue, bold
--   symlinks     dired-symlink's quiet cyan
--   executables  a settled green
--   specials     warm amber; archives a soft red
--   metadata     grays that recede (size, date, tree bars)
local NETRW_HL = {
  netrwDir = { fg = '#4a7bd0', bold = true },
  netrwSymLink = { fg = '#35a0b5' },
  netrwExe = { fg = '#48a048' },
  netrwSpecial = { fg = '#c08a3e' },
  netrwSpecFile = { fg = '#c08a3e' },
  netrwCompress = { fg = '#c05a5a' },
  netrwCoreDump = { fg = '#c05a5a' },
  netrwBak = { fg = '#909090' },
  netrwData = { fg = '#9a8bc8' },
  netrwHdr = { fg = '#9a8bc8' },
  netrwLib = { fg = '#948d80' },
  netrwObj = { fg = '#948d80' },
  netrwPix = { fg = '#8aa4c0' },
  netrwDoc = { fg = '#948d80' },
  netrwLex = { fg = '#948d80' },
  netrwYacc = { fg = '#948d80' },
  netrwMakeFile = { fg = '#c08a3e' },
  netrwTags = { fg = '#948d80' },
  netrwTilde = { fg = '#909090' },
  netrwTmp = { fg = '#909090' },
  netrwLink = { fg = '#6fa0b0' },
  netrwSlash = { fg = '#8a8a8a' },
  netrwSizeDate = { fg = '#8a8a8a' },
  netrwDateSep = { fg = '#7a7a7a' },
  netrwTimeSep = { fg = '#7a7a7a' },
  netrwTreeBar = { fg = '#707070' },
  netrwTreeBarSpace = { fg = '#707070' },
}

--- Point netrw's own listing groups at the soft palette. Called at setup
--- (before netrw's `hi def link` runs, so the definitions win) and again
--- on every colorscheme change (they are re-asserted after the theme).
function M.apply_netrw()
  if config.options.soft_colors == false then
    return
  end
  for name, spec in pairs(NETRW_HL) do
    local out = {}
    for k, v in pairs(spec) do
      out[k] = k == 'fg' and M.color(v) or v
    end
    pcall(vim.api.nvim_set_hl, 0, name, out)
  end
end

return M
