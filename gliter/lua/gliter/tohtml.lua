--- gliter.tohtml — the buffer (or the selection), out: HTML with the
--- buffer's own syntax colors, Markdown as a fenced code block, or PDF —
--- typeset by groff (1973's troff, still the best line-breaker in the
--- business), the syntax colors carried into it as \\m[] color requests.
---
--- Vim shipped :TOhtml (2html.vim, Bram Moolenaar, 2001) for a quarter
--- century; Neovim dropped it. gliter.tohtml brings the HTML side back in
--- Lua — same idea: every character's highlight becomes a <span> style —
--- and adds the two exports TOhtml never had. The HTML colors follow
--- whatever the classic syntax engine (:syn on) paints, the way TOhtml's
--- did.
---
---   :GliterTohtml            HTML, in a new buffer named <file>.html
---   :'<,'>GliterTohtml       the same, for the selection
---   :GliterTohtml md         Markdown: the range as one ```lang fence
---   :GliterTohtml pdf        PDF through groff -Tpdf -ms, written next to
---                            the source as <file>.pdf (groff 1.22+, the
---                            pdf device, must be on $PATH; colors, bold
---                            and italic carried over; lines longer than
---                            pdf_width split hard)
---
--- The Emacs side of the lineage is htmlize.el (Hrvoje Niksic, 1997),
--- which has been exporting buffers with their faces to HTML since before
--- Neovim existed.
local M = {}

M.did_setup = false

M.defaults = {
  groff = 'groff', -- the pdf engine; false turns the pdf target off
  pdf_width = 100, -- display columns a pdf line gets before a hard split
  pdf_font_size = 8, -- points
}

M.options = vim.deepcopy(M.defaults)

---------------------------------------------------------------------------
-- the colors: per-character styles, the way synID sees them
---------------------------------------------------------------------------

-- The 16 ANSI colors (and their common names), for terminals where a
-- highlight carries a cterm color only.
local ANSI = {
  [0] = '000000', '800000', '008000', '808000', '000080', '800080', '008080',
  'c0c0c0', '808080', 'ff0000', '00ff00', 'ffff00', '0000ff', 'ff00ff',
  '00ffff', 'ffffff',
  black = '000000', darkred = '800000', darkgreen = '008000',
  brown = '808000', darkblue = '000080', darkmagenta = '800080',
  darkcyan = '008080', gray = 'c0c0c0', darkgray = '808080',
  red = 'ff0000', green = '00ff00', yellow = 'ffff00', blue = '0000ff',
  magenta = 'ff00ff', cyan = '00ffff', white = 'ffffff', lightgray = 'c0c0c0',
}

local function hex(color)
  if not color or color == '' then
    return nil
  end
  if color:sub(1, 1) == '#' then
    return color:sub(2)
  end
  local n = tonumber(color)
  if n then
    return ANSI[n]
  end
  return ANSI[color:lower()]
end

--- The style of one character: fg/bg hex (nil = inherit) and the flags.
---@param tid integer synIDtrans() of the character's group
---@return { fg: string?, bg: string?, bold: boolean, italic: boolean, underline: boolean }
local function style_of(tid)
  if tid == 0 then
    return { fg = nil, bg = nil, bold = false, italic = false, underline = false }
  end
  local u = vim.fn.synIDattr(tid, 'underline') == '1'
    or vim.fn.synIDattr(tid, 'undercurl') == '1'
  return {
    fg = hex(vim.fn.synIDattr(tid, 'fg#')) or hex(vim.fn.synIDattr(tid, 'fg')),
    bg = hex(vim.fn.synIDattr(tid, 'bg#')) or hex(vim.fn.synIDattr(tid, 'bg')),
    bold = vim.fn.synIDattr(tid, 'bold') == '1',
    italic = vim.fn.synIDattr(tid, 'italic') == '1',
    underline = u,
  }
end

local function style_key(s)
  return string.format('%s|%s|%d%d%d', s.fg or '', s.bg or '', s.bold and 1 or 0, s.italic and 1 or 0, s.underline and 1 or 0)
end

--- The styled runs of lines `from..to` (1-based, inclusive): one list of
--- `{ text, fg, bg, bold, italic, underline }` per line, UTF-8 kept whole.
--- Exposed for tests.
---@param from integer
---@param to integer
---@return table[] runs_per_line
function M.spans(from, to)
  local lines = vim.api.nvim_buf_get_lines(0, from - 1, to, false)
  local out = {}
  for lnum, line in ipairs(lines) do
    local runs, cur, curkey = {}, nil, nil
    local col = 1 -- byte index into line
    while col <= #line do
      local b = line:byte(col)
      local len = 1
      if b >= 0xf0 then
        len = 4
      elseif b >= 0xe0 then
        len = 3
      elseif b >= 0xc0 then
        len = 2
      end
      local style
      if not (b >= 0x80 and b <= 0xbf) then -- a lead byte (or plain ASCII)
        style = style_of(vim.fn.synIDtrans(vim.fn.synID(from + lnum - 1, col, 1)))
      end
      if not cur then
        style = style or { fg = nil, bg = nil, bold = false, italic = false, underline = false }
        cur = { text = '', fg = style.fg, bg = style.bg, bold = style.bold, italic = style.italic, underline = style.underline }
        curkey = style_key(style)
        runs[#runs + 1] = cur
      elseif style and style_key(style) ~= curkey then
        cur = { text = '', fg = style.fg, bg = style.bg, bold = style.bold, italic = style.italic, underline = style.underline }
        curkey = style_key(style)
        runs[#runs + 1] = cur
      end
      cur.text = cur.text .. line:sub(col, col + len - 1)
      col = col + len
    end
    out[#out + 1] = runs
  end
  return out
end

---------------------------------------------------------------------------
-- html
---------------------------------------------------------------------------

local function html_escape(s)
  return (s:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'))
end

--- The whole HTML document for the styled runs. Exposed for tests.
---@param spans table[] runs per line
---@param title string
---@return string[]
function M.html_document(spans, title)
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false }) or {}
  local tohex = function(c)
    return c and ('#%06x'):format(c) or nil
  end
  local bg = tohex(normal.bg) or '#ffffff'
  local fg = tohex(normal.fg) or '#000000'
  local function span_style(r)
    local parts = {}
    if r.fg then
      parts[#parts + 1] = 'color:#' .. r.fg
    end
    if r.bg then
      parts[#parts + 1] = 'background:#' .. r.bg
    end
    if r.bold then
      parts[#parts + 1] = 'font-weight:bold'
    end
    if r.italic then
      parts[#parts + 1] = 'font-style:italic'
    end
    if r.underline then
      parts[#parts + 1] = 'text-decoration:underline'
    end
    return #parts > 0 and (' style="' .. table.concat(parts, ';') .. '"') or ''
  end
  local out = {
    '<!DOCTYPE html>',
    '<html>',
    '<head>',
    '<meta charset="UTF-8">',
    '<title>' .. html_escape(title) .. '</title>',
    '<style>',
    'body { margin: 0; }',
    ('pre { font-family: monospace; font-size: 14px; background: %s; color: %s; padding: 12px; line-height: 1.35; }'):format(bg, fg),
    '</style>',
    '</head>',
    '<body>',
    '<pre>',
  }
  for _, runs in ipairs(spans) do
    local parts = {}
    for _, r in ipairs(runs) do
      if span_style(r) ~= '' then
        parts[#parts + 1] = '<span' .. span_style(r) .. '>' .. html_escape(r.text) .. '</span>'
      else
        parts[#parts + 1] = html_escape(r.text)
      end
    end
    out[#out + 1] = table.concat(parts)
  end
  table.insert(out, '</pre>')
  table.insert(out, '</body>')
  table.insert(out, '</html>')
  return out
end

---------------------------------------------------------------------------
-- markdown
---------------------------------------------------------------------------

--- The range as one fenced code block. Exposed for tests.
---@param from integer
---@param to integer
---@return string[]
function M.markdown_lines(from, to)
  local lang = vim.bo.filetype
  local lines = vim.api.nvim_buf_get_lines(0, from - 1, to, false)
  local out = { '```' .. lang }
  for _, l in ipairs(lines) do
    out[#out + 1] = l
  end
  out[#out + 1] = '```'
  return out
end

---------------------------------------------------------------------------
-- pdf: groff -ms with the colors as \\m[] requests
---------------------------------------------------------------------------

local function groff_escape(s)
  return (s:gsub('\\', '\\e'))
end

-- groff keeps color and font state across lines; groff_line tracks the
-- same state so every change is said out loud, and groff_document resets
-- it once before the first line
local groff_state = { color = nil, font = nil }

--- One pdf line: the runs escaped, colored and split at `width` display
--- columns. Color and font state is tracked the way groff tracks it —
--- it persists across output lines — so every change carries its own
--- `\m[...]`/`\f...` escape, a run with no color resets with `\m[]`, and a
--- hard split mid-run needs no re-issue. Exposed for tests.
---@param runs table[]
---@param width integer
---@return string[]
function M.groff_line(runs, width)
  local lines, out, used = {}, {}, 0
  local function flush()
    lines[#lines + 1] = '\\&' .. table.concat(out)
    out = {}
  end
  for _, r in ipairs(runs) do
    local text = groff_escape(r.text):gsub('\t', '        ')
    local color = r.fg and ('\\m[#' .. r.fg .. ']') or nil
    local font = r.bold and '\\fB' or (r.italic and '\\fI' or nil)
    local i = 1
    while i <= #text do
      local b = text:byte(i)
      local len = 1
      if b >= 0xf0 then
        len = 4
      elseif b >= 0xe0 then
        len = 3
      elseif b >= 0xc0 then
        len = 2
      end
      local ch = text:sub(i, i + len - 1)
      local w = vim.fn.strdisplaywidth(ch)
      if used + w > width and #out > 0 then
        flush()
        used = 0
      end
      if #out == 0 then
        -- the line's first cell: re-establish where we are — a color
        -- change (or the lack of one) must be said, groff keeps state
        -- across lines
        if color ~= groff_state.color then
          out[#out + 1] = color or '\\m[]'
          groff_state.color = color
        end
        if font ~= groff_state.font then
          out[#out + 1] = font or '\\fP'
          groff_state.font = font
        end
      elseif color ~= groff_state.color then
        out[#out + 1] = color or '\\m[]'
        groff_state.color = color
      end
      out[#out + 1] = ch
      used = used + w
      i = i + len
    end
  end
  if #out > 0 then
    flush()
  end
  if #lines == 0 then
    lines[1] = '\\&'
  end
  return lines
end

--- The groff -ms document for the styled runs. Exposed for tests.
---@param spans table[] runs per line
---@param title string
---@param width integer
---@param fontsize integer
---@return string[]
function M.groff_document(spans, title, width, fontsize)
  groff_state.color, groff_state.font = nil, nil
  local out = {
    '.\\\" generated by gliter.tohtml',
    '.TL',
    title,
    '.LP',
    '.nf',
    '.ft C',
    ('.ps %d'):format(fontsize),
  }
  for _, runs in ipairs(spans) do
    for _, l in ipairs(M.groff_line(runs, width)) do
      out[#out + 1] = l
    end
  end
  out[#out + 1] = '\\m[]'
  return out
end

---------------------------------------------------------------------------
-- the command
---------------------------------------------------------------------------

local function output_name(ext)
  local name = vim.fn.fnamemodify(vim.fn.bufname('%'), ':t')
  if name == '' then
    name = 'gliter-tohtml'
  end
  return name .. ext
end

--- Name a scratch output buffer `<name>`; when the name is taken (a real
--- file of it is open elsewhere) the buffer still gets the content, just
--- unnamed, with a notice.
---@param buf integer
---@param name string
local function name_buf(buf, name)
  local ok, err = pcall(vim.api.nvim_buf_set_name, buf, name)
  if not ok then
    vim.notify('gliter.tohtml: could not name the output buffer ' .. name
      .. ' (' .. tostring(err) .. ') — :w it to the file yourself', vim.log.levels.WARN)
  end
end

local function run(o)
  local from, to = o.line1, o.line2
  if o.range == 0 then -- no range: the whole buffer
    from, to = 1, vim.api.nvim_buf_line_count(0)
  end
  local what = (o.fargs[1] or 'html'):lower()
  local title = output_name('')

  if what == 'html' then
    local doc = M.html_document(M.spans(from, to), title)
    local buf = vim.api.nvim_create_buf(true, false)
    name_buf(buf, output_name('.html'))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, doc)
    vim.bo[buf].filetype = 'html'
    vim.api.nvim_set_current_buf(buf)
    vim.cmd('normal! gg')
  elseif what == 'md' or what == 'markdown' then
    local buf = vim.api.nvim_create_buf(true, false)
    name_buf(buf, output_name('.md'))
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.markdown_lines(from, to))
    vim.bo[buf].filetype = 'markdown'
    vim.api.nvim_set_current_buf(buf)
    vim.cmd('normal! gg')
  elseif what == 'pdf' then
    if not M.options.groff or vim.fn.executable(M.options.groff) == 0 then
      return vim.notify(('gliter.tohtml: %s not found — the pdf target needs groff (1.22+)'):format(M.options.groff or 'groff'), vim.log.levels.ERROR)
    end
    local src = table.concat(M.groff_document(M.spans(from, to), title, M.options.pdf_width, M.options.pdf_font_size), '\n')
    local srcfile = vim.fn.tempname() .. '.ms'
    vim.fn.writefile(vim.split(src, '\n', { plain = true }), srcfile)
    local res = vim.system({ M.options.groff, '-Tpdf', '-ms', srcfile }, { text = false }):wait()
    os.remove(srcfile)
    if res.code ~= 0 then
      return vim.notify('gliter.tohtml: groff failed: ' .. vim.trim(tostring(res.stderr)), vim.log.levels.ERROR)
    end
    local out = vim.fn.fnamemodify(output_name(''), ':r') .. '.pdf'
    local f = assert(io.open(out, 'wb'))
    f:write(res.stdout)
    f:close()
    vim.notify('gliter.tohtml: wrote ' .. vim.fn.fnamemodify(out, ':p'))
  else
    vim.notify('gliter.tohtml: html | md | pdf (got "' .. what .. '")', vim.log.levels.ERROR)
  end
end

function M.setup(opts)
  M.did_setup = true
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  vim.api.nvim_create_user_command('GliterTohtml', run, {
    range = true,
    nargs = '?',
    complete = function()
      return { 'html', 'md', 'pdf' }
    end,
    desc = 'gliter.tohtml: the buffer (or [range]) as HTML (syntax colors), Markdown, or PDF (groff)',
  })
  return M
end

return M
