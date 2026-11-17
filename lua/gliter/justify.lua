--- gliter.justify — flush both margins: reflow the paragraph to the width,
--- then distribute the leftover spaces between the words so the right edge
--- comes out straight. `g=` on a paragraph (or a Visual selection), or
--- `:GliterTohtml`-style `:GliterJustify [width]` over a range — the last
--- line of every paragraph stays ragged, the way a justified paragraph in a
--- book does.
---
--- The lineage: Emacs `M-q` (fill.el, 1980s) has reflowed paragraphs since
--- before Vim existed, and Neovim ships the other half — the `justify`
--- dist plugin (Preben "Peppe" Guldberg, 1998), which pads lines in place
--- but never moves a word between them. gliter.justify is the two halves
--- together: the reflow of `M-q` (that is `gq`'s own word wrapping, done in
--- Lua so the cursor stays put) and the space distribution of justify.vim —
--- all lines but the last padded to the full width. `gww`/`gqq` still do
--- plain `gq` filling; this is the button for when you want the right edge
--- straight.
local M = {}

M.did_setup = false

M.defaults = {
  keys = {
    justify = 'g=', -- n: justify the paragraph around the cursor;
                    -- x: justify the selection
  },
  width = nil, -- nil: 'textwidth' when nonzero, else 80; a count or the
               -- :GliterJustify argument overrides both
}

M.options = vim.deepcopy(M.defaults)

---------------------------------------------------------------------------
-- the reflow, pure and testable
---------------------------------------------------------------------------

--- Greedy-wrap `words` to `width`, then distribute the slack of every line
--- but the last between its words. A single word wider than `width`, or a
--- line that cannot be stretched (one word), stays as it is. Exposed for
--- tests.
---@param words string[]
---@param width integer
---@return string[]
function M.justified_words(words, width)
  width = math.max(8, width)
  -- greedy wrap
  local lines, cur = {}, {}
  local curw = 0
  for _, w in ipairs(words) do
    if #cur == 0 then
      cur = { w }
      curw = #w
    elseif curw + 1 + #w <= width then
      cur[#cur + 1] = w
      curw = curw + 1 + #w
    else
      lines[#lines + 1] = cur
      cur = { w }
      curw = #w
    end
  end
  if #cur > 0 then
    lines[#lines + 1] = cur
  end
  -- justify every line but the last: split the slack across the gaps,
  -- the leftmost gaps taking the odd space
  local out = {}
  for i, line in ipairs(lines) do
    local text = table.concat(line, ' ')
    if i == #lines or #line == 1 or #text > width then
      out[#out + 1] = text
    else
      local slack = width - #text
      local gaps = #line - 1
      local base = math.floor(slack / gaps)
      local odd = slack % gaps
      local parts = {}
      for j, w in ipairs(line) do
        parts[#parts + 1] = w
        if j < #line then
          local pad = 1 + base + (j <= odd and 1 or 0)
          parts[#parts + 1] = string.rep(' ', pad)
        end
      end
      out[#out + 1] = table.concat(parts)
    end
  end
  return out
end

--- Expand tabs to `tabstop`-spaced columns (byte-safe for multibyte text).
---@param l string
---@param ts integer
---@return string
local function expand_tabs(l, ts)
  if not l:find('\t') then
    return l
  end
  local out, col, i = {}, 0, 1
  while i <= #l do
    local ch = l:sub(i, i)
    if ch == '\t' then
      local n = ts - col % ts
      out[#out + 1] = string.rep(' ', n)
      col = col + n
    else
      out[#out + 1] = ch
      col = col + 1
    end
    i = i + 1
  end
  return table.concat(out)
end

--- The lines of `lines`, reflowed to `width` and justified — tabs expanded,
--- a common leading indent kept on every line (and paid for out of the
--- width). Exposed for tests.
---@param lines string[]
---@param width integer
---@param tabstop integer
---@return string[]
function M.justified_lines(lines, width, tabstop)
  tabstop = math.max(1, tabstop or 8)
  local expanded = {}
  for _, l in ipairs(lines) do
    expanded[#expanded + 1] = expand_tabs(l, tabstop)
  end
  -- the indent: the leading whitespace shared by every non-blank line
  local indent = nil
  for _, l in ipairs(expanded) do
    if l:match('%S') then
      local lead = l:match('^%s*') or ''
      if indent == nil or #lead < #indent then
        indent = lead
      end
    end
  end
  indent = indent or ''
  local words = {}
  for _, l in ipairs(expanded) do
    for w in l:gmatch('%S+') do
      words[#words + 1] = w
    end
  end
  local body = M.justified_words(words, width - #indent)
  if #indent == 0 then
    return body
  end
  local out = {}
  for _, l in ipairs(body) do
    out[#out + 1] = indent .. l
  end
  return out
end

---------------------------------------------------------------------------
-- the paragraph, the selection, the buffer
---------------------------------------------------------------------------

--- The line range of the paragraph around `lnum`: the contiguous non-blank
--- lines around it.
---@param lnum integer
---@return integer, integer
function M.paragraph_around(lnum)
  local count = vim.api.nvim_buf_line_count(0)
  local first, last = lnum, lnum
  while first > 1 and vim.fn.getline(first - 1):match('%S') do
    first = first - 1
  end
  while last < count and vim.fn.getline(last + 1):match('%S') do
    last = last + 1
  end
  return first, last
end

--- Justify lines `from..to` (1-based, inclusive) of the current buffer to
--- `width`. The cursor stays on its line (clamped into the new range).
---@param from integer
---@param to integer
---@param width integer
function M.range(from, to, width)
  local lines = vim.api.nvim_buf_get_lines(0, from - 1, to, false)
  local out = M.justified_lines(lines, width, vim.bo.tabstop)
  vim.api.nvim_buf_set_lines(0, from - 1, to, false, out)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if row < from or row > from + #out - 1 then
    vim.api.nvim_win_set_cursor(0, { math.min(math.max(row, from), from + #out - 1), 0 })
  end
end

local function width_of(count, arg)
  if arg and arg:match('^%d+$') then
    return tonumber(arg)
  end
  if count and count > 0 then
    return count
  end
  if M.options.width then
    return M.options.width
  end
  return vim.bo.textwidth > 0 and vim.bo.textwidth or 80
end

---------------------------------------------------------------------------
-- setup: the command and the keys
---------------------------------------------------------------------------

function M.setup(opts)
  M.did_setup = true
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})

  vim.api.nvim_create_user_command('GliterJustify', function(o)
    local from, to = o.line1, o.line2
    if o.range == 0 then
      from, to = M.paragraph_around(from)
    end
    -- the width: the argument (:GliterJustify 60), else 'textwidth'/80
    M.range(from, to, width_of(nil, o.fargs[1]))
  end, {
    range = true,
    nargs = '?',
    desc = 'gliter.justify: reflow and justify [range] (the paragraph by default) to [width] (textwidth/80 by default)',
  })

  local key = M.options.keys and M.options.keys.justify
  if key then
    vim.keymap.set('n', key, function()
      local from, to = M.paragraph_around(vim.fn.line('.'))
      M.range(from, to, width_of(vim.v.count, nil))
    end, { silent = true, desc = 'gliter.justify: justify the paragraph' })
    vim.keymap.set('x', key, function()
      local a, b = vim.fn.line('v'), vim.fn.line('.')
      if a > b then
        a, b = b, a
      end
      vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
      M.range(a, b, width_of(vim.v.count, nil))
    end, { silent = true, desc = 'gliter.justify: justify the selection' })
  end
  return M
end

return M
