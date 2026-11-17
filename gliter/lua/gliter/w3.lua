--- gliter.w3 — the web in a buffer: `:GliterW3 example.com` fetches the
--- page and shows it as text, links followable from the keyboard. The
--- interface is eww's (and viww's, which took it from Emacs): <CR> opens
--- the link under the cursor, H goes back, R reloads; ]l / [l walk the
--- links, gl collects them into the quickfix; an argument that is not an
--- address is a search (DuckDuckGo, in the same rendered-text form).
---
--- The rendering is viww's pipeline by default — curl fetches, pandoc
--- turns the HTML into markdown, and gliter.w3 post-processes it: the
--- link labels underlined with their urls kept, a heading in Title
--- colors, code in Comment colors. Images are not shown — not their
--- alt text, not a placeholder, not a `data:image/...;base64,...`
--- payload: an image leaves nothing on the line.
---
--- The other viewers, one page at a time:
---   lynx   `lynx -dump` — the fallback when there is no pandoc; its
---          numbered reference list becomes the page's link table
---          (1992, the oldest browser still maintained)
---   w3m    curl hands w3m the html it fetched and `w3m -T text/html
---          -dump` renders it — the links come out of the html itself
---          and land underlined in the dump, which on its own would be
---          nothing but text (1995)
---   webls   `wls <site>` — "web ls": not the page but the site's whole
---          URL list, crawled from its sitemaps (robots.txt included) —
---          the netrw move, applied to the web; every line is a link
--- `engine = 'auto'` (the default) takes the first of them it finds —
---   pandoc first, lynx when there is no pandoc;
--- name one to pin it, or put it in front of the url on the command line
--- (`:GliterW3 lynx example.com`) — the same viewer then serves <CR>, H
--- and R, so a webls buffer's <CR> lists the site of the link under the
--- cursor.
---
--- The fetch is asynchronous — the buffer shows a spinner and the clock
--- while the page loads, and the editor never freezes; `timeout` seconds
--- is the ceiling. The chain gliter borrows the interface from: W3
--- (William Perry, 1993), the first Emacs web browser → eww (Lars
--- Ingebrigtsen, 2013), the Emacs Web Wowser, rendering with shr → viww
--- (Rugved Pund, 2026), the vi web wowser: curl and pandoc under eww's
--- keys. gliter.w3 is viww's interface over the viewers you already have.
local M = {}

M.did_setup = false

if vim.fn.has('nvim-0.10') == 0 then
  function M.setup()
    vim.notify('[gliter] w3 needs Neovim 0.10+ (vim.system)', vim.log.levels.WARN)
  end
  return M
end

--- The viewers, in the order `engine = 'auto'` tries them.
M.ENGINES = { 'pandoc', 'lynx', 'w3m', 'webls' }

M.defaults = {
  engine = 'auto', -- 'auto' | 'pandoc' | 'lynx' | 'w3m' | 'webls'
  timeout = 30, -- seconds a fetch gets before it is killed
  -- where keywords go (an argument with no dot and spaces, say)
  search = 'https://duckduckgo.com/html/?q=%s',
  curl = 'curl', -- the fetcher of the pandoc pipeline
  -- the viewers; a path works too, false turns one off
  browsers = { pandoc = 'pandoc', lynx = 'lynx', w3m = 'w3m', webls = 'wls' },
  keys = {
    follow = '<CR>', -- open the link under the cursor
    next_link = ']l', -- the next link, wrapping around
    prev_link = '[l', -- the previous link
    links = 'gl', -- every link in the quickfix: search and jump between them
    back = 'H', -- the previous page
    reload = 'R', -- this page again
  },
}

M.options = vim.deepcopy(M.defaults)

--- The addresses this session visited, newest first — the history of the
--- prompt and the completion of :GliterW3.
M.urls = {}

local ns = vim.api.nvim_create_namespace('gliter_w3')

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'gliter.w3' })
end

local function push_url(url)
  if M.urls[1] ~= url then
    table.insert(M.urls, 1, url)
    while #M.urls > 100 do
      M.urls[#M.urls] = nil
    end
  end
end

---------------------------------------------------------------------------
-- the viewers
---------------------------------------------------------------------------

--- The command line a dump viewer runs for `url`. nil when the viewer is
--- off, and for the pandoc engine — that one is a curl -> pandoc chain,
--- not one command (see fetch_pandoc).
---@param engine string
---@param url string
---@return string[]?
function M.cmd_for(engine, url)
  if engine == 'pandoc' then
    return nil
  end
  local bin = M.options.browsers[engine]
  if not bin or bin == false then
    return nil
  end
  if engine == 'webls' then
    return { bin, url } -- wls takes domains, robots.txt and sitemap urls raw
  end
  return { bin, '-dump', url }
end

--- The first viewer on $PATH ('auto'): the pandoc pipeline needs curl
--- and pandoc, the others only themselves. nil when none is.
---@return string?
function M.pick()
  for _, e in ipairs(M.ENGINES) do
    if e == 'pandoc' then
      local c, p = M.options.curl, M.options.browsers.pandoc
      if c and c ~= false and vim.fn.executable(c) == 1
        and p and p ~= false and vim.fn.executable(p) == 1 then
        return 'pandoc'
      end
    else
      local bin = M.options.browsers[e]
      if bin and bin ~= false and vim.fn.executable(bin) == 1 then
        return e
      end
    end
  end
  return nil
end

local function resolve(engine)
  engine = engine or M.options.engine
  if engine == 'auto' then
    engine = M.pick()
  end
  return engine
end

---------------------------------------------------------------------------
-- urls
---------------------------------------------------------------------------

--- Percent-encode everything a query string cannot carry.
local function url_encode(s)
  return (s:gsub('[^%w%-._~]', function(c)
    return ('%%%02X'):format(c:byte())
  end))
end

--- An argument into a url: a scheme passes through, a dotted word becomes
--- an address, anything else is a search. webls gets its argument raw —
--- wls takes domains, robots.txt and sitemap urls alike.
---@param input string
---@param engine? string resolved engine
---@return string
function M.normalize(input, engine)
  if input:find('^[a-zA-Z][a-zA-Z0-9+.-]*://') then
    return input
  end
  if engine == 'webls' then
    return input
  end
  if not input:find('%s') and input:find('%.') then
    return 'https://' .. input -- example.com, example.com/page, host:port
  end
  return (M.options.search):format(url_encode(input))
end

--- A reference `ref` against the page url `base` — the common cases
--- (absolute, site-root, directory-relative, #fragment, //host), not the
--- whole of RFC 3986. Exposed for tests.
---@param base string
---@param ref string
---@return string
function M.resolve_url(base, ref)
  if type(ref) ~= 'string' or ref == '' then
    return base
  end
  if ref:match('^%a[%a%d+.-]*://') or ref:match('^data:') or ref:match('^mailto:') then
    return ref
  end
  local scheme, rest = base:match('^(%a[%a%d+.-]*://)(.*)$')
  if not scheme then
    return ref
  end
  if ref:sub(1, 2) == '//' then
    return scheme .. ref:sub(3)
  end
  local host = rest:match('^([^/?#]*)') or ''
  local path = (rest:sub(#host + 1)):gsub('[?#].*$', '')
  if ref:sub(1, 1) == '/' then
    return scheme .. host .. ref
  end
  if ref:sub(1, 1) == '#' or ref:sub(1, 1) == '?' then
    return scheme .. host .. path .. ref
  end
  local dir = path:match('^(.*)/') or ''
  return scheme .. host .. dir .. '/' .. ref
end

---------------------------------------------------------------------------
-- the pandoc renderer: markdown in, text + a link table out
---------------------------------------------------------------------------

local function unescape(s)
  return (s:gsub('\\(.)', '%1'))
end

local function unescape_entities(s)
  return (s:gsub('&(%a+);', {
    amp = '&', lt = '<', gt = '>', quot = '"', apos = "'", nbsp = ' ',
  }):gsub('&#(%d+);', function(n)
    return utf8.char(tonumber(n) or 63)
  end))
end

--- A data: uri's payload never reaches the screen, whatever path it
--- took in — and an image is not shown at all: the whole `data:image/...`
--- uri (one space before it with it) is gone. Other payloads keep the
--- mime, the base64 (or the url-encoded svg) collapsing to an ellipsis.
local function scrub_data(s)
  s = s:gsub('%s?data:image/[%w.+-]*;?[^%s%)%]]*', '')
  s = s:gsub('(data:[%w%.+/-]+;base64,)[%w+/%=]+', '%1…')
  return (s:gsub('(data:[%w%.+/-]+;utf8?,)[^%s%)%]]+', '%1…'))
end

--- Hrefs that are not pages: nothing to follow, nothing to show.
local function dead_scheme(u)
  return u:match('^data:') ~= nil or u:match('^mailto:') ~= nil
    or u:match('^javascript:') ~= nil or u:match('^tel:') ~= nil
end

--- Markdown emphasis off a line: `**bold**`, `*italic*`, `` `code` ``,
--- `__underline__`, `~~strike~~` — code spans protected from the rest,
--- because the asterisks inside them are text.
local function strip_emphasis(s)
  s = s:gsub('`(.-)`', '\001%1\001')
  s = s:gsub('%*%*(.-)%*%*', '%1')
  s = s:gsub('%*(.-)%*', '%1')
  s = s:gsub('__(.-)__', '%1')
  s = s:gsub('~~(.-)~~', '%1')
  return (s:gsub('\001(.-)\001', '%1'))
end

--- The `]` that matches the `[` at `i`, counting nesting and stepping
--- over backslash escapes; nil when the bracket never closes.
local function match_bracketed(s, i)
  local depth = 0
  local k = i
  while k <= #s do
    local c = s:sub(k, k)
    if c == '\\' then
      k = k + 2
    elseif c == '[' then
      depth = depth + 1
    elseif c == ']' then
      depth = depth - 1
      if depth == 0 then
        return k
      end
    end
    k = k + 1
  end
  return nil
end

--- One markdown line into display text; `entries` (in `lnum`, 1-based)
--- collects the links found — `col`/`end_col` are 0-based bytes into
--- the DISPLAY text. `allow_links` is false while rendering a link's
--- label (links do not nest). Images leave nothing: no text, no entry,
--- one space either side of them enough.
local function scan_md(line, lnum, entries, base, allow_links)
  local out, outlen = {}, 0
  local function emit(s)
    if s ~= '' then
      s = scrub_data(s) -- a stray data: payload never reaches the screen
      out[#out + 1] = s
      outlen = outlen + #s
    end
  end
  -- pandoc's attribute blocks (`{width=16}`, `{#id .class}`) follow an
  -- image or a link; they are syntax, not text
  local function skip_attrs(i)
    local attrs = line:match('^%b{}', i)
    return attrs and i + #attrs or i
  end
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    if c == '\\' and i < n then
      emit(line:sub(i + 1, i + 1)) -- pandoc's \[ \" --- escapes resolve here
      i = i + 2
    elseif c == '!' and line:sub(i + 1, i + 1) == '[' then
      local j = match_bracketed(line, i + 1)
      local parens = j and line:match('^%b()', j + 1)
      if j and parens then
        -- an image: not shown — no text, nothing followable; one space
        -- on either side of it is enough
        i = skip_attrs(j + 1 + #parens)
        if line:sub(i, i) == ' ' and (#out == 0 or out[#out]:sub(-1) == ' ') then
          i = i + 1
        end
      else
        emit(c)
        i = i + 1
      end
    elseif allow_links and c == '[' and line:sub(i + 1, i + 1) ~= '^' then
      local j = match_bracketed(line, i)
      local parens = j and line:match('^%b()', j + 1)
      if j and parens then
        local raw = parens:sub(2, -2)
        local sub = {}
        local label = scan_md(line:sub(i + 1, j - 1), lnum, sub, base, false)
        local col = outlen
        emit(label)
        for _, se in ipairs(sub) do
          se.col = se.col + col
          se.end_col = se.end_col + col
          entries[#entries + 1] = se
        end
        local url = M.resolve_url(base, unescape(raw))
        if not dead_scheme(url) then
          entries[#entries + 1] = {
            lnum = lnum, col = col, end_col = outlen,
            url = url, kind = 'link', label = label,
          }
        end
        i = skip_attrs(j + 1 + #parens)
      else
        emit(c)
        i = i + 1
      end
    elseif allow_links and c == '<' and line:find('^<%a[%w+.-]*://[^ >]+>', i) then
      local m = line:match('^<([^ >]+)>', i) -- <https://…>: the url, followable
      local col = outlen
      emit(m)
      entries[#entries + 1] = { lnum = lnum, col = col, end_col = outlen, url = m, kind = 'link', label = m }
      i = i + #m + 2
    elseif c == '[' and line:sub(i + 1, i + 1) == '^' then
      local j = line:find(']', i + 1, true) -- a footnote marker: gone
      i = j and j + 1 or i + 1
    else
      -- a run of ordinary text, up to the next special character: whole
      -- fragments keep the data: scrub meaningful (and are faster)
      local run = line:find('[\\!\\[<]', i + 1) or (#line + 1)
      emit(line:sub(i, run - 1))
      i = run
    end
  end
  return (table.concat(out):gsub('%s+$', ''))
end

--- Pandoc's markdown of a page into the lines to show, the link entries
--- on them and the line highlights ({ lnum, group }: headings in Title
--- colors, code in Comment colors). Links render as their labels —
--- underlined through the entries, the urls behind them; images are
--- not shown at all; fenced and indented code stays untouched. Exposed
--- for tests.
---@param md string
---@param base string the page url, for relative references
---@return string[] lines, table[] entries, table[] hls
function M.render_markdown(md, base)
  local lines = vim.split(md:gsub('\r\n?', '\n'), '\n', { plain = true })
  local out, entries, hls = {}, {}, {}
  local in_fence = false
  for _, line in ipairs(lines) do
    if line:match('^%s*```') or line:match('^%s*~~~') then
      in_fence = not in_fence -- the fence markers themselves do not render
    elseif in_fence then
      out[#out + 1] = line
      hls[#hls + 1] = { #out, 'Comment' }
    elseif line:match('^%s%s%s%s%s*%S') then
      out[#out + 1] = line -- indented code: kept as-is, nothing parsed inside
      hls[#hls + 1] = { #out, 'Comment' }
    elseif line:match('^%s*$') then
      out[#out + 1] = ''
    else
      local hl
      local _, rest = line:match('^(#+)%s+(.-)%s*$')
      if rest then
        line = rest
        hl = 'Title'
      elseif line:match('^%s*>') then
        line = line:gsub('^%s*>%s?', '')
      elseif line:match('^%s*[-*+]%s+') then
        line = line:gsub('^%s*([-*+])%s+', '%1 ')
      elseif line:match('^%s*%d+%.%s+') then
        line = line:gsub('^(%s*%d+%.)%s+', '%1 ')
      elseif line:match('^%s*%[%^%d+%]:') then
        line = nil -- a footnote definition: not part of the page
      end
      if line then
        if hl then
          hls[#hls + 1] = { #out + 1, hl }
        end
        out[#out + 1] = scan_md(strip_emphasis(line), #out + 1, entries, base, true)
      end
    end
  end
  while #out > 0 and out[#out] == '' do
    out[#out] = nil
  end
  return out, entries, hls
end

---------------------------------------------------------------------------
-- the w3m renderer: html in (curl fetches it), links out of the html
---------------------------------------------------------------------------

--- The links of an html page, in document order: every `<a href>` with
--- its label (tags inside stripped, entities unescaped, whitespace
--- collapsed). Links whose label is the url itself, and hrefs that are
--- not pages (data:, mailto:, ...), are left out — the dump renderer
--- picks bare urls up on its own, and a data: href has nothing to
--- follow. Exposed for tests.
---@param html string
---@return { label: string, href: string }[]
function M.extract_html_links(html)
  local out = {}
  local init = 1
  while true do
    local s, e, attrs = html:find('<a%s(.-)>', init)
    if not s then
      break
    end
    init = e + 1
    local href = attrs:match([=[%f[%w]href%f[^%w]%s*=%s*"([^"]+)"]=])
      or attrs:match([=[%f[%w]href%f[^%w]%s*=%s*'([^']+)']=])
      or attrs:match([=[%f[%w]href%f[^%w]%s*=%s*(%S+)]=])
    if href and href ~= '' and not href:match('^#') and not dead_scheme(href) then
      local close = html:find('</a>', e, true)
      local label = close and html:sub(e + 1, close - 1) or ''
      label = label:gsub('<[^>]+>', ' ')
      label = unescape_entities(label)
      label = vim.trim(label:gsub('%s+', ' '))
      if label ~= '' and label ~= href and not label:match('^https?://%S+$') then
        out[#out + 1] = { label = label, href = href }
      end
    end
  end
  return out
end

--- Links of the html onto the lines a dump viewer rendered of it: each
--- label looked up forward from where the last one landed (dumps render
--- in document order), its span an entry pointing at the resolved url.
--- Labels the dump does not carry are skipped. Exposed for tests.
---@param lines string[] the rendered dump
---@param links { label: string, href: string }[]
---@param base string the page url, for relative references
---@return table[] entries
function M.match_dump_links(lines, links, base)
  local entries = {}
  local li, pos = 1, 1 -- the search never moves backwards
  for _, l in ipairs(links) do
    local found ---@type integer?, integer?
    local i, p = li, pos
    while i <= #lines do
      local s, e = lines[i]:find(l.label, p, true)
      if s then
        found = i
        break
      end
      i, p = i + 1, 1
    end
    if found then
      local s, e = lines[found]:find(l.label, p, true)
      entries[#entries + 1] = {
        lnum = found, col = s - 1, end_col = e,
        url = M.resolve_url(base, l.href), kind = 'link', label = l.label,
      }
      li, pos = found, e + 1
    end
  end
  return entries
end

---------------------------------------------------------------------------
-- the dump renderer: lynx / w3m / wls output, reference lists and all
---------------------------------------------------------------------------

--- The numbered link table at the end of a w3m/lynx dump — `   1. url`
--- (lynx) or `[1] url` (w3m) lines. Inline `[1]` markers are not URLs and
--- do not match. Exposed for tests.
---@param lines string[]
---@return table<integer, string> refs
function M.parse_refs(lines)
  local refs = {}
  for _, l in ipairs(lines) do
    local n, u = l:match('^%s*%[(%d+)%][%.:]?%s*(https?://%S+)')
    if not n then
      n, u = l:match('^%s*(%d+)%.%s+(https?://%S+)')
    end
    if n then
      refs[tonumber(n)] = u:gsub('[.,;:)%]]+$', '')
    end
  end
  return refs
end

--- A viewer dump into the lines to show and the link entries on them:
--- every url on a line (wls listings, reference lists), and every inline
--- `[n]` marker resolved through the dump's reference table — the entry
--- spans the marker and the label before it. Exposed for tests.
---@param text string
---@return string[] lines, table[] entries, table<integer, string> refs
function M.render_dump(text)
  local lines = vim.split(text, '\n', { plain = true })
  while #lines > 0 and lines[#lines]:match('^%s*$') do
    lines[#lines] = nil
  end
  for i, l in ipairs(lines) do
    lines[i] = scrub_data(l) -- before the entries: their columns follow suit
  end
  local refs = M.parse_refs(lines)
  local entries = {}
  for i, l in ipairs(lines) do
    local init = 1
    while true do
      local s, e = l:find('https?://%S+', init)
      if not s then
        break
      end
      local url = (l:sub(s, e)):gsub('[.,;:)%]"]+$', '')
      entries[#entries + 1] = {
        lnum = i, col = s - 1, end_col = s - 1 + #url,
        url = url, kind = 'link', label = url,
      }
      init = e + 1
    end
    init = 1
    while true do
      local s, e, cap = l:find('%[(%d+)%]', init)
      if not s then
        break
      end
      local url = refs[tonumber(cap)]
      if url then
        local ls = s
        while ls > 1 and l:sub(ls - 1, ls - 1):match('[^%s]') do
          ls = ls - 1
        end
        entries[#entries + 1] = {
          lnum = i, col = ls - 1, end_col = e,
          url = url, kind = 'link',
          label = vim.trim(l:sub(ls, s - 1)),
        }
      end
      init = e + 1
    end
  end
  table.sort(entries, function(a, b)
    return a.lnum < b.lnum or (a.lnum == b.lnum and a.col < b.col)
  end)
  return lines, entries, refs
end

---------------------------------------------------------------------------
-- the page buffer
---------------------------------------------------------------------------

local attach_keys

--- One rendered page: its url, the viewer that rendered it, the link
--- entries (and the reference table of a dump), the history <CR> builds
--- and H walks back, and the loading state of the fetch in flight.
---@class GliterW3Page
---@field url string
---@field engine string
---@field entries table[]
---@field refs table<integer, string>
---@field history { url: string, engine: string }[]
---@field loading boolean
---@field failed boolean
---@field gen integer the fetch generation: a newer one abandons this

-- Pages by buffer. Not vim.b (deep-copy on store would freeze the page at
-- render time); buffer ids are unique for a session, so an entry for a
-- wiped buffer is unreachable, not dangerous.
local pages = {} ---@type table<integer, GliterW3Page>

--- The page shown in `buf`, if it is one.
---@param buf integer
---@return GliterW3Page?
function M.page(buf)
  local p = pages[buf]
  if p and vim.api.nvim_buf_is_valid(buf) then
    return p
  end
  return nil
end

local function decorate(buf, entries, hls)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, e in ipairs(entries or {}) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, e.lnum - 1, e.col, {
      end_col = e.end_col,
      hl_group = 'Underlined',
    })
  end
  for _, h in ipairs(hls or {}) do
    vim.api.nvim_buf_set_extmark(buf, ns, h[1] - 1, 0, { line_hl_group = h[2] })
  end
end

--- The pandoc pipeline: curl to a temp file (with the content type on
--- stdout), then pandoc html->markdown on it, then render_markdown.
--- text/plain goes in raw; anything else (an image, a binary) is an
--- info page saying what it is. `ok(lines, entries, refs, hls)` or
--- `fail(err)` — asynchronously.
local function fetch_pandoc(url, ok, fail)
  local tmp = vim.fn.tempname()
  local argv = {
    M.options.curl, '-sSL',
    '-m', tostring(math.max(1, M.options.timeout)),
    '-w', '\n%{content_type}',
    '-o', tmp,
    url,
  }
  local function cleanup()
    os.remove(tmp)
  end
  -- the callback runs in a fast uv context: schedule the handling out
  -- of it, where the api is callable
  vim.system(argv, { text = true }, vim.schedule_wrap(function(res)
    if type(res) ~= 'table' or res.code ~= 0 then
      cleanup()
      local code = type(res) == 'table' and res.code or '?'
      local detail = type(res) == 'table' and vim.trim((res.stderr or ''):gsub('\n', ' ')):sub(1, 120) or ''
      return fail(('%s exited with %s%s'):format(argv[1], tostring(code), detail ~= '' and (': ' .. detail) or ''))
    end
    local ctype = (res.stdout or ''):match('%S+') or ''
    local function read_file()
      local f = io.open(tmp, 'rb')
      if not f then
        return nil
      end
      local t = f:read('*a')
      f:close()
      return t
    end
    if ctype:find('text/html') then
      local bin = M.options.browsers.pandoc
      if not bin or bin == false then
        cleanup()
        return fail('pandoc is off (browsers.pandoc = false)')
      end
      vim.system({ bin, '-f', 'html', '-t', 'markdown', '--wrap=none', tmp }, { text = true }, vim.schedule_wrap(function(r2)
        if type(r2) ~= 'table' or r2.code ~= 0 or not r2.stdout or vim.trim(r2.stdout) == '' then
          cleanup()
          local code = type(r2) == 'table' and r2.code or '?'
          local detail = type(r2) == 'table' and vim.trim((r2.stderr or ''):gsub('\n', ' ')):sub(1, 120) or ''
          return fail(('%s exited with %s%s'):format(bin, tostring(code), detail ~= '' and (': ' .. detail) or ''))
        end
        local lines, entries, hls = M.render_markdown(r2.stdout, url)
        cleanup()
        ok(lines, entries, {}, hls)
      end))
    elseif ctype:find('text/plain') or ctype == '' then
      local body = read_file()
      cleanup()
      if not body or vim.trim(body) == '' then
        return fail(argv[1] .. ' returned nothing for ' .. url)
      end
      ok(vim.split(body:gsub('\r\n?', '\n'), '\n', { plain = true }), {}, {})
    else
      local st = vim.uv.fs_stat(tmp) or {}
      local body = read_file() or ''
      cleanup()
      ok({
        '[' .. (ctype ~= '' and ctype or 'binary') .. '] ' .. url,
        '',
        ('  %d bytes'):format(st.size or #body),
        '',
        '  R tries again; text/html and text/plain are the pages gliter.w3 renders.',
      }, {}, {})
    end
  end))
end

--- The w3m pipeline: curl fetches the html to a file, w3m renders that
--- file (`-T text/html -dump`), and the links come out of the html
--- itself — a w3m dump alone carries no urls, every link would be
--- nothing but text. When curl cannot fetch (offline, a bad url), w3m
--- fetches the page itself the plain way and the dump is what it is.
--- `ok(lines, entries, refs)` or `fail(err)` — asynchronously.
local function fetch_w3m(url, ok, fail)
  local bin = M.options.browsers.w3m
  local tmp = vim.fn.tempname()
  local timeout = math.max(1, M.options.timeout) * 1000
  vim.system({ M.options.curl, '-sSL', '-m', tostring(math.max(1, M.options.timeout)), '-o', tmp, url },
    { text = true }, vim.schedule_wrap(function(res)
      local function plain_dump()
        vim.system({ bin, '-dump', url }, { text = true, timeout = timeout }, vim.schedule_wrap(function(r2)
          if type(r2) ~= 'table' or r2.code ~= 0 or not r2.stdout or vim.trim(r2.stdout) == '' then
            local code = type(r2) == 'table' and r2.code or '?'
            local detail = type(r2) == 'table' and vim.trim((r2.stderr or ''):gsub('\n', ' ')):sub(1, 120) or ''
            return fail(('%s exited with %s%s'):format(bin, tostring(code), detail ~= '' and (': ' .. detail) or ''))
          end
          local lines, entries, refs = M.render_dump(r2.stdout)
          ok(lines, entries, refs)
        end))
      end
      if type(res) ~= 'table' or res.code ~= 0 then
        os.remove(tmp)
        return plain_dump()
      end
      local f = io.open(tmp, 'rb')
      local html = f and f:read('*a') or ''
      if f then
        f:close()
      end
      if not html:find('<%a') then -- not html after all: let w3m have it
        os.remove(tmp)
        return plain_dump()
      end
      vim.system({ bin, '-T', 'text/html', '-dump', tmp }, { text = true, timeout = timeout },
        vim.schedule_wrap(function(r2)
          os.remove(tmp)
          if type(r2) ~= 'table' or r2.code ~= 0 or not r2.stdout or vim.trim(r2.stdout) == '' then
            local code = type(r2) == 'table' and r2.code or '?'
            local detail = type(r2) == 'table' and vim.trim((r2.stderr or ''):gsub('\n', ' ')):sub(1, 120) or ''
            return fail(('%s exited with %s%s'):format(bin, tostring(code), detail ~= '' and (': ' .. detail) or ''))
          end
          local lines, entries, refs = M.render_dump(r2.stdout)
          local extra = M.match_dump_links(lines, M.extract_html_links(html), url)
          local seen = {}
          for _, e in ipairs(entries) do
            seen[('%d:%d:%s'):format(e.lnum, e.col, e.url)] = true
          end
          for _, e in ipairs(extra) do
            if not seen[('%d:%d:%s'):format(e.lnum, e.col, e.url)] then
              entries[#entries + 1] = e
            end
          end
          table.sort(entries, function(a, b)
            return a.lnum < b.lnum or (a.lnum == b.lnum and a.col < b.col)
          end)
          ok(lines, entries, refs)
        end))
    end))
end

--- Fetch `url` and render it — asynchronously: the buffer shows a spinner
--- and the seconds while the page loads, the editor stays live, and a
--- navigation that starts before it arrives (H, R, a new <CR>) abandons
--- the fetch. The current buffer when it already shows a page, else a new
--- buffer; the page state (history included) follows the buffer. Returns
--- true when a fetch started.
---@param url string
---@param engine? string
---@return boolean
function M.open(url, engine)
  engine = resolve(engine)
  if not engine then
    notify('no viewer found: install pandoc (curl fetches, pandoc renders), lynx, w3m or wls — or set browsers = {...}', vim.log.levels.WARN)
    return false
  end
  local cur = vim.api.nvim_get_current_buf()
  local buf = pages[cur] and cur or vim.api.nvim_create_buf(false, true)
  if buf ~= cur then
    vim.api.nvim_set_current_buf(buf)
    vim.bo[buf].buftype = 'nofile'
    vim.bo[buf].swapfile = false
  end
  -- the name may be taken (another w3 buffer of the same url) or otherwise
  -- refused; the page still renders, just under its old name
  pcall(vim.api.nvim_buf_set_name, buf, 'w3://' .. url)
  if attach_keys then
    attach_keys(buf)
  end
  local page = pages[buf] or { history = {}, entries = {}, refs = {} }
  pages[buf] = page
  page.gen = (page.gen or 0) + 1
  page.url, page.engine = url, engine
  page.loading = true
  page.failed = false
  page.entries, page.refs = {}, {}

  local function setlines(lines, first)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, (first or 1) - 1, -1, false, lines)
      vim.bo[buf].modifiable = false
    end
  end

  -- the loading screen: a spinner and the clock, never a frozen editor
  local t0 = vim.uv.hrtime()
  local frames = { '-', '\\', '|', '/' }
  local fi = 0
  local timer
  setlines({ 'Loading ' .. url, '' })
  local win = vim.fn.bufwinid(buf)
  if win >= 0 and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
    pcall(function()
      vim.wo[win].wrap = true
      vim.wo[win].linebreak = true
    end)
  end
  timer = vim.fn.timer_start(120, function()
    if not vim.api.nvim_buf_is_valid(buf) or not pages[buf] or pages[buf].gen ~= page.gen or not page.loading then
      pcall(vim.fn.timer_stop, timer)
      return
    end
    fi = fi + 1
    local secs = (vim.uv.hrtime() - t0) / 1e9
    setlines({ ('%s loading %.1fs (%s)'):format(frames[fi % 4 + 1], secs, engine) }, 2)
    pcall(vim.cmd, 'redraw')
  end, { ['repeat'] = -1 })

  local function stale()
    return not vim.api.nvim_buf_is_valid(buf) or not pages[buf] or pages[buf].gen ~= page.gen
  end

  local function ok(lines, entries, refs, hls)
    if stale() then
      pcall(vim.fn.timer_stop, timer)
      return
    end
    vim.fn.timer_stop(timer)
    page.loading = false
    page.entries, page.refs = entries or {}, refs or {}
    setlines(lines)
    decorate(buf, entries, hls)
    push_url(url)
    local w = vim.fn.bufwinid(buf)
    if w >= 0 and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_set_cursor, w, { 1, 0 })
    end
  end

  local function fail(err)
    if stale() then
      pcall(vim.fn.timer_stop, timer)
      return
    end
    vim.fn.timer_stop(timer)
    page.loading = false
    page.failed = true
    setlines({
      'Could not load ' .. url,
      '',
      '  ' .. err,
      '',
      '  R tries this page again; H goes back if there is a page to go back to.',
    })
  end

  if engine == 'pandoc' then
    fetch_pandoc(url, ok, fail)
  elseif engine == 'w3m' then
    if not M.options.browsers.w3m or M.options.browsers.w3m == false then
      fail('w3m is off (browsers.w3m = false)')
    else
      fetch_w3m(url, ok, fail)
    end
  else
    local argv = M.cmd_for(engine, url)
    if not argv then
      fail('unknown viewer "' .. tostring(engine) .. '" (pandoc, lynx, w3m, webls)')
      return true
    end
    vim.system(argv, {
      text = true,
      timeout = math.max(1, M.options.timeout) * 1000,
    }, vim.schedule_wrap(function(res)
      if type(res) ~= 'table' or res.code ~= 0 then
        local code = type(res) == 'table' and res.code or '?'
        local detail = type(res) == 'table' and vim.trim((res.stderr or ''):gsub('\n', ' ')):sub(1, 120) or ''
        return fail(('%s exited with %s%s'):format(argv[1], tostring(code), detail ~= '' and (': ' .. detail) or ''))
      end
      if not res.stdout or vim.trim(res.stdout) == '' then
        return fail(argv[1] .. ' returned nothing for ' .. url)
      end
      local lines, entries, refs = M.render_dump(res.stdout)
      ok(lines, entries, refs)
    end))
  end
  return true
end

---------------------------------------------------------------------------
-- <CR>, ]l/[l, gl, H, R
---------------------------------------------------------------------------

--- The link at `lnum` (and `col`, 0-based, when given) of page buffer
--- `buf`: the entry the cursor sits on, else the first entry of the line,
--- else — a dump with no entries, a `[n]` marker through the page's link
--- table, a line that is nothing but a url, the first bare url on the
--- line. nil when there is no link. Exposed for tests.
---@param buf integer
---@param lnum integer
---@param col? integer 0-based
---@return string? url, table? entry
function M.link_at(buf, lnum, col)
  local page = pages[buf]
  if page then
    local first
    for _, e in ipairs(page.entries or {}) do
      if e.lnum == lnum then
        if col and col >= e.col and col < e.end_col then
          return e.url, e
        end
        first = first or e
      end
    end
    if first then
      return first.url, first
    end
  end
  local line = vim.fn.getbufline(buf, lnum)[1] or ''
  local trimmed = line:match('^%s*(.-)%s*$')
  if trimmed:match('^https?://%S+$') then
    return trimmed, { lnum = lnum, col = #(line:match('^%s*')), end_col = #line, url = trimmed, kind = 'link', label = trimmed }
  end
  if page then
    local n = line:match('%[(%d+)%]')
    if n and page.refs[tonumber(n)] then
      return page.refs[tonumber(n)], nil
    end
  end
  local u = line:match('https?://[^%s%]%)]+')
  if u then
    u = (u:gsub('[.,;:]+$', ''))
    local s = line:find(u, 1, true)
    return u, { lnum = lnum, col = (s or 1) - 1, end_col = (s or 1) - 1 + #u, url = u, kind = 'link', label = u }
  end
  return nil
end

--- <CR>: open the link under the cursor (the current page onto the
--- history first). Exposed for tests.
function M.follow()
  local buf = vim.api.nvim_get_current_buf()
  local page = pages[buf]
  if not page then
    return
  end
  local url = M.link_at(buf, vim.fn.line('.'), vim.fn.col('.') - 1)
  if not url then
    return notify('No link on this line.')
  end
  table.insert(page.history, { url = page.url, engine = page.engine })
  M.open(url, page.engine)
end

--- ]l / [l: the next / previous link of the page, wrapping around.
--- `dir` 1 forward, -1 back. Exposed for tests.
---@param dir integer
function M.next_link(dir)
  local buf = vim.api.nvim_get_current_buf()
  local page = pages[buf]
  if not page or #(page.entries or {}) == 0 then
    return notify('No links on this page.')
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local lnum, col = pos[1], pos[2]
  local pick
  if dir >= 0 then
    for _, e in ipairs(page.entries) do
      if e.lnum > lnum or (e.lnum == lnum and e.col > col) then
        pick = e
        break
      end
    end
    pick = pick or page.entries[1]
  else
    for i = #page.entries, 1, -1 do
      local e = page.entries[i]
      if e.lnum < lnum or (e.lnum == lnum and e.col < col) then
        pick = e
        break
      end
    end
    pick = pick or page.entries[#page.entries]
  end
  vim.api.nvim_win_set_cursor(0, { pick.lnum, pick.col })
end

--- gl: every link of the page into the quickfix — search and jump
--- between them the vim way. Exposed for tests.
function M.list_links()
  local buf = vim.api.nvim_get_current_buf()
  local page = pages[buf]
  if not page then
    return
  end
  if #(page.entries or {}) == 0 then
    return notify('No links on this page.')
  end
  local qf = {}
  for _, e in ipairs(page.entries) do
    qf[#qf + 1] = {
      bufnr = buf,
      lnum = e.lnum,
      col = e.col + 1,
      text = (e.label or '') .. ' — ' .. (e.url or ''),
    }
  end
  vim.fn.setqflist({}, ' ', { title = 'gliter.w3 — ' .. (page.url or ''), items = qf })
  vim.cmd('6copen')
end

--- H: the previous page off the history. Exposed for tests.
function M.back()
  local buf = vim.api.nvim_get_current_buf()
  local page = pages[buf]
  if not page then
    return
  end
  local prev = table.remove(page.history)
  if not prev then
    return notify('Already at the first page.')
  end
  M.open(prev.url, prev.engine)
end

--- R: this page again. Exposed for tests.
function M.reload()
  local page = pages[vim.api.nvim_get_current_buf()]
  if not page then
    return
  end
  M.open(page.url, page.engine)
end

---------------------------------------------------------------------------
-- setup
---------------------------------------------------------------------------

-- (the `local attach_keys` the page functions close over lives above,
-- in "the page buffer"; this assignment is the one they see)
attach_keys = function(buf)
  local km = M.options.keys or {}
  local function map(key, fn, desc)
    if key and key ~= false then
      vim.keymap.set('n', key, fn, {
        buffer = buf,
        silent = true,
        nowait = true,
        desc = 'gliter.w3: ' .. desc,
      })
    end
  end
  map(km.follow, M.follow, 'open the link under the cursor')
  map(km.next_link, function()
    M.next_link(1)
  end, 'the next link')
  map(km.prev_link, function()
    M.next_link(-1)
  end, 'the previous link')
  map(km.links, M.list_links, 'all links in the quickfix')
  map(km.back, M.back, 'go back a page')
  map(km.reload, M.reload, 'reload this page')
end

function M.setup(opts)
  M.did_setup = true
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})

  vim.api.nvim_create_user_command('GliterW3', function(o)
    local args = vim.list_extend({}, o.fargs)
    local engine
    if args[1] and (vim.tbl_contains(M.ENGINES, args[1]:lower()) or args[1]:lower() == 'auto') then
      engine = table.remove(args, 1):lower()
      if engine == 'auto' then
        engine = nil
      end
    end
    local input = vim.trim(table.concat(args, ' '))
    if input == '' then
      -- the command line vim.fn.input() gives: readline keys and a ghost
      -- of the addresses opened before with gliter.cmd set up, <Up>/<Down>
      -- walking them in the `@` history
      local ok, res = pcall(vim.fn.input, {
        prompt = 'W3 open: ',
        cancelreturn = '',
      })
      input = vim.trim(ok and res or '')
      if input == '' then
        return
      end
      if vim.fn.histget('@', -1) ~= input then
        vim.fn.histadd('@', input)
      end
    end
    M.open(M.normalize(input, resolve(engine)), engine)
  end, {
    nargs = '*',
    complete = function(arglead)
      local out = {}
      for _, e in ipairs(M.ENGINES) do
        if e:find('^' .. vim.pesc(arglead:lower())) then
          out[#out + 1] = e
        end
      end
      for _, u in ipairs(M.urls) do
        if u:lower():find('^' .. vim.pesc(arglead:lower())) then
          out[#out + 1] = u
        end
      end
      return out
    end,
    desc = 'gliter.w3: open a url / domain (or search keywords) in a buffer; a viewer name first (pandoc, lynx, w3m, webls) picks the way to view',
  })

  -- keys on every page buffer as it opens; buffers from before this
  -- setup (a second setup call, say) get them too
  for buf, page in pairs(pages) do
    if page and vim.api.nvim_buf_is_valid(buf) then
      attach_keys(buf)
    end
  end
  return M
end

return M
