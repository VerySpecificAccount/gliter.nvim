--- The custom listing in color (see custom.lua): commands asked for their
--- colored output — `ls -ltrhF --color=always`, `tree -C` — send ANSI
--- escape sequences, which a terminal turns into colors and a plain pipe
--- would leave as garbage on the line. The escapes are taken out of the
--- text (the listing parser and every key read plain bytes; a `/` search
--- matches the clean name), and what each run of them colored comes back
--- as a highlight over exactly those bytes: the listing looks the way it
--- does in a terminal — the way Emacs' dired shows `ls --color=always`.
---
--- The SGR codes covered: 0 reset; 1/3/4/7/9 and 22/23/24/27/29 the
--- attributes; 30-37/90-97 and 40-47/100-107 the sixteen palette colors
--- (xterm's standard RGB — fixed, the way the terminal shows them, so a
--- colorscheme does not reroute them); 38;5;N / 38;2;R;G;B (and 48;...)
--- the 256-color cube and truecolor. Every other escape (cursor moves,
--- fonts) is stripped and ignored. The highlight ranges sit below
--- gliter's own marks — where an entry carries one, the mark's highlight
--- ([copy], [delete], ...) names the reason the entry is lit.
local M = {}

local ns = vim.api.nvim_create_namespace('gliter_netrw_color')

-- xterm's sixteen ANSI colors, as hex.
local BASE16 = {
  [0] = '#000000', '#cd0000', '#00cd00', '#cdcd00', '#0000ee', '#cd00cd', '#00cdcd', '#e5e5e5',
  '#7f7f7f', '#ff0000', '#00ff00', '#ffff00', '#5c5cff', '#ff00ff', '#00ffff', '#ffffff',
}

local function rgb_hex(r, g, b)
  return ('#%02x%02x%02x'):format(r, g, b)
end

--- xterm's 256-color palette, as hex: the base sixteen, the 6×6×6 cube,
--- the 24-step grayscale.
local function hex256(n)
  n = math.max(0, math.min(255, math.floor(tonumber(n) or 0)))
  if n < 16 then
    return BASE16[n]
  end
  if n < 232 then
    local c = n - 16
    local level = { 0, 95, 135, 175, 215, 255 }
    return rgb_hex(level[math.floor(c / 36) + 1], level[math.floor(c / 6) % 6 + 1], level[c % 6 + 1])
  end
  local v = 8 + 10 * (n - 232)
  return rgb_hex(v, v, v)
end

--- One SGR parameter list into the running highlight state; 0 resets it.
--- Returns the (possibly new) state table.
local function apply_sgr(params, spec)
  local i = 1
  while i <= #params do
    local p = params[i]
    if p == 0 then
      spec = {}
    elseif p == 1 then
      spec.bold = true
    elseif p == 3 then
      spec.italic = true
    elseif p == 4 then
      spec.underline = true
    elseif p == 7 then
      spec.reverse = true
    elseif p == 9 then
      spec.strikethrough = true
    elseif p == 22 then
      spec.bold = nil
    elseif p == 23 then
      spec.italic = nil
    elseif p == 24 then
      spec.underline = nil
    elseif p == 27 then
      spec.reverse = nil
    elseif p == 29 then
      spec.strikethrough = nil
    elseif p == 39 then
      spec.fg = nil
    elseif p == 49 then
      spec.bg = nil
    elseif p >= 30 and p <= 37 then
      spec.fg = BASE16[p - 30]
    elseif p >= 40 and p <= 47 then
      spec.bg = BASE16[p - 40]
    elseif p >= 90 and p <= 97 then
      spec.fg = BASE16[p - 90 + 8]
    elseif p >= 100 and p <= 107 then
      spec.bg = BASE16[p - 100 + 8]
    elseif p == 38 or p == 48 then
      local key = p == 38 and 'fg' or 'bg'
      if params[i + 1] == 5 and params[i + 2] then
        spec[key] = hex256(params[i + 2])
        i = i + 2
      elseif params[i + 1] == 2 and params[i + 2] and params[i + 3] and params[i + 4] then
        spec[key] = rgb_hex(params[i + 2], params[i + 3], params[i + 4])
        i = i + 4
      end
    end
    i = i + 1
  end
  return spec
end

--- One line of command output: the plain text (every escape sequence
--- removed) and the colored runs on it — `{ from, to, spec }` byte spans,
--- 0-based, half-open; a run is emitted only where the state colors
--- something, so uncolored stretches keep netrw's own syntax.
---@param line string
---@return string plain, { from: integer, to: integer, spec: table }[] runs
function M.strip(line)
  local plain, runs = {}, {}
  local spec = {}
  local run_start, len = 0, 0 -- byte offsets: into `line` for scans, into `plain` for runs
  local i, n = 1, #line
  while i <= n do
    local c = line:byte(i)
    if c == 27 then
      local j = i + 1
      if line:byte(j) == 0x5B then -- [ : a CSI sequence
        j = j + 1
        while j <= n and line:byte(j) >= 0x30 and line:byte(j) <= 0x3F do
          j = j + 1
        end
        while j <= n and line:byte(j) >= 0x20 and line:byte(j) <= 0x2F do
          j = j + 1
        end
        if j <= n then
          local final = line:byte(j)
          if len > run_start and next(spec) then
            runs[#runs + 1] = { from = run_start, to = len, spec = vim.tbl_extend('force', {}, spec) }
          end
          if final == 0x6D then -- m: the parameters become the state
            local params = {}
            for num in line:sub(i + 2, j - 1):gmatch('%d+') do
              params[#params + 1] = tonumber(num) or 0
            end
            if #params == 0 then
              params[1] = 0
            end
            spec = apply_sgr(params, spec)
          end
          run_start = len
          i = j + 1
        else
          i = i + 1 -- incomplete escape at the line's end: drop the ESC
        end
      else
        i = i + 1 -- a lone ESC: drop it
      end
    else
      len = len + 1
      plain[#plain + 1] = line:sub(i, i)
      i = i + 1
    end
  end
  if len > run_start and next(spec) then
    runs[#runs + 1] = { from = run_start, to = len, spec = vim.tbl_extend('force', {}, spec) }
  end
  return table.concat(plain), runs
end

local groups = {} ---@type table<string, string> spec key -> highlight group
local group_n = 0
local soft = require('gliter.netrw.soft')

--- The highlight group for a run's spec: created once per distinct spec
--- (GliterNetrwLsColorN), never deleted — the set of colors a command
--- uses is small and stable across a session's listings. While
--- `soft_colors` is on (the default) every color is softened first
--- (see soft.lua): the terminal-bright palette a `--color=always`
--- command sends becomes the pastel one Emacs' dired would show.
local function group(spec)
  if spec.fg then
    spec.fg = soft.color(spec.fg)
  end
  if spec.bg then
    spec.bg = soft.color(spec.bg)
  end
  local parts = {}
  for _, k in ipairs({ 'fg', 'bg', 'bold', 'italic', 'underline', 'reverse', 'strikethrough' }) do
    if spec[k] ~= nil then
      parts[#parts + 1] = k .. '=' .. tostring(spec[k])
    end
  end
  local key = table.concat(parts, ';')
  if not groups[key] then
    group_n = group_n + 1
    groups[key] = 'GliterNetrwLsColor' .. group_n
    vim.api.nvim_set_hl(0, groups[key], spec)
  end
  return groups[key]
end

--- Lay the runs onto the listing: extmarks over the plain text, in this
--- module's namespace (cleared by the next render), below gliter's own
--- mark decorations in priority.
---@param buf integer
---@param from integer first listing line, 1-based
---@param runs_per_line { from: integer, to: integer, spec: table }[][]
function M.apply(buf, from, runs_per_line)
  for i, runs in ipairs(runs_per_line) do
    local row = from + i - 2
    for _, r in ipairs(runs) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, r.from, {
        end_col = r.to,
        hl_group = group(r.spec),
        priority = 100,
      })
    end
  end
end

--- Drop every color mark (the next render brings its own).
---@param buf integer
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

return M
