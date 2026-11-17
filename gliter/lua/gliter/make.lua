--- gliter.make — the *compilation* buffer: Emacs' compile for Neovim's :make
--- machinery (Neovim 0.9+).
---
--- WHAT IT DOES
---   * Sets 'makeprg' (and where useful 'errorformat') per filetype, from a
---     table in opts — 'make' for everything by default, 'go build ./...'
---     for go, 'cargo build' for rust, and so on. The options are ordinary
---     buffer-locals afterwards: :setl makeprg=... still wins over the table.
---   * <Leader>lm (Spacemacs' compile key) runs the program the way
---     Emacs' M-x compile does: a bottom window on the buffer `gliter://make` opens,
---     the command is echoed as its first line, and the output streams in —
---     stdout and stderr interleaved, the job under a pty by default
---     (Emacs' compile runs its processes on a pty too), so gcc, cargo,
---     python and friends think they talk to a terminal and PAINT — and
---     the ANSI escape sequences they send are rendered as real
---     highlights: colored compilers look like they do in a terminal.
---     The buffer is a plain normal buffer: yank from it, search in it, keep
---     it around with :b after the window is closed.
---   * Errors are recognized with 'errorformat', the way Emacs matches
---     them: every line is tried against a *list* of formats — a
---     filetype-specific one first, then Vim's default — until one
---     recognizes it (a single merged format cannot do it: errorformat
---     does not backtrack, and a half-matching pattern in front eats the
---     line before the patterns behind ever see it). Formats without
---     file:line:col columns count too — Python's `  File "x.py", line 2,
---     in <module>` and the bare `  File "x.py", line 2` of syntax errors
---     alike — and every recognized line — with a location or not — fills
---     the quickfix list (location-less ones as message-only entries, so
---     :cnext/:cprev never die on an empty list), and :cc/:copen work next
---     to gliter's own keys; the output itself stays dressed exactly as
---     the tool wrote it — its own ANSI colors, no extra underline.
---   * Jumps land on the exact character, whatever the format produced: a
---     parsed column when there is one, else Python's caret line
---     (`    ^^^^` under the echoed source), else the quoted symbols of the
---     message (`name 'x' is not defined`) searched on the error's line —
---     and the span is VISUALLY SELECTED (v-mode) in the source buffer,
---     where Emacs' compilation only flashes a face.
---   * In the output buffer: n / p cycle through the error locations,
---     jumping in the window the build started from (every jump pushed
---     onto the jumplist) — and the span landed on is FLASHED for a quick
---     second (GliterMakeFlash, opts.flash ms) instead of parking a
---     selection in a window you are not in; the quickfix's own stepping
---     (:cc/:cnext/:cprev, <CR> in the quickfix window) gets the same
---     flash. <CR> in the output jumps to the error under the cursor (or
---     the nearest one) AND moves there with the span selected, q closes
---     the window, r re-runs the command, <C-c> stops a running build,
---     i types a line into the running program's stdin (the pipe has
---     one; the buffer just never showed it) and t re-runs the command in
---     a real terminal — Emacs compilation-mode's keys, one modifier
---     shorter, plus comint's i.
---   * At the end the buffer says what Emacs says: `Compilation finished
---     at 13:37:12.` or `Compilation exited abnormally with code 2 at
---     13:37:12.`
---   * The runner half: <Leader>lr runs the current FILE
---     (runner.programs[filetype]: 'pypy3 %' for python, 'gcc -g % &&
---     ./a.out' for c, ...), its Visual-mode twin runs the live SELECTION
---     through runner.visual[filetype] (a temp file piped to lua / python
---     / node), <Leader>lp ripgreps a pattern (matches in the quickfix,
---     flashed on stepping like errors), and the runner.shells keys
---     (<Leader>lf fzf, <Leader>lt tree by default — every key sits
---     under <Leader>l, the runner's prefix) launch the tools
---     (runner.grep_prog picks the search binary — false,
---     or a binary that is not installed, falls back to :vimgrep). Where
---     a run goes is ONE function, runner.output — set it to yours (a
---     floating Snacks terminal, say; the example is in
---     doc/gliter.make.md); the default is this module's compilation
---     buffer + quickfix, with a real terminal for the commands that need
---     a keyboard — and i / t in the output for the ones that only start
---     asking once they run.
---
--- USAGE (from your init.lua)
---   require('gliter.make').setup()                      -- defaults
---   require('gliter.make').setup { height = 16 }        -- taller window
---   require('gliter').setup { make = true }             -- through gliter
---
---   :GliterMake [args]      run the build (args are appended to 'makeprg')
---   :GliterMakeShow         bring the output window back
---   :GliterMakeStop         stop the running build
---   :GliterRun [args]       run the current file (runner.programs)
---   :GliterGrep [pat]       ripgrep a pattern (prompted when absent)

local M = {}

M.did_setup = false

if vim.fn.has('nvim-0.9') == 0 then
  function M.setup()
    vim.notify('[gliter] make needs Neovim 0.9+ (jobstart, extmarks)', vim.log.levels.WARN)
  end
  return M
end

local defaults = {
  keys = {
    run = '<Leader>lm', -- run the build; a second press restarts it
    show = false, -- e.g. '<Leader>ls'; :GliterMakeShow works without a key
    stop = false, -- e.g. '<Leader>lk'; :GliterMakeStop works without a key
    run_file = '<Leader>lr', -- run the current file; the Visual-mode twin
    -- of the key runs the live selection instead
    grep = '<Leader>lp', -- ripgrep a pattern (prompted, cword prefilled)
  },
  -- 'makeprg' per filetype, applied as a buffer-local option when the
  -- filetype is set; '*' is everything else. Set any row to false to leave
  -- that filetype's (or the default) 'makeprg' alone.
  programs = {
    ['*'] = 'make',
    cmake = 'cmake --build build',
    go = 'go build ./...',
    rust = 'cargo build',
    zig = 'zig build',
    -- python = 'python -m py_compile %', -- syntax check only: no run, no traceback
    python = 'pypy3 %', -- run the file: full tracebacks with jumpable locations
    tex = 'latexmk -pdf -interaction=nonstopmode %',
  },
  -- 'errorformat' per filetype, replacing Vim's default in those buffers.
  -- A LIST: each entry is tried on its own, in order, against one output
  -- line — the way Emacs' compilation-error-regexp-alist works — before
  -- Vim's default 'errorformat' gets its turn. They must NOT be merged
  -- into one comma-separated 'errorformat': errorformat does not
  -- backtrack, so `  File "%f"\\, line %l\\, in %.%#` in front eats the
  -- bare `  File "x.py", line 2` of a syntax error and the pattern behind
  -- never sees the line (exactly how syntax errors used to go
  -- unrecognized).
  errorformats = {
    -- cargo: the ` --> src/main.rs:3:24` lines carry the location; the
    -- `error:`/`warning:` lines have none of their own
    rust = { '%E%.%#-->\\ %f:%l:%c,%Wwarning:%m' },
    -- python tracebacks, both shapes — `  File "x.py", line 2, in <module>`
    -- and the bare `  File "x.py", line 2` of syntax errors (`%.%#` drinks
    -- whichever tail follows). Single-line patterns on purpose: entries
    -- are matched as the output streams, one line at a time; the exact
    -- character comes from the caret line or the message's quoted symbols
    -- afterwards (see note_exact).
    python = { '  File "%f"\\, line %l%.%#' },
  },
  height = 12, -- output window height
  ansi = true, -- render ANSI escape sequences as highlights (terminal look)
  scroll = true, -- keep the output window scrolled to the bottom while running
  -- environment the build runs with (merged with yours) — asks the common
  -- tools for colors over a pipe, where they default to plain text. Set to
  -- false to pass nothing.
  env = { CLICOLOR_FORCE = '1', FORCE_COLOR = '1', CARGO_TERM_COLOR = 'always' },
  pty = true, -- run under a pty, the way Emacs' compile does: full
  -- interleaving and COLORS FROM EVERY TOOL — gcc, clang, cargo, python
  -- all check "is this a terminal?" before painting, stay plain over a
  -- pipe and paint under a pty — at the price of lines wrapping at the
  -- pty's width and progress spinners turning into lines (Emacs' compile
  -- pays both too; that is what a *compilation* buffer looks like).
  -- false: a plain pipe — no wrapping, and colors only from the tools the
  -- env table below can talk into them
  width = 0, -- the pty's width: 0 = the origin window's width floored at
  -- 100 (a compiler's lines deserve the room); a number forces it;
  -- ignored when pty = false
  flash = 1000, -- ms an error's span stays flashed when n / p — or the
  -- quickfix's own :cnext/:cprev/<CR> — step onto it (false: no flash);
  -- <CR> in the output buffer leaves a real Visual selection instead
  -- The runner: run the file in front of you, not the project. Every run
  -- goes through runner.output — a function of your own, or the default:
  -- the compilation buffer + quickfix, and a real terminal where stdin is
  -- needed. '%' in a program is the buffer's file (full path,
  -- shell-escaped; a '%s' anywhere switches the template to printf style).
  runner = {
    programs = {
      python = 'pypy3 %',
      c = 'gcc -g % && ./a.out',
      cpp = 'g++ -std=c++17 -g -Wall % 2>/dev/null && ./a.out',
      lua = 'lua %',
      rust = 'RUST_BACKTRACE=1 cargo run || rustc % -o a.out && ./a.out',
      haskell = 'runhaskell %',
      [''] = 'make', -- a buffer with no filetype at all
      -- a table row forces the default output's terminal split for that
      -- filetype: python = { cmd = 'python -i %', interactive = true }
      -- ['*'] = '...', -- a catch-all for unnamed filetypes (off by
      -- default: unknown filetypes are announced, not guessed)
    },
    visual = { -- interpreters for the Visual selection (x<Leader>lr)
      lua = 'lua',
      python = 'python',
      javascript = 'node',
    },
    grep_prog = 'rg', -- the <Leader>lp search binary: 'rg' runs
    -- 'rg --vimgrep --color=always -- <pat> .', any other binary
    -- '<bin> -rn -- <pat> .'; false (or a binary that is not installed)
    -- falls back to :vimgrep — no external tool needed
    shells = { -- launchers on <Leader>l<key> (a key that is not a
      -- single character is used as the whole key)
      f = { cmd = 'fzf', interactive = true },
      t = 'tree', -- plain output: the compilation buffer
    },
    output = nil, -- function(spec) — see doc/gliter.make.md; spec =
    -- { cmd, kind = 'file'|'visual'|'grep'|'shell', ft, file, interactive,
    --   title }
  },
}

local cfg = vim.deepcopy(defaults)

local BUFNAME = 'gliter://make' -- an Emacs-y *gliter make* in :ls, but a
-- scheme name stays itself: a plain '*gliter make*' is treated as relative
-- and quietly becomes /cwd/*gliter make* — breaking the reuse lookup below
local ns = vim.api.nvim_create_namespace('gliter.make')

local S = {
  job = nil, -- running job id
  buf = nil, -- the output buffer
  win = nil, -- the window showing it
  origin_win = nil, -- the window the build was started from
  origin_buf = nil,
  cmd = nil, -- the command line as run
  args = '', -- args given to :GliterMake
  cwd = nil,
  efm = nil, -- 'errorformat' captured at run time (the buffer's own)
  efms = nil, -- the list tried per line: the buffer's, the filetype's, the default
  carry = '', -- partial output line
  replace_first = false, -- next line replaces the buffer's single empty line
  errors = {}, -- { { line = output lnum, entry = {...} } }
  cursor_idx = 0, -- cycle position in errors
  follow = true, -- still auto-scrolling
  last_set = 0, -- the line we last scrolled to
  killed = false, -- stopped by :GliterMakeStop
  running = false,
  gen = 0, -- which run the callbacks belong to
  qf_id = nil, -- the quickfix list id our last fill created
  last_code = 0, -- the exit code of the finished run (qf_flush reads it)
  title = nil, -- its title ('gliter make: ...', 'gliter rg: ...')
  grep = false, -- the running command is a grep: exit 1 = no matches
  tmp = nil, -- the visual run's temp file, removed when the job ends
  term_win = nil, -- the runner's interactive terminal window
}

--------------------------------------------------------------------- ansi --

-- The basic 16 colors, the xterm way.
local basic = {
  '#000000', '#800000', '#008000', '#808000', '#000080', '#800080', '#008080', '#c0c0c0',
  '#808080', '#ff0000', '#00ff00', '#ffff00', '#0000ff', '#ff00ff', '#00ffff', '#ffffff',
}

--- xterm's 256-color palette, as hex.
local function xterm256(i)
  if i < 16 then
    return basic[i + 1]
  end
  if i < 232 then
    local l = i - 16
    local v = { 0, 95, 135, 175, 215, 255 }
    return ('#%02x%02x%02x'):format(v[math.floor(l / 36) + 1], v[math.floor(l / 6) % 6 + 1], v[l % 6 + 1])
  end
  local g = 8 + (i - 232) * 10
  return ('#%02x%02x%02x'):format(g, g, g)
end

local function color_hex(c)
  if type(c) == 'number' then
    return xterm256(c)
  end
  if type(c) == 'table' then
    if c.idx then
      return xterm256(c.idx)
    end
    if c.rgb then
      return ('#%02x%02x%02x'):format(c.rgb[1] or 0, c.rgb[2] or 0, c.rgb[3] or 0)
    end
  end
  return nil
end

--- Apply one SGR parameter list ("31;1") to the state table `st`.
local function apply_sgr(params, st)
  local ps = vim.split(params, ';', { plain = true })
  local k = 1
  while k <= #ps do
    local v = tonumber(ps[k]) or 0
    if v == 0 then
      for key in pairs(st) do
        st[key] = nil
      end
    elseif v == 1 then
      st.bold = true
    elseif v == 3 then
      st.italic = true
    elseif v == 4 then
      st.underline = true
    elseif v == 7 then
      st.reverse = true
    elseif v == 9 then
      st.strike = true
    elseif v == 22 then
      st.bold = nil
    elseif v == 23 then
      st.italic = nil
    elseif v == 24 then
      st.underline = nil
    elseif v == 27 then
      st.reverse = nil
    elseif v == 29 then
      st.strike = nil
    elseif v >= 30 and v <= 37 then
      st.fg = v - 30
    elseif v == 38 or v == 48 then
      local slot = (v == 38) and 'fg' or 'bg'
      local mode = tonumber(ps[k + 1]) or 0
      if mode == 5 then
        st[slot] = { idx = tonumber(ps[k + 2]) or 0 }
        k = k + 2
      elseif mode == 2 then
        st[slot] = {
          rgb = { tonumber(ps[k + 2]) or 0, tonumber(ps[k + 3]) or 0, tonumber(ps[k + 4]) or 0 },
        }
        k = k + 4
      end
    elseif v == 39 then
      st.fg = nil
    elseif v >= 40 and v <= 47 then
      st.bg = v - 40
    elseif v == 49 then
      st.bg = nil
    elseif v >= 90 and v <= 97 then
      st.fg = v - 90 + 8
    elseif v >= 100 and v <= 107 then
      st.bg = v - 100 + 8
    end
    k = k + 1
  end
end

--- Split a raw output line into plain text plus colored segments.
--- Non-SGR escape sequences (cursor moves, OSC titles) are dropped; a
--- segment is { start_col, end_col, state } in byte columns of the text
--- that survives. A state is a table of SGR attributes, or { group = name }
--- for pre-resolved highlights.
---@return string text, table[] segs
local function parse_ansi(raw)
  if not raw:find('\27', 1, true) then
    return raw, {}
  end
  local out, segs = {}, {}
  local col, i, n = 0, 1, #raw
  local st = {}
  local from = 1

  local function flush(upto) -- emit raw[from..upto-1]
    if upto > from then
      local text = raw:sub(from, upto - 1)
      out[#out + 1] = text
      if next(st) then
        -- snapshot: apply_sgr mutates st in place, and a segment already
        -- pushed must not change with the colors that come after it
        segs[#segs + 1] = { col, col + #text, vim.tbl_extend('force', {}, st) }
      end
      col = col + #text
    end
  end

  while i <= n do
    if raw:byte(i) == 0x1b then
      local c = raw:sub(i + 1, i + 1)
      local after = i + 2 -- what the skip costs
      if c == '[' then
        local j = i + 2
        while j <= n and raw:byte(j) >= 0x20 and raw:byte(j) <= 0x3f do
          j = j + 1
        end
        local fin = (j <= n) and raw:sub(j, j) or ''
        if fin >= '@' and fin <= '~' then
          flush(i)
          if fin == 'm' then
            apply_sgr(raw:sub(i + 2, j - 1), st)
          end
          from = j + 1
          after = j + 1
        else -- unterminated: drop the rest
          flush(i)
          from, after = n + 1, n + 1
        end
      elseif c == ']' then -- OSC: ends at BEL or ESC \
        local bel = raw:find('\7', i + 2, true)
        local stp = raw:find('\27\\', i + 2, true)
        local stop = bel and (stp and math.min(bel, stp - 2) or bel) or (stp and stp - 2)
        flush(i)
        if stop then
          from = stop + (bel == stop and 1 or 2)
          after = from
        else
          from, after = n + 1, n + 1
        end
      else -- two-character escape
        flush(i)
        from = i + 2
      end
      i = after
    else
      i = i + 1
    end
  end
  flush(n + 1)
  return table.concat(out), segs
end

------------------------------------------------------------- highlights --

local hl_seq = 0
local hl_cache = {} -- state-key -> group name

--- The highlight group for one ANSI state. Error and warning lines wear
--- exactly what the tool painted on them — no underline on top anymore:
--- a whole line underlined red under gcc's already-red error reads twice,
--- and the quickfix list carries the error now.
---@param st table
---@return string group
local function group_for(st)
  local function ckey(c)
    if type(c) == 'number' then
      return tostring(c)
    end
    if type(c) == 'table' then
      if c.idx then
        return 'i' .. c.idx
      end
      if c.rgb then
        return 'r' .. table.concat(c.rgb, ',')
      end
    end
    return ''
  end

  if st.group then -- pre-resolved ({ group = 'GliterMakeOk' })
    return st.group
  end

  local key = table.concat({
    ckey(st.fg),
    ckey(st.bg),
    st.bold and 'B' or '',
    st.italic and 'I' or '',
    st.underline and 'U' or '',
    st.reverse and 'R' or '',
    st.strike and 'S' or '',
  })
  local cached = hl_cache[key]
  if cached then
    return cached
  end

  local hl = {}
  local fg, bg = color_hex(st.fg), color_hex(st.bg)
  if fg then
    hl.fg = fg
  end
  if bg then
    hl.bg = bg
  end
  hl.bold = st.bold or nil
  hl.italic = st.italic or nil
  hl.underline = st.underline or nil
  hl.reverse = st.reverse or nil
  hl.strikethrough = st.strike or nil
  hl_seq = hl_seq + 1
  local name = 'GliterMakeHl' .. hl_seq
  pcall(vim.api.nvim_set_hl, 0, name, hl)
  hl_cache[key] = name
  return name
end

local function define_highlights()
  vim.api.nvim_set_hl(0, 'GliterMakeOk', { fg = '#50fa7b', bold = true })
  vim.api.nvim_set_hl(0, 'GliterMakeFail', { fg = '#ff6b6b', bold = true })
  -- status-line friends for :GliterMakeStop
  vim.api.nvim_set_hl(0, 'GliterMakeStopped', { fg = '#e6b450', bold = true })
  -- n/p's flash: a face on the error's span for a quick second — Emacs'
  -- compilation cannot leave a selection, so it flashes one instead
  vim.api.nvim_set_hl(0, 'GliterMakeFlash', { bg = '#e0af68', default = true })
end

-------------------------------------------------------------- the buffer --

--- The window the build was started from, if it still shows something.
local function origin_window()
  if S.origin_win and vim.api.nvim_win_is_valid(S.origin_win) then
    return S.origin_win
  end
  local prev = vim.fn.win_getid(vim.fn.winnr('#'))
  if prev ~= -1 and vim.api.nvim_win_is_valid(prev) then
    return prev
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if not S.win or w ~= S.win then
      return w
    end
  end
end

--- Create (once) the output buffer: a plain normal buffer with the
--- compilation-mode keys.
local function ensure_buf()
  if S.buf and vim.api.nvim_buf_is_valid(S.buf) then
    return S.buf
  end
  -- A buffer of ours that is still around (a second setup() call, a
  -- reloading dev loop) is reused instead of duplicated.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b) == BUFNAME then
      S.buf = b
      break
    end
  end
  local buf = S.buf or vim.api.nvim_create_buf(true, false)
  pcall(vim.api.nvim_buf_set_name, buf, BUFNAME)
  local bo = vim.bo[buf]
  bo.buftype = 'nofile'
  bo.bufhidden = 'hide'
  bo.swapfile = false
  bo.undolevels = -1
  bo.modifiable = false

  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, {
      buffer = buf,
      silent = true,
      nowait = true,
      desc = 'gliter.make: ' .. desc,
    })
  end
  map('n', function()
    M.cycle(1)
  end, 'next error location')
  map('p', function()
    M.cycle(-1)
  end, 'previous error location')
  map('<CR>', function()
    M.jump_at_cursor()
  end, 'jump to the error under the cursor (and move there)')
  map('q', function()
    M.hide()
  end, 'close the output window')
  map('<Esc>', function()
    M.hide()
  end, 'close the output window')
  map('r', function()
    M.run(S.args)
  end, 'run the same command again')
  map('<C-c>', function()
    M.stop()
  end, 'stop the running compilation')

  -- comint's half: a line typed at the prompt below goes to the running
  -- program's stdin — the job's pipe has one, the buffer just never
  -- showed it. For the programs that want more than a line: t.
  local function type_to_job()
    if not (S.job and S.running) then
      return vim.notify('[gliter] nothing is running', vim.log.levels.INFO)
    end
    local ok, text = pcall(vim.fn.input, { prompt = 'input: ', cancelreturn = '\0' })
    if not ok or not text or text == '\0' or text == '' then
      return
    end
    M.send_input(text)
  end
  for _, k in ipairs({ 'i', 'a', 'I', 'A' }) do
    map(k, type_to_job, 'type a line to the running program (stdin)')
  end
  map('t', function()
    M.run_in_term()
  end, 're-run the command in a real terminal (full keyboard)')

  S.buf = buf
  return buf
end

--- Open (or find) the output window at the bottom, Emacs-style; the focus
--- stays where it was.
local function open_win()
  if S.win and vim.api.nvim_win_is_valid(S.win) and vim.api.nvim_win_get_buf(S.win) == S.buf then
    return S.win
  end
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == S.buf then
      S.win = w
      return w
    end
  end
  local cur = vim.api.nvim_get_current_win()
  vim.cmd('botright ' .. math.max(1, cfg.height) .. 'split')
  S.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(S.win, ensure_buf())
  if cur ~= S.win and vim.api.nvim_win_is_valid(cur) then
    vim.api.nvim_set_current_win(cur) -- Emacs keeps you in your buffer
  end
  return S.win
end

--- Append one line to the output buffer with its highlight segments.
---@param text string
---@param segs table[]
local function append_line(text, segs)
  local buf = S.buf
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local bo = vim.bo[buf]
  bo.modifiable = true
  if S.replace_first and vim.api.nvim_buf_line_count(buf) == 1 then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { text })
    S.replace_first = false
  else
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, { text })
  end
  bo.modifiable = false

  local row = vim.api.nvim_buf_line_count(buf) - 1 -- 0-based
  local function mark(c1, c2, group)
    vim.api.nvim_buf_set_extmark(buf, ns, row, c1, {
      end_line = row,
      end_col = c2,
      hl_group = group,
      hl_mode = 'combine',
      priority = 10,
    })
  end
  for _, s in ipairs(segs) do
    mark(s[1], s[2], group_for(s[3]))
  end
end

--- Keep the output window glued to the bottom while output streams in —
--- until the user scrolls away (their cursor leaves the line we put it on).
local function maybe_scroll()
  if not cfg.scroll then
    return
  end
  local w = S.win
  if not (w and vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == S.buf) then
    return
  end
  local last = vim.api.nvim_buf_line_count(S.buf)
  local cur = vim.api.nvim_win_get_cursor(w)
  if cur[1] ~= S.last_set then
    if cur[1] >= last then -- the user came back to the tail
      S.follow = true
    elseif S.follow then
      S.follow = false -- the user scrolled away
    end
    if not S.follow then
      return
    end
  end
  if not S.follow then
    return
  end
  vim.api.nvim_win_set_cursor(w, { last, 0 })
  S.last_set = last
  pcall(vim.api.nvim_win_call, w, function()
    vim.cmd('normal! z-')
  end)
end

-------------------------------------------------------------- quickfix --

local qf_timer = nil

--- Refill the quickfix list from the errors collected so far.
local function qf_flush()
  local items = {}
  for _, e in ipairs(S.errors) do
    -- the parsed message when one was captured (Python's trailer line:
    -- `SyntaxError: invalid syntax`), else the raw matched line
    local item = {
      lnum = e.entry.lnum,
      text = e.entry.msg or e.entry.text,
      type = e.entry.type,
    }
    if e.entry.file then
      item.filename = e.entry.file
    end
    -- errors without a location (a bare `SyntaxError: ...` trailer, an
    -- `error: boom` line) still get their quickfix row, message-only:
    -- :cnext/:cprev step through them like any other entry instead of
    -- dying with E42 on a list that stayed empty
    if e.entry.col > 0 then -- only when actually known: 0 would be a fake column
      item.col = e.entry.col
    end
    items[#items + 1] = item
  end
  if #items == 0 and S.running then
    return -- don't wipe the user's list for a clean run in progress
  end
  if #items == 0 then
    -- nothing recognized at the end of the run. A clean success (or an
    -- empty grep) clears the list, the way :make does; a FAILED run
    -- keeps the errors you were stepping through — the next run's
    -- errors are not in yet, and `no errors` is not `no problem`
    if S.grep or (S.last_code or 0) == 0 then
      vim.fn.setqflist({}, ' ', { items = {}, title = S.title or ('gliter make: ' .. (S.cmd or '')) })
    end
    S.qf_id = nil -- whatever list is there now: not this run's, don't flash
    return
  end
  vim.fn.setqflist({}, ' ', { items = items, title = S.title or ('gliter make: ' .. (S.cmd or '')) })
  S.qf_id = vim.fn.getqflist({ id = 0 }).id -- the flash hook looks for it
end

local function qf_tick()
  if qf_timer then
    return
  end
  qf_timer = vim.defer_fn(function()
    qf_timer = nil
    qf_flush()
  end, 200)
end

--- Resolve `p` against the directory the build ran in: compilers report
--- file names relative to it, and a bare 'main.c' would otherwise be taken
--- relative to wherever the cursor happens to be.
---@param p string
---@return string
local function to_abs(p)
  if p:match('^%a[%w+.-]+://') then
    return p
  end
  if p:sub(1, 1) == '~' then
    return vim.fn.expand(p)
  end
  if p:sub(1, 1) == '/' or p:match('^%a:[/\\]') then
    return vim.fs.normalize(p)
  end
  return vim.fs.normalize(vim.fs.joinpath(S.cwd or vim.fn.getcwd(), p))
end

--- One output line through the 'errorformat's of the run — the way Emacs
--- matches a line at a time: every format in S.efms is tried on its own,
--- in order, until one yields an entry (a merged format cannot: the first
--- half-matching pattern eats the line and there is no backtracking).
--- Returns an entry with a file for jumpable errors, only a kind for
--- trailers like `make: *** ...`.
---@param text string
---@return table? entry
local function parse_error(text)
  if text == '' then
    return nil
  end
  local it
  for _, efm in ipairs(S.efms or { S.efm }) do
    if efm and efm ~= '' then
      local ok, res = pcall(vim.fn.getqflist, { lines = { text }, efm = efm })
      local one = ok and type(res) == 'table' and res.items and res.items[1]
      if
        one
        and one.valid == 1
        and (
          one.lnum > 0
          or one.col > 0
          or one.bufnr ~= 0
          or (type(one.filename) == 'string' and one.filename ~= '')
        )
      then
        it = one
        break
      end
    end
  end
  if it then
    local file
    if it.bufnr ~= 0 then
      file = vim.fn.fnamemodify(vim.fn.bufname(it.bufnr), ':p')
      if file == '' then
        file = nil
      end
    elseif type(it.filename) == 'string' and it.filename ~= '' then
      file = to_abs(it.filename) -- not in any buffer: resolve against the build's cwd
    end
    local msg = it.text or ''
    local kind = msg:match('^%s*error') and 'E'
      or msg:match('^%s*warning') and 'W'
      or msg:match('^%s*note') and 'I'
      or (it.type ~= '' and it.type:upper():sub(1, 1))
      or (S.grep and 'I' or 'E') -- a grep's matches are not errors
    return {
      file = file,
      lnum = it.lnum or 0,
      col = it.col or 0,
      text = text,
      msg = msg ~= '' and msg or nil,
      type = kind,
    }
  end
  -- Lines that carry no location but are still worth their face.
  if
    text:match('^%s*error') -- cargo: `error[E0308]: ...`
    or text:match('^%S*[Ee]rror:') -- python: `SyntaxError: ...`
    or text:match('^make%[%d*%]: %*%*%*') -- make: *** [target] Error 1
    or text:match('^%s*make: %*%*%*')
  then
    return { file = nil, lnum = 0, col = 0, text = text, type = 'E' }
  end
  if text:match('^%s*warning') or text:match('^%s*note:') then
    return { file = nil, lnum = 0, col = 0, text = text, type = 'W' }
  end
  return nil
end

------------------------------------------------------------- the stream --

--- Refine the exact spot of the entry just recorded, from the lines that
--- follow it — the way Emacs' compilation lands on the character regardless
--- of the error format:
---   * Python 3.11+ echoes the offending source line and underlines it with
---     a run of carets (`    ^^^^`; 3.13 mixes tildes in, `  ~~^^~~`).
---     The carets sit under the *echoed* line — which the traceback indents
---     on its own (CPython prepends four spaces) — so the column is
---     translated into the file's coordinates through the echo line
---     recorded here, not used raw.
---   * The exception trailer (`NameError: name 'x' is not defined`) quotes
---     the symbols involved — in 'single' or ‘typographic’ quotes, gcc uses
---     the latter — searched on the error's line at jump time (the first one
---     found there wins). The trailer also becomes the entry's message, so
---     the quickfix list reads `SyntaxError: invalid syntax` instead of the
---     bare `  File "x.py", line 2` that only carried the location.
--- Returns true when the line was consumed as part of the previous error
--- (the caller then keeps it out of the quickfix: it is already in, as the
--- message of the entry it refined).
---@param text string the output line just appended
---@param out_line integer its 1-based line in the output buffer
---@param entry table? the line's own parse, when it recognized one
local function note_exact(text, out_line, entry)
  local last = S.errors[#S.errors]
  if not last or (out_line - last.line) > 4 then
    return false
  end
  local indent, carets = text:match('^(%s*)([%^~]+)%s*$')
  if indent then
    local first = carets:find('%^') or 1
    local col = #indent + first
    local len = #carets
    -- translate the caret out of the echo's coordinates: find where the
    -- echoed text sits on the file's own line, shift by that much
    local echo, fileline = last.entry.echo, nil
    if echo and last.entry.file then
      local ok, fl = pcall(function()
        return (vim.fn.readfile(last.entry.file, '', math.max(last.entry.lnum, 1)))[last.entry.lnum]
      end)
      if ok then
        fileline = fl
      end
    end
    if fileline then
      local trimmed = (echo:gsub('^%s+', ''))
      local at = trimmed ~= '' and fileline:find(trimmed, 1, true) or nil
      if at then
        col = col - #(echo:match('^%s*') or '') + (at - 1)
      end
      if col + len - 1 > #fileline then -- the span cannot run past the line
        len = math.max(1, #fileline - col + 1)
      end
    end
    last.entry.echo = nil
    if col >= 1 then
      last.entry.col = col
      last.entry.len = len
    end
    qf_tick()
    return true
  end
  if text:match('^%u[%w_.]*Error') or text:match('^%a[%w_]*Exception') then
    last.entry.msg = text
    last.entry.echo = nil
    if not last.entry.symbols then
      local syms = {}
      -- quoted symbols, in 'single', "double" or ‘typographic’ quotes (gcc
      -- uses the latter when the locale says so)
      local quoted = [=[[‘"']([^'‘”"]+)['’"]]=]
      for sym in text:gmatch(quoted) do
        syms[#syms + 1] = sym
        if #syms >= 4 then
          break
        end
      end
      if #syms > 0 then
        last.entry.symbols = syms
      end
    end
    return true
  end
  -- the echoed source line: kept for the caret's coordinate translation
  if not entry and not last.entry.echo and text:match('^%s+%S') then
    last.entry.echo = text
    return true
  end
  return false
end

--- Handle one complete line of output.
local function handle_line(raw)
  local text, segs
  if cfg.ansi then
    text, segs = parse_ansi(raw)
  else
    text, segs = raw, {}
  end
  local entry = parse_error(text)
  append_line(text, segs)
  local out_line = vim.api.nvim_buf_line_count(S.buf)
  if entry and entry.file then
    S.errors[#S.errors + 1] = {
      line = out_line,
      entry = entry,
    }
    qf_tick()
  else
    -- a caret line or an exception trailer refines the error recorded
    -- above (its message, its column); when the line recognized as an
    -- error of its own and refined nothing, it is recorded too — as a
    -- message-only quickfix entry (see qf_flush)
    if not note_exact(text, out_line, entry) and entry then
      S.errors[#S.errors + 1] = {
        line = out_line,
        entry = entry,
      }
      qf_tick()
    end
  end
  maybe_scroll()
end

--- Feed a chunk from the job: commit complete lines, keep the rest.
--- \n ends a line; a lone \r (pty progress) ends one too, but a trailing
--- \r waits for the text that will overwrite the line.
local function on_data(chunk)
  if not chunk or chunk == '' or not S.buf then
    return
  end
  S.carry = S.carry .. chunk
  local n = #S.carry
  local i = 1
  while i <= n do
    local nl = S.carry:find('[\r\n]', i)
    if not nl then
      break
    end
    local c = S.carry:sub(nl, nl)
    if c == '\r' and nl == n then
      break -- trailing CR: the line is still coming
    end
    handle_line(S.carry:sub(i, nl - 1))
    i = (c == '\r' and S.carry:sub(nl + 1, nl + 1) == '\n') and nl + 2 or nl + 1
  end
  S.carry = S.carry:sub(i)
end

local function on_exit(code)
  if S.carry ~= '' then
    handle_line(S.carry)
    S.carry = ''
  end
  S.running = false
  S.job = nil
  S.last_code = code

  if S.tmp then
    os.remove(S.tmp) -- the visual run's temp file: the job has drunk it
    S.tmp = nil
  end

  local when = os.date('%H:%M:%S')
  local status, group
  if S.killed then
    status = 'Compilation interrupted.'
    group = { group = 'GliterMakeStopped' }
  elseif S.grep and code == 1 then -- rg: no matches is a result, not a fault
    status = 'No matches.'
    group = { fg = 8 }
  elseif code == 0 then
    status = S.grep and ('%d matches at %s.'):format(#S.errors, when)
      or ('Compilation finished at %s.'):format(when)
    group = { group = 'GliterMakeOk' }
  else
    status = ('Compilation exited abnormally with code %d at %s.'):format(code, when)
    group = { group = 'GliterMakeFail' }
  end

  append_line('', {})
  append_line(status, { { 0, #status, group } })

  qf_flush()
  if (code == 0 or (S.grep and code == 1)) and not S.killed then
    vim.notify('[gliter] ' .. status, vim.log.levels.INFO)
  else
    local where = ''
    if S.errors[1] and not S.grep then
      where = (' (%d jumpable errors; n for the first)'):format(#S.errors)
    end
    vim.notify('[gliter] ' .. status .. where, vim.log.levels.WARN)
    -- Park the output cursor on the first error, Emacs-style visibility.
    if S.win and vim.api.nvim_win_is_valid(S.win) and vim.api.nvim_win_get_buf(S.win) == S.buf then
      local first = S.errors[1]
      if first then
        vim.api.nvim_win_set_cursor(S.win, { first.line, 0 })
        S.last_set = first.line
      end
    end
  end
end

--------------------------------------------------------------- jumping --

--- Flash the error's span in its source buffer: an extmark that lives
--- opts.flash milliseconds, then dissolves. Emacs' compilation cannot
--- leave a selection in the file it points at, so it puts a face on the
--- offending text for a moment instead — n / p cycling and the quickfix's
--- own stepping (:cc, :cnext, <CR> in the quickfix window) flash that way
--- here, while <CR> in the output buffer leaves a real Visual selection.
local flash_gen = 0
local flash_at = { buf = nil, id = nil }

local function flash_clear()
  if flash_at.buf and vim.api.nvim_buf_is_valid(flash_at.buf) and flash_at.id then
    pcall(vim.api.nvim_buf_del_extmark, flash_at.buf, ns, flash_at.id)
  end
  flash_at.buf, flash_at.id = nil, nil
end

---@param buf integer
---@param entry table
local function flash_span(buf, entry)
  if not cfg.flash or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  flash_clear()
  local row = math.max(entry.lnum or 1, 1) - 1
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
  local col, len = entry.col or 0, entry.len or 0
  if col == 0 and entry.symbols then
    for _, sym in ipairs(entry.symbols) do -- the quoted symbols, on the line
      local s, e2 = line:find(sym, 1, true)
      if s then
        col, len = s, e2 - s + 1
        break
      end
    end
  end
  local c1 = math.max(col - 1, 0)
  local c2 = col > 0 and math.min(col - 1 + math.max(len, 1), #line) or #line
  flash_at.id = vim.api.nvim_buf_set_extmark(buf, ns, row, c1, {
    end_line = row,
    end_col = math.max(c2, c1),
    hl_group = 'GliterMakeFlash',
    hl_mode = 'combine',
    priority = 300,
  })
  flash_at.buf = buf
  flash_gen = flash_gen + 1
  local gen = flash_gen
  vim.defer_fn(function()
    if flash_gen == gen then
      flash_clear()
    end
  end, cfg.flash)
end

--- Jump to an error entry: the window the build started from, the file
--- edited in it (so the jump lands on the jumplist), cursor on the exact
--- character — the parsed column, else the error's quoted symbols searched
--- on the line — and the span VISUALLY SELECTED (v-mode) and left selected,
--- so the next key acts on exactly what the compiler pointed at: c to
--- change it, y to yank it, i to type over it. (Emacs' compilation only
--- flashes a face for the span; Vim has a real selection grammar, so the
--- jump ends IN Visual mode.) `focus` also moves the cursor into the
--- target window — <CR> from the output buffer does, so the jump is
--- impossible to miss; n / p keep you in the output to cycle, where
--- style = 'flash' only flashes the span instead of selecting it.
---@param e table
---@param focus? boolean
---@param style? 'select'|'flash'
local function jump_to(e, focus, style)
  local w = origin_window()
  if not w then
    vim.notify('[gliter] no window to jump in', vim.log.levels.WARN)
    return
  end
  local entry = e.entry
  if entry.file then
    if focus and vim.api.nvim_win_is_valid(w) then
      -- first, not last: switching the current window after the selection
      -- started would end Visual mode the instant it appears
      vim.api.nvim_set_current_win(w)
    end
    vim.api.nvim_win_call(w, function()
      if vim.api.nvim_buf_get_name(0) ~= entry.file then
        pcall(vim.cmd.edit, vim.fn.fnameescape(entry.file))
      end
      local col, len = entry.col or 0, entry.len or 0
      if col == 0 and entry.symbols then
        -- whatever the format said: the offending symbol is on the line
        local line = vim.api.nvim_buf_get_lines(0, entry.lnum - 1, entry.lnum, false)[1] or ''
        for _, sym in ipairs(entry.symbols) do
          local s, e2 = line:find(sym, 1, true)
          if s then
            col, len = s, e2 - s + 1
            break
          end
        end
      end
      local row = math.max(entry.lnum, 1)
      vim.api.nvim_win_set_cursor(w, { row, math.max(col - 1, 0) })
      vim.cmd('normal! zv')
      if style ~= 'flash' and col > 0 and len > 0 then
        -- v from the first character of the span, cursor slid onto the last
        vim.cmd('normal! v')
        vim.api.nvim_win_set_cursor(w, { row, math.max(col - 1, 0) + math.max(len - 1, 0) })
      end
      vim.cmd('normal! zz')
    end)
    if style == 'flash' then
      flash_span(vim.api.nvim_win_get_buf(w), entry)
    end
  else
    -- a message-only error (no file of its own): there is nothing to open
    -- — the output line IS the location, and the tail below parks the
    -- output cursor on it. The message is echoed, so n / p through a
    -- run of bare trailers still says something.
    vim.notify('[gliter] ' .. (entry.msg or entry.text or ''), vim.log.levels.INFO)
  end
  -- Show where we are in the output, if it is on screen.
  if S.win and vim.api.nvim_win_is_valid(S.win) and vim.api.nvim_win_get_buf(S.win) == S.buf then
    vim.api.nvim_win_set_cursor(S.win, { math.max(e.line, 1), 0 })
    S.last_set = e.line
    S.follow = true
  end
end

--- Move through the error locations, :cnext-style but from the compilation
--- buffer, jumping in the origin window — the span flashed for a quick
--- second where it lands (opts.flash), because a selection parked in a
--- window you are not in is no use to anyone.
---@param dir integer 1 next, -1 previous
function M.cycle(dir)
  if #S.errors == 0 then
    vim.notify('[gliter] no errors in the output', vim.log.levels.INFO)
    return
  end
  local new = S.cursor_idx + dir
  if new < 1 then
    new = 1
    if S.cursor_idx == 1 then
      vim.notify('[gliter] already at the first error')
    end
  elseif new > #S.errors then
    new = #S.errors
    if S.cursor_idx == #S.errors then
      vim.notify('[gliter] already at the last error')
    end
  end
  S.cursor_idx = new
  jump_to(S.errors[new], false, 'flash')
end

--- Jump to the error on the cursor line — or the first one below it, and
--- when the cursor sits below the last error (the trailer lines at the end
--- of the output, say), the last one above: <CR> always goes somewhere as
--- long as there is an error to go to. The cursor moves into the target
--- window (Emacs' compile-goto-error does the same), with the recognized
--- span left selected there.
function M.jump_at_cursor()
  if #S.errors == 0 then
    vim.notify('[gliter] no errors in the output', vim.log.levels.INFO)
    return
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local chosen, chosen_idx = S.errors[#S.errors], #S.errors
  for idx, e in ipairs(S.errors) do
    if e.line >= row then
      chosen, chosen_idx = e, idx
      break
    end
  end
  S.cursor_idx = chosen_idx
  jump_to(chosen, true, 'select')
end

-------------------------------------------------------------- runner --

--- '%' (and '%:p', '%:h', ...) in a runner program expands to the buffer's
--- file — full path, shell-escaped, so names with spaces survive. A '%s'
--- anywhere in the template switches it to printf style instead:
--- string.format(prog, shellescape(file)).
---@param prog string
---@param buf integer
---@return string? cmd
local function expand_runner(prog, buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' then
    return nil
  end
  local file = vim.fn.fnamemodify(name, ':p')
  if prog:find('%%s', 1, true) then
    local ok, out = pcall(string.format, prog, vim.fn.shellescape(file))
    if ok then
      return out
    end
  end
  return (prog:gsub('%%([:%.~%w]*)', function(mod)
    return vim.fn.shellescape(vim.fn.fnamemodify(file, mod ~= '' and (':' .. mod) or ':p'))
  end))
end

--- Start `cmd` as a terminal in the current buffer and return its job id.
--- jobstart()'s `term = true` is the modern door; termopen() the old one —
--- called WITHOUT its optional {opts} dict, which is the fix for the
--- E475 the shells keys used to die with: an empty Lua table no longer
--- crosses the fn bridge as a dictionary, and `termopen(cmd, {})`
--- rejects it (Neovim 0.11+).
---@param cmd string
---@return integer? id, string? err
local function term_open(cmd)
  local buf = vim.api.nvim_get_current_buf()
  local ok, id = pcall(vim.fn.jobstart, cmd, { term = true })
  if ok and type(id) == 'number' and id > 0 then
    -- Neovim 0.10's jobstart(term=true) can return a live job id yet
    -- never attach the terminal to the buffer (buftype stays ''): wait
    -- a tick for the attachment, and treat a detached job as a failure
    -- so the termopen fallback below gets its chance
    if vim.wait(50, function()
      return vim.bo[buf].buftype == 'terminal'
    end) and vim.bo[buf].buftype == 'terminal' then
      return id
    end
    pcall(vim.fn.jobstop, id) -- the detached job, out of the way
  end
  ok, id = pcall(vim.fn.termopen, cmd) -- no opts: none are needed here
  if ok and type(id) == 'number' and id > 0 then
    return id
  end
  return nil, tostring(id)
end

--- A real terminal window at the bottom, for the runner commands that need
--- a keyboard (fzf, a shell): the compilation buffer is a pipe, and a
--- pipe has no keyboard. A user `runner.output` replaces this too.
local function terminal_split(cmd)
  -- one at a time: a previous launcher whose process is over is closed, so
  -- dead terminals do not stack up
  if S.term_win and vim.api.nvim_win_is_valid(S.term_win) then
    local old = vim.api.nvim_win_get_buf(S.term_win)
    local jid = vim.b[old] and vim.b[old].terminal_job_id
    if not (jid and vim.fn.jobwait({ jid }, 0)[1] == -1) then
      pcall(vim.api.nvim_win_close, S.term_win, true)
      S.term_win = nil
    end
  end
  -- :new, not :split — a split repeats the CURRENT buffer in the new
  -- window, and jobstart(term=true) refuses a modified (or nofile) one:
  -- "requires unmodified buffer". :new hands over a fresh, empty buffer
  -- every time, whatever window the launcher was pressed in.
  vim.cmd('botright ' .. math.max(1, cfg.height) .. 'new')
  local win = vim.api.nvim_get_current_win()
  S.term_win = win
  local id, err = term_open(cmd)
  if not id then
    pcall(vim.api.nvim_win_close, win, true)
    S.term_win = nil
    return vim.notify('[gliter] terminal: ' .. (err or 'cannot start'), vim.log.levels.ERROR)
  end
  local buf = vim.api.nvim_win_get_buf(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  -- q closes the window once the process is over; i goes back in
  vim.keymap.set('n', 'q', function()
    local jid = vim.b[buf].terminal_job_id
    if jid and vim.fn.jobwait({ jid }, 0)[1] == -1 then
      return vim.notify('[gliter] still running — i to use it, :bd! to kill it', vim.log.levels.INFO)
    end
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, silent = true, desc = 'gliter.make: close this terminal window' })
  vim.cmd('startinsert') -- you opened it to use it
end

--- Where a runner command goes. `runner.output` — yours to set — takes the
--- whole job and does with it what it wants (the doc's example opens a
--- floating Snacks terminal); the default runs it through the compilation
--- buffer and the quickfix, with terminal_split() for the interactive
--- commands a pipe cannot serve.
---@param spec table { cmd, kind = 'file'|'visual'|'grep'|'shell', ft,
---   file, interactive, title, efms, grep, tmp }
local function runner_output(spec)
  if type(cfg.runner.output) == 'function' then
    local ok, err = pcall(cfg.runner.output, spec)
    if not ok then
      vim.notify('[gliter] runner.output: ' .. err, vim.log.levels.ERROR)
    end
    return
  end
  if spec.interactive then
    return terminal_split(spec.cmd)
  end
  M.run(nil, {
    cmd = spec.cmd,
    efms = spec.efms,
    title = spec.title,
    grep = spec.grep,
    tmp = spec.tmp,
  })
end

--- The buffer a runner key was pressed in — not the output buffer, when
--- the press happens to come from there.
local function run_origin()
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_win_get_buf(win)
  if S.buf and buf == S.buf then
    win = origin_window() or win
    buf = vim.api.nvim_win_get_buf(win)
  end
  return buf
end

--- <Leader>lr — run the current FILE: runner.programs[filetype] ('pypy3 %'
--- for python, 'gcc -g % && ./a.out' for c, ...), through `runner.output`
--- (default: the compilation buffer, errors and matches in the quickfix).
--- `args` (from :GliterRun) is appended.
---@param args? string
function M.run_file(args)
  local buf = run_origin()
  local ft = vim.bo[buf].filetype
  local prog = cfg.runner.programs[ft]
  if prog == nil and ft == '' then
    prog = cfg.runner.programs['']
  end
  if prog == nil then
    prog = cfg.runner.programs['*']
  end
  local interactive = false
  if type(prog) == 'table' then
    -- { cmd = 'python -i %', interactive = true }: a program with a stdin
    -- habit can ask for a real terminal up front, instead of i / t in the
    -- output buffer once it starts asking
    interactive = prog.interactive == true
    prog = prog.cmd or prog[1]
  end
  local show = ft ~= '' and ft or "''"
  if prog == false then
    return vim.notify(('[gliter] runner disabled for filetype %s'):format(show), vim.log.levels.INFO)
  end
  if not prog then
    return vim.notify(('[gliter] no run command for filetype %s — add runner.programs["%s"] = "pypy3 %%"'):format(show, show), vim.log.levels.WARN)
  end
  local cmd = expand_runner(prog, buf)
  if not cmd then
    return vim.notify('[gliter] this buffer has no file to run', vim.log.levels.WARN)
  end
  if vim.bo[buf].modified then
    vim.notify('[gliter] buffer modified — running the saved version on disk', vim.log.levels.INFO)
  end
  args = (args or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if args ~= '' then
    cmd = cmd .. ' ' .. args
  end
  runner_output({ cmd = cmd, kind = 'file', ft = ft, file = vim.api.nvim_buf_get_name(buf), interactive = interactive })
end

--- x<Leader>lr — run the live VISUAL SELECTION through
--- runner.visual[filetype]: the selection — read live, from v to ., because
--- '< '> are only written when Visual mode ends and this fires before that
--- — is written to a temp file and piped to the interpreter.
function M.run_visual()
  local buf = run_origin()
  local ft = vim.bo[buf].filetype
  local interp = cfg.runner.visual[ft]
  if not interp then
    return vim.notify(('[gliter] no interpreter for selections of filetype %s — add runner.visual["%s"] = "cmd"'):format(ft ~= '' and ft or "''", ft), vim.log.levels.WARN)
  end
  local vstart = vim.fn.getpos('v')
  local vend = vim.fn.getpos('.')
  local first = math.min(vstart[2], vend[2])
  local last = math.max(vstart[2], vend[2])
  local lines = vim.api.nvim_buf_get_lines(0, first - 1, last, false)
  if #lines == 0 or (#lines == 1 and lines[1] == '') then
    return vim.notify('[gliter] empty selection', vim.log.levels.WARN)
  end
  local tmp = vim.fn.tempname()
  if not pcall(vim.fn.writefile, lines, tmp) then
    return vim.notify('[gliter] cannot write the selection to a temp file', vim.log.levels.ERROR)
  end
  runner_output({
    cmd = interp .. ' < ' .. vim.fn.shellescape(tmp),
    kind = 'visual',
    ft = ft,
    tmp = tmp, -- removed when the default run's job is done; a custom
    -- output owns it from here on
  })
end

--- <Leader>lp — grep a pattern through the runner: the matches land in
--- the quickfix (and flash on stepping, like errors do), the output keeps
--- its colors in the compilation buffer. The binary is `runner.grep_prog`
--- — 'rg' by default ('rg --vimgrep --color=always -- <pat> .'), any other
--- name runs as '<bin> -rn -- <pat> .', and false — or a binary that is
--- not installed — falls back to :vimgrep (M.vimgrep), no external tool
--- needed. `pat` skips the prompt (:GliterGrep); the prompt is prefilled
--- with the word under the cursor.
---@param pat? string
function M.grep(pat)
  local function go(input)
    if not input or vim.trim(input) == '' then
      return
    end
    local prog = cfg.runner.grep_prog
    if prog ~= false then
      if type(prog) == 'table' then -- { cmd = 'rg --vimgrep --', efm = '...' }
        local cmd = (prog.cmd or prog[1] or 'rg --vimgrep --color=always --')
          .. ' ' .. vim.fn.shellescape(input) .. ' .'
        return runner_output({
          cmd = cmd,
          kind = 'grep',
          efms = prog.efms or { '%f:%l:%c:%m' },
          title = 'gliter grep: ' .. input,
          grep = true,
        })
      end
      prog = (type(prog) == 'string' and prog ~= '') and prog or 'rg'
      if vim.fn.executable(prog) == 1 then
        local args = prog == 'rg' and ' --vimgrep --color=always -- ' or ' -rn -- '
        return runner_output({
          cmd = prog .. args .. vim.fn.shellescape(input) .. ' .',
          kind = 'grep',
          efms = { prog == 'rg' and '%f:%l:%c:%m' or '%f:%l:%m' },
          title = 'gliter ' .. prog .. ': ' .. input,
          grep = true,
        })
      end
      vim.notify(('[gliter] %s not found — :vimgrep instead'):format(prog), vim.log.levels.WARN)
    end
    M.vimgrep(input)
  end
  if pat and pat ~= '' then
    return go(pat)
  end
  vim.ui.input({ prompt = 'rg: ', default = vim.fn.expand('<cword>') }, go)
end

--- The no-binary grep: :vimgrep from the working directory, the matches
--- poured into the same quickfix/flash machinery a ripgrep run fills —
--- n / p and :cnext step them with the flash and all.
---@param pat string
function M.vimgrep(pat)
  if not pat or pat == '' then
    return
  end
  -- under \V only the backslash is special; / must not end the pattern,
  -- and | or " would end the whole : command — all four are defused
  local esc = pat:gsub('\\', '\\\\'):gsub('/', [[\/]]):gsub('[|"\n]', ' ')
  vim.cmd(('silent! noautocmd vimgrep /\\V%s/gj **/*'):format(esc))
  local items = vim.fn.getqflist({ items = 0 }).items or {}
  S.errors = {}
  S.cursor_idx = 0
  for _, it in ipairs(items) do
    local file = (type(it.filename) == 'string' and it.filename ~= '') and it.filename
      or (it.bufnr ~= 0 and vim.fn.bufname(it.bufnr) or nil)
    if file and file ~= '' then
      file = vim.fs.normalize(vim.fn.fnamemodify(file, ':p'))
      S.errors[#S.errors + 1] = {
        line = 0,
        entry = {
          file = file,
          lnum = it.lnum or 0,
          col = it.col or 0,
          len = 0,
          text = it.text or '',
          type = 'I',
        },
      }
    end
  end
  local qf_items = {}
  for _, e in ipairs(S.errors) do
    local item = { filename = e.entry.file, lnum = e.entry.lnum, text = e.entry.text, type = 'I' }
    if e.entry.col > 0 then
      item.col = e.entry.col
    end
    qf_items[#qf_items + 1] = item
  end
  vim.fn.setqflist({}, ' ', { items = qf_items, title = 'gliter vimgrep: ' .. pat })
  S.qf_id = vim.fn.getqflist({ id = 0 }).id
  vim.notify(('[gliter] %d matches — :copen, :cnext'):format(#S.errors), vim.log.levels.INFO)
end

--- <Leader>l<key> — the launchers of runner.shells (fzf and tree by
--- default). `interactive` ones get a real terminal by default; the rest
--- the compilation buffer.
---@param key string
function M.shell(key)
  local s = cfg.runner.shells[key]
  if not s then
    return
  end
  local cmd, interactive = s, false
  if type(s) == 'table' then
    cmd = s.cmd or s[1]
    interactive = s.interactive == true or s[2] == true
  end
  if not cmd then
    return
  end
  runner_output({ cmd = cmd, kind = 'shell', interactive = interactive, title = 'gliter ' .. cmd })
end

------------------------------------------------------------------- api --

--- Stop the running build.
function M.stop()
  if S.job then
    S.killed = true
    vim.fn.jobstop(S.job)
    S.job = nil
    S.running = false
    vim.notify('[gliter] compilation stopped', vim.log.levels.INFO)
  end
end

--- Type a line to the running build's stdin (i, a, I, A in the output
--- buffer): the job's pipe always had one — the buffer just never showed
--- it. The line is echoed dim into the output (a comint input echo) and
--- sent on: python's input(), cat, a REPL that landed in the compilation
--- buffer, all answer it. For a program that wants more than lines,
--- M.run_in_term (t) takes the whole run to a real terminal.
---@param text string
function M.send_input(text)
  if not (S.job and S.running) then
    return vim.notify('[gliter] nothing is running', vim.log.levels.INFO)
  end
  text = text or ''
  local ok = pcall(vim.fn.chansend, S.job, text .. '\n')
  if not ok then
    return vim.notify('[gliter] the program is no longer running', vim.log.levels.WARN)
  end
  append_line(text, { { 0, #text, { fg = 8 } } })
  maybe_scroll()
end

--- Re-run the last command in a real terminal window (t in the output
--- buffer) — the escape hatch for programs that need a whole keyboard,
--- not just a line: the pipe job is stopped and the same command starts
--- over in terminal_split, where stdin is a tty.
function M.run_in_term()
  if not S.cmd then
    return vim.notify('[gliter] nothing has run yet', vim.log.levels.INFO)
  end
  M.stop()
  terminal_split(S.cmd)
end

--- Show the output window (focus it).
function M.show()
  ensure_buf()
  if vim.api.nvim_buf_line_count(S.buf) == 1 and (vim.api.nvim_buf_get_lines(S.buf, 0, 1, false)[1] or '') == '' then
    vim.bo[S.buf].modifiable = true
    vim.api.nvim_buf_set_lines(S.buf, 0, 1, false, { ('No compilation yet — %s or :GliterMake runs one.'):format(cfg.keys.run or '<Leader>lm') })
    vim.bo[S.buf].modifiable = false
    S.replace_first = false
  end
  open_win()
  if S.win and vim.api.nvim_win_is_valid(S.win) then
    vim.api.nvim_set_current_win(S.win)
  end
end

--- Close the output window (the buffer stays, like Emacs' *compilation*).
function M.hide()
  -- q / <Esc> run with the output buffer current; close the window that
  -- shows it (S.win, or whichever the user split it into).
  local win = S.win
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(cur) and S.buf and vim.api.nvim_win_get_buf(cur) == S.buf then
    win = cur
  end
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  if #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(win)) == 1 then
    -- The only window in its tab page: closing it is E444. The buffer is
    -- bufhidden=hide, so an empty buffer takes the window instead.
    pcall(vim.api.nvim_win_call, win, function()
      vim.cmd('enew')
    end)
    return
  end
  pcall(vim.api.nvim_win_close, win, false)
end

--- Run the build: 'makeprg' of the current buffer (expanded like :make
--- does), plus `args` from the command line. A running build is restarted.
--- `o` is the runner's half of the API: { cmd = an explicit command
--- (already shell-ready), efms = 'errorformat's tried before the buffer's
--- own, title = the quickfix title, grep = exit 1 means "no matches",
--- tmp = a file to remove when the job is done }.
---@param args? string
---@param o? table
function M.run(args, o)
  o = o or {}
  args = (args or ''):gsub('^%s+', ''):gsub('%s+$', '')

  -- Where the build starts from — not the output buffer itself.
  local origin_win = vim.api.nvim_get_current_win()
  local origin_buf = vim.api.nvim_win_get_buf(origin_win)
  if S.buf and origin_buf == S.buf then
    origin_win = origin_window() or origin_win
    origin_buf = vim.api.nvim_win_get_buf(origin_win)
  end

  local cmd = o.cmd -- the runner sends its own, already expanded
  if not cmd then
    cmd = vim.bo[origin_buf].makeprg
    if cmd == '' then -- global-local: no local value, use the global
      cmd = vim.o.makeprg
    end
    if cmd == '' then
      cmd = cfg.programs['*'] or 'make'
    end
    local okc, expanded = pcall(vim.api.nvim_buf_call, origin_buf, function()
      return vim.fn.expandcmd(cmd)
    end)
    cmd = okc and expanded or cmd
  end
  if args ~= '' then
    cmd = cmd .. ' ' .. args
  end

  if S.job then
    M.stop()
  end

  S.origin_win = origin_win
  S.origin_buf = origin_buf
  S.cmd = cmd
  S.args = args
  S.cwd = vim.fn.getcwd()
  S.efm = vim.bo[origin_buf].errorformat
  if S.efm == '' then -- errorformat is global-local, like makeprg
    S.efm = vim.o.errorformat
  end
  -- The formats tried per output line, in order (see parse_error): the
  -- buffer's own — the user's :setl efm=..., or gliter's per-filetype one —
  -- then the rest of this filetype's list, then Vim's default.
  local list = {}
  local function add(efm)
    if type(efm) == 'string' and efm ~= '' and not vim.tbl_contains(list, efm) then
      list[#list + 1] = efm
    end
  end
  for _, efm in ipairs(o.efms or {}) do -- this run's own first (a grep's)
    add(efm)
  end
  add(S.efm)
  local cfgd = cfg.errorformats[vim.bo[origin_buf].filetype]
  if type(cfgd) == 'string' then
    add(cfgd) -- a string value stays supported
  elseif type(cfgd) == 'table' then
    for _, efm in ipairs(cfgd) do
      add(efm)
    end
  end
  add(vim.o.errorformat)
  S.efms = list
  S.carry = ''
  S.errors = {}
  S.cursor_idx = 0
  S.follow = true
  S.killed = false
  S.last_code = 0
  S.running = true
  S.last_set = 0
  S.title = o.title
  S.grep = o.grep == true
  S.tmp = o.tmp
  -- A run of its own: callbacks from a previous (stopped) job must not
  -- leak into this one's buffer and state.
  S.gen = (S.gen or 0) + 1
  local gen = S.gen

  ensure_buf()
  open_win()

  -- Reset the buffer, then echo the command the way Emacs does.
  vim.api.nvim_buf_clear_namespace(S.buf, ns, 0, -1)
  vim.bo[S.buf].modifiable = true
  vim.api.nvim_buf_set_lines(S.buf, 0, -1, false, {})
  vim.bo[S.buf].modifiable = false
  S.replace_first = true
  local dim = { fg = 8 } -- the command line, quietly
  append_line(cmd, { { 0, #cmd, dim } })
  append_line('', {})
  if S.win and vim.api.nvim_win_is_valid(S.win) and vim.api.nvim_win_get_buf(S.win) == S.buf then
    vim.api.nvim_win_set_cursor(S.win, { 2, 0 })
    S.last_set = 2
  end

  local job_opts = {
    cwd = S.cwd,
    on_stdout = function(_, chunk)
      -- jobstart delivers chunks as a list of \n-separated pieces with the
      -- newlines stripped (a trailing "" means the chunk ended in \n)
      if S.gen ~= gen then
        return
      end
      if type(chunk) == 'table' then
        on_data(table.concat(chunk, '\n'))
      elseif chunk then
        on_data(chunk)
      end
    end,
    on_stderr = function(_, chunk)
      if S.gen ~= gen then
        return
      end
      if type(chunk) == 'table' then
        on_data(table.concat(chunk, '\n'))
      elseif chunk then
        on_data(chunk)
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if S.gen == gen then
          on_exit(code)
        end
      end)
    end,
  }
  if cfg.env ~= false then
    job_opts.env = cfg.env
  end
  if cfg.pty then
    job_opts.pty = true
    local w = tonumber(cfg.width) or 0
    if w <= 0 then
      w = 100
      if vim.api.nvim_win_is_valid(origin_win) then
        w = math.max(100, vim.api.nvim_win_get_width(origin_win))
      end
    end
    job_opts.width = w
    job_opts.height = 60
    if not vim.env.TERM or vim.env.TERM == '' then
      -- a GUI-launched nvim has no TERM; a pty without one is a terminal
      -- every tool draws plain. Say xterm-256color so the colors come.
      job_opts.env = type(job_opts.env) == 'table'
          and vim.tbl_extend('force', job_opts.env, { TERM = 'xterm-256color' })
          or { TERM = 'xterm-256color' }
    end
  end

  S.job = vim.fn.jobstart(cmd, job_opts)
  if S.job <= 0 then
    S.job = nil
    S.running = false
    append_line('', {})
    append_line('Compilation failed: cannot start the command.', { { 0, 44, { group = 'GliterMakeFail' } } })
    vim.notify('[gliter] cannot run: ' .. cmd, vim.log.levels.ERROR)
    return
  end
end

--------------------------------------------------------------- setup --

--- 'makeprg' (and 'errorformat') for one buffer, from the tables.
local function apply_to_buf(buf)
  if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].buftype ~= '' then
    return
  end
  local ft = vim.bo[buf].filetype
  if ft == '' then
    return
  end
  local prog = cfg.programs[ft] or cfg.programs['*']
  if prog then
    -- A buffer the user has configured (a local 'makeprg' of their own, or a
    -- global one that is not the default) is left alone; so is a local value
    -- gliter itself set earlier. For global-local options vim.bo reads the
    -- local side only, and it reads as '' when no local value is set.
    local legacy = { 'python -m py_compile %' } -- defaults of earlier versions: migrate them
    local function untouched(v)
      if v == '' or v == 'make' then
        return true
      end
      for _, x in pairs(cfg.programs) do
        if v == x then
          return true
        end
      end
      for _, x in ipairs(legacy) do
        if v == x then
          return true
        end
      end
      return false
    end
    if untouched(vim.bo[buf].makeprg) and untouched(vim.o.makeprg) then
      vim.bo[buf].makeprg = prog
    end
  end
  local efm = cfg.errorformats[ft]
  if efm then
    if type(efm) == 'table' then
      efm = efm[1] -- the buffer option takes the first; parse_error tries the list
    end
    vim.bo[buf].errorformat = efm
  end
end

---@param opts? table
function M.setup(opts)
  opts = (type(opts) == 'table') and opts or {}
  for k, v in pairs(opts) do
    if k == 'keys' or k == 'programs' or k == 'errorformats' or k == 'env' then
      cfg[k] = vim.tbl_extend('force', cfg[k] or {}, (type(v) == 'table') and v or {})
    elseif k == 'runner' then -- nested tables merge (programs, visual,
      -- shells); a function value (output) replaces
      cfg.runner = vim.tbl_deep_extend('force', cfg.runner, (type(v) == 'table') and v or {})
    else
      cfg[k] = v
    end
  end
  M.did_setup = true

  define_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('GliterMake', { clear = true }),
    callback = define_highlights,
  })

  -- 'makeprg' per filetype
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('GliterMakePrg', { clear = true }),
    callback = function(args)
      apply_to_buf(args.buf)
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      apply_to_buf(buf)
    end
  end

  local function map(key, fn, desc)
    if key then
      vim.keymap.set('n', key, fn, { silent = true, desc = 'gliter.make: ' .. desc })
    end
  end
  map(cfg.keys.run, function()
    M.run()
  end, 'run the build (make), Emacs compile-style')
  map(cfg.keys.show, M.show, 'show the make output window')
  map(cfg.keys.stop, M.stop, 'stop the running build')

  -- the runner: <Leader>lr runs the file (x<Leader>lr the selection),
  -- <Leader>lp greps (in Visual mode: the selection is the pattern), and
  -- every runner.shells key is <Leader>l<key>
  if cfg.keys.run_file then
    vim.keymap.set('n', cfg.keys.run_file, function()
      M.run_file()
    end, { silent = true, desc = 'gliter.make: run the current file (runner.programs)' })
    vim.keymap.set('x', cfg.keys.run_file, function()
      M.run_visual()
    end, { silent = true, desc = 'gliter.make: run the visual selection (runner.visual)' })
  end
  if cfg.keys.grep then
    vim.keymap.set('n', cfg.keys.grep, function()
      M.grep()
    end, { silent = true, desc = 'gliter.make: ripgrep a pattern, quickfix matches' })
    vim.keymap.set('x', cfg.keys.grep, function()
      -- a one-line selection is the pattern itself (read live: v to .);
      -- anything else falls back to the prompt
      local vs, ve = vim.fn.getpos('v'), vim.fn.getpos('.')
      if vs[2] == ve[2] then
        local line = vim.api.nvim_get_current_line()
        local sel = line:sub(math.min(vs[3], ve[3]), math.max(vs[3], ve[3]))
        if sel:find('%S') then
          return M.grep(sel)
        end
      end
      M.grep()
    end, { silent = true, desc = 'gliter.make: ripgrep the selection, quickfix matches' })
  end
  for k, s in pairs(cfg.runner.shells) do
    local key = (type(k) == 'string' and #k == 1) and ('<Leader>l' .. k) or k
    local cmd = (type(s) == 'table' and (s.cmd or s[1])) or s
    if cmd then
      vim.keymap.set({ 'n', 'v' }, key, function()
        M.shell(k)
      end, { silent = true, desc = 'gliter.make runner: ' .. cmd })
    end
  end

  vim.api.nvim_create_user_command('GliterMake', function(a)
    M.run(a.args)
  end, { nargs = '*', desc = 'Run makeprg and show the output like Emacs compile' })
  vim.api.nvim_create_user_command('GliterMakeShow', M.show, { desc = 'Show the gliter.make output window' })
  vim.api.nvim_create_user_command('GliterMakeStop', M.stop, { desc = 'Stop the running gliter.make build' })
  vim.api.nvim_create_user_command('GliterRun', function(a)
    M.run_file(a.args ~= '' and a.args or nil)
  end, { nargs = '*', desc = 'Run the current file (gliter.make runner)' })
  vim.api.nvim_create_user_command('GliterGrep', function(a)
    M.grep(a.args ~= '' and a.args or nil)
  end, { nargs = '*', desc = 'ripgrep a pattern into the quickfix (gliter.make runner)' })

  -- Stepping through our quickfix list — :cc, :cnext, :cprev, <CR> in
  -- the quickfix window — flashes the span of the entry landed on, the
  -- same quick second n / p flash in the output buffer. :cnext and
  -- friends do NOT fire QuickFixCmdPost (that event belongs to the
  -- commands that FILL the list: :make, :grep, ...), so the stepping is
  -- watched where it can actually be seen: the command line (every
  -- typed :cnext/:cprev/:cc/...), and the quickfix window's own <CR>.
  -- The list id says the list is this run's; anyone else's
  -- (gliter.ctags', :grep's) is left alone.
  local function flash_on_qf_step()
    if not cfg.flash then
      return
    end
    local qf = vim.fn.getqflist({ id = 0, idx = 0 })
    if not S.qf_id or qf.id ~= S.qf_id or not qf.idx or qf.idx < 1 then
      return
    end
    local e = S.errors[qf.idx] -- the fills are 1:1 with S.errors
    if not e or not e.entry.file then
      return
    end
    local buf = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_get_name(buf) ~= e.entry.file then
      buf = vim.fn.bufnr(e.entry.file)
      if buf == -1 then
        return
      end
    end
    flash_span(buf, e.entry)
  end

  -- the quickfix window's <CR>: :cc (a location list: :ll) to the entry
  -- under the cursor — the qf buffer lists entries one per line — then
  -- the flash
  vim.api.nvim_create_autocmd('FileType', {
    group = vim.api.nvim_create_augroup('GliterMakeQf', { clear = true }),
    pattern = 'qf',
    callback = function(a)
      vim.keymap.set('n', '<CR>', function()
        local n = vim.v.count
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local target = math.max(1, n ~= 0 and n or row)
        local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1] or {}
        if info.loclist == 1 then
          vim.cmd('ll ' .. target)
        else
          vim.cmd('cc ' .. target)
        end
        flash_on_qf_step()
      end, { buffer = a.buf, nowait = true, desc = 'gliter.make: jump to this entry (and flash its span)' })
    end,
  })

  -- :cnext and friends, as typed: capture the command line as it
  -- changes (getcmdline() is only honest during CmdlineChanged), and on
  -- leave, if it was one of the stepping commands, flash after it ran
  local step_cmds = {
    cnext = true, cn = true,
    cprev = true, cp = true, cprevious = true,
    cnextfile = true, cnf = true, cpfile = true, cpf = true,
    cfirst = true, cfir = true, clast = true, cla = true,
    cc = true, cnewer = true, colder = true,
  }
  local last_cmdline = ''
  vim.api.nvim_create_autocmd('CmdlineChanged', {
    group = vim.api.nvim_create_augroup('GliterMakeQfCmd', { clear = true }),
    pattern = ':',
    callback = function()
      last_cmdline = vim.fn.getcmdline()
    end,
  })
  vim.api.nvim_create_autocmd('CmdlineLeave', {
    group = vim.api.nvim_create_augroup('GliterMakeQfLeave', { clear = true }),
    pattern = ':',
    callback = function()
      local ev = vim.v.event or {}
      if ev.abort then
        return
      end
      local name = (last_cmdline or ''):match('^%s*:?%d*([%a]+)')
      if not (name and step_cmds[name]) then
        return
      end
      -- the command runs right after this event; the flash must read
      -- the quickfix index it leaves behind
      vim.schedule(flash_on_qf_step)
    end,
  })
end

return M
