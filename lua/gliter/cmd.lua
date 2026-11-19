--- gliter.cmd — readline's keys on the command line Neovim already
--- has, and fish's ghost on top of it. That is the whole module: the
--- built-in command line stays the command line — every builtin key
--- keeps working, Tab and S-Tab above all (the wildmenu opens and
--- walks exactly the way it always did; the keys the menu owns —
--- C-n/C-p, Left/Right, C-e — pass through to it untouched) — and
--- gliter adds the keys readline has had since 1988 that the built-in
--- line lacks, plus the ghost echo: the history's continuation drawn
--- dimmed after the line, fish's autosuggestion (2005). `:w` with
--- ` file` ghosted after it runs `:w` — Enter runs the text alone,
--- the ghost is never the line; C-p cycles the echoes — the entries
--- the line could be, one older at a time, the text staying — C-n
--- cycles them back, and at the newest it takes the echo (so do C-f,
--- C-e and Right at the end of the line); C-y and M-l take whichever
--- echo is showing. The other prompts — input()'s, netrw's `%<mark>`
--- regexp, w3's address — are command lines too, and the same keys
--- and the same ghost ride on them (their answers live in the `@`
--- history).
---
--- The editing keys are readline's (Brian Fox, 1988): C-a/C-e to the
--- ends of the line, C-b/C-f by character, M-b/M-f by word, C-d
--- deleting at the cursor, M-BS/M-d the word before/after it, C-k to
--- the end, C-t transposing — each a cnoremap that edits the line
--- through setcmdline(), the way c_CTRL-\_e always did. What the
--- built-in line has readline-style already — C-w, C-u, C-h, C-r
--- {reg} (C-r C-w: the word under the cursor), C-v, C-y, Up/Down —
--- is left exactly as it is, and readline's Tab is the wildmenu's
--- Tab: untouched, both it and S-Tab. While the menu is up the edit
--- keys sleep and the menu's own keys go straight to it — C-e is its
--- revert, Right rides C-n's next match — and C-f's old job of opening
--- the command-line window is q:'s alone now.
---
--- setup { ghost = false } keeps the keys and drops the ghost —
--- C-n/C-p then stay the built-in history recall they always were.
--- M.state() reports the line, the echoes it could be and which one
--- is showing, for tests and statuslines.
local M = {}

--- vim.keycode (0.10+), or its 0.9 stand-in
local keycode = vim.keycode
  or function(s)
    return vim.api.nvim_replace_termcodes(s, true, true, true)
  end

M.defaults = {
  ghost = true, -- the history's continuation after the line, fish's
                -- autosuggestion; false = the readline keys alone,
                -- C-n/C-p/Right left to their built-in jobs
  max_history = 200, -- how many history entries feed the ghost echoes
}

M.options = vim.deepcopy(M.defaults)

---------------------------------------------------------------------------
-- the editing core (pure; every piece testable without a prompt)
---------------------------------------------------------------------------

local function is_word(b)
  local c = string.char(b)
  return c:match('[%w_]') ~= nil
end

--- Byte position of the start of the character that ends at `pos - 1`.
local function char_start(s, pos)
  local r = pos - 1
  while r > 1 and s:byte(r) >= 0x80 and s:byte(r) <= 0xbf do
    r = r - 1
  end
  return r
end

--- Byte position of the end of the character that starts at `pos`.
local function char_end(s, pos)
  local e = pos
  while e < #s and s:byte(e + 1) >= 0x80 and s:byte(e + 1) <= 0xbf do
    e = e + 1
  end
  return e
end

--- Cursor (insert position, 1-based bytes) of the start of the word
--- before `pos` — the M-b / M-BS motion. Exposed for tests.
---@param s string
---@param pos integer
---@return integer
function M.word_back(s, pos)
  local i = pos - 1
  while i >= 1 and not is_word(s:byte(i)) do
    i = i - 1
  end
  while i >= 1 and is_word(s:byte(i)) do
    i = i - 1
  end
  return i + 1
end

--- Cursor after the end of the word at/after `pos` — M-f. Exposed for
--- tests.
---@param s string
---@param pos integer
---@return integer
function M.word_fwd(s, pos)
  local i = pos
  while i <= #s and not is_word(s:byte(i)) do
    i = i + 1
  end
  while i <= #s and is_word(s:byte(i)) do
    i = i + 1
  end
  return i
end

--- The ghost echoes `text` could be: the history entries that
--- continue it (they start like it, case folded, and are longer),
--- newest first, deduplicated case-insensitively. Exposed for tests.
---@param text string
---@param history string[]
---@return string[]
function M.echoes(text, history)
  if text == '' then
    return {}
  end
  local out, seen = {}, {}
  for _, h in ipairs(history or {}) do
    if type(h) == 'string' and #h > #text
      and h:lower():sub(1, #text) == text:lower()
      and not seen[h:lower()] then
      seen[h:lower()] = true
      out[#out + 1] = h
    end
  end
  return out
end

--- The part of `entry` that goes after `text` — the ghost itself.
--- Exposed for tests.
---@param text string
---@param entry string
---@return string
function M.ghost_of(text, entry)
  return entry:sub(#text + 1)
end

--- `text` cut to `cells` display cells, `…` when it had to be cut.
--- Exposed for tests.
---@param text string
---@param cells integer
---@return string
function M.fit(text, cells)
  if vim.fn.strdisplaywidth(text) <= cells then
    return text
  end
  if cells <= 1 then
    return '…'
  end
  local out = ''
  for i = 1, vim.fn.strchars(text) do
    local c = vim.fn.strcharpart(text, i - 1, 1)
    if vim.fn.strdisplaywidth(out) + vim.fn.strdisplaywidth(c) > cells - 1 then
      break
    end
    out = out .. c
  end
  return out .. '…'
end

---------------------------------------------------------------------------
-- the ghost: a float on the cmdline's own row, after the line
---------------------------------------------------------------------------

local fwin, fbuf ---@type integer?, integer?

--- The echo state of the command line that is up, if one is: the
--- text, the echoes it could be, which one is showing and its ghost —
--- for tests and statuslines.
---@return { text: string, echoes: string[], idx: integer, ghost: string, type: string, prompt: string }?
function M.state()
  return M._state
end

local function close_float()
  if fwin and vim.api.nvim_win_is_valid(fwin) then
    vim.api.nvim_win_close(fwin, true)
  end
  fwin, fbuf = nil, nil
end

--- The history feeding the ghost of the command line that is up: the
--- `:` commands, the `/` and `?` searches, or the `@` answers
--- input() gave — newest first, empty for the prompts with no
--- history of their own.
local function history_of()
  local ty = vim.fn.getcmdtype()
  if ty == '/' or ty == '?' then
    ty = '/'
  elseif ty ~= ':' and ty ~= '@' then
    return {}
  end
  local out = {}
  local i = -1
  while #out < M.options.max_history do
    local h = vim.fn.histget(ty, i)
    if h == '' then
      break
    end
    out[#out + 1] = h
    i = i - 1
  end
  return out
end

--- The prompt whose width the text is drawn after — getcmdprompt()'s
--- (input()'s prompts carry theirs), the prompt char itself for the
--- Ex and search lines.
local function prompt_of(ty)
  local ok, prompt = pcall(vim.fn.getcmdprompt)
  if ok and prompt ~= '' then
    return prompt
  end
  if ty == ':' or ty == '/' or ty == '?' then
    return ty
  end
  return ''
end

--- How many cells the ruler may claim at the right of the cmdline's
--- row: it only shows there when the last window has no status line
--- of its own.
local function ruler_reserve()
  if vim.o.ruler and vim.o.laststatus < 2 then
    return 18
  end
  return 0
end

--- (Re)draw the ghost after the line: the echo C-p has walked to,
--- dimmed on the cmdline's own row, starting one cell past the line's
--- end — never while the wildmenu is up, and never over the ruler. The
--- ghost itself is computed here, synchronously (M.state() reads it);
--- the window work is scheduled — the mappings edit the line inside a
--- textlock that forbids changing text or windows, and the schedule
--- lands after it lifts, still before the row is seen.
local pending_paint = false
local function draw()
  if not M.options.ghost or not M._state then
    return
  end
  local st = M._state
  st.ghost = st.echoes[st.idx] and M.ghost_of(st.text, st.echoes[st.idx]) or ''
  if pending_paint then
    return
  end
  pending_paint = true
  vim.schedule(function()
    pending_paint = false
    if not (M._state and M.options.ghost) then
      return
    end
    local st = M._state
    if st.ghost == '' or vim.fn.wildmenumode() ~= 0 then
      close_float()
      return
    end
    -- where the line ends on screen: the cursor's own screen column
    -- plus whatever follows it — getcmdscreenpos()'s answer, which
    -- asks nothing of the prompt (and reads input()'s on every
    -- version getcmdprompt() does not). A line longer than the row
    -- scrolls, and there is no saying where — the ghost stays home
    -- then. Read here, in the schedule, off the state that is current
    -- when the paint lands.
    local col
    local ok, sp = pcall(vim.fn.getcmdscreenpos)
    if ok and type(sp) == 'number' and sp >= 1 then
      col = (sp - 1) + vim.fn.strdisplaywidth(st.text:sub(vim.fn.getcmdpos()))
    else
      col = vim.fn.strdisplaywidth(st.prompt) + vim.fn.strdisplaywidth(st.text)
    end
    local avail = vim.o.columns - col - ruler_reserve()
    if avail < 1 then
      close_float()
      return
    end
    local shown = M.fit(st.ghost, avail)
    local width = math.max(1, vim.fn.strdisplaywidth(shown))
    if not (fwin and vim.api.nvim_win_is_valid(fwin)) then
      fbuf = vim.api.nvim_create_buf(false, true)
      vim.bo[fbuf].buftype = 'nofile'
      vim.bo[fbuf].bufhidden = 'wipe'
      vim.bo[fbuf].swapfile = false
      fwin = vim.api.nvim_open_win(fbuf, false, {
        relative = 'editor',
        width = width,
        height = 1,
        row = math.max(0, vim.o.lines - 1),
        col = col,
        style = 'minimal',
        border = 'none',
        zindex = 400,
        focusable = false,
      })
      -- the row the ghost rides on is the message area's: its paper,
      -- and full background transparency where the terminal has it
      vim.wo[fwin].winblend = 100
      vim.wo[fwin].winhighlight = 'Normal:GliterCmdGhost'
      vim.wo[fwin].wrap = false
    else
      vim.api.nvim_win_set_config(fwin, {
        relative = 'editor',
        width = width,
        height = 1,
        row = math.max(0, vim.o.lines - 1),
        col = col,
      })
    end
    vim.api.nvim_buf_set_lines(fbuf, 0, -1, false, { shown })
    -- a float painted while the command line is up is not composited on
    -- its own — the line redraws the message grid only — so the flush is
    -- asked for by name (Neovim 0.10+; without it the ghost rides unseen,
    -- its keys still working)
    pcall(vim.api.nvim__redraw, { flush = true })
  end)
end

--- Recompute the echoes for the command line that is up (the text
--- changed, or the prompt just opened): the newest echo is the ghost.
local function recompute()
  local ok, text = pcall(vim.fn.getcmdline)
  local okt, ty = pcall(vim.fn.getcmdtype)
  if not (ok and okt) then
    return
  end
  M._state = {
    text = text,
    echoes = M.echoes(text, history_of()),
    idx = 1,
    ghost = '',
    type = ty,
    prompt = prompt_of(ty),
  }
  draw()
end

---------------------------------------------------------------------------
-- the keys: cnoremaps editing the line through setcmdline()
---------------------------------------------------------------------------

local function line()
  return vim.fn.getcmdline(), vim.fn.getcmdpos()
end

--- Set text and cursor in one go — c_CTRL-\_e's job, done directly.
--- Returns false when the line would not change.
local function put(text, pos)
  if text == vim.fn.getcmdline() and pos == vim.fn.getcmdpos() then
    return false
  end
  vim.fn.setcmdline(text, pos)
  return true
end

--- Take the ghost: the line becomes the echo it is showing, the
--- cursor at its end. Returns false when there is no echo to take.
local function take()
  local st = M._state
  if not (st and st.echoes[st.idx]) then
    return false
  end
  local entry = st.echoes[st.idx]
  vim.fn.setcmdline(entry, #entry + 1) -- CmdlineChanged recomputes
  return true
end

--- Forward a character — and at the end of the line, where there is
--- nothing left to move over, the ghost taken instead: fish's accept
--- (C-f's, Right's).
local function forward()
  local text, cur = line()
  if cur > #text then
    take()
    return
  end
  put(text, char_end(text, cur) + 1)
end

--- The line with the two characters at the cursor transposed — at
--- the end of the line the last two, the way readline drags them —
--- and where the cursor lands. nil when there are not two to swap.
local function transposed(t, cur)
  if cur > #t then
    local p = char_start(t, #t + 1) -- the last character
    local q = char_start(t, p) -- the one before it
    if p <= q then
      return nil
    end
    return t:sub(1, q - 1) .. t:sub(p) .. t:sub(q, p - 1), #t + 1
  end
  if cur < 2 then
    return nil
  end
  local a = char_start(t, cur) -- the character before the cursor
  local b = char_end(t, cur) -- the one at it
  return t:sub(1, a - 1) .. t:sub(cur, b) .. t:sub(a, cur - 1) .. t:sub(b + 1), b + 1
end

--- What a key does while the wildmenu is up: the menu's own keys go
--- to it — the single-byte ones handed back raw (an <expr> map's
--- result is read as keys, and one byte is a key), Right riding C-n's
--- next match (a mapping-bred Tab would type itself into the line:
--- 'wildcharm' lore), C-y its accept — and everything else sleeps,
--- handed back nothing: the menu stays, nothing happens.
---@param key string the key's notation, e.g. '<C-n>'
---@return string keys to hand back instead ('' to sleep)
local function menu_policy(key)
  if key == '<C-n>' or key == '<C-p>' or key == '<C-e>' or key == '<C-y>' or key == '<Right>' then
    return keycode(key == '<Right>' and '<C-n>' or key)
  end
  return ''
end

--- The readline editing keys, always on. `run` returns the keys to
--- hand back (usually none).
local edit_keys = {
  ['<C-a>'] = {
    desc = 'to the beginning of the line (Home)',
    run = function()
      local text = line()
      put(text, 1)
    end,
  },
  ['<C-e>'] = {
    desc = 'to the end of the line — at the end, the ghost taken',
    run = function()
      local text, cur = line()
      if not (cur > #text and take()) then
        put(text, #text + 1)
      end
    end,
  },
  ['<C-b>'] = {
    desc = 'back a character (Left)',
    run = function()
      local text, cur = line()
      if cur > 1 then
        put(text, char_start(text, cur))
      end
    end,
  },
  ['<C-f>'] = {
    desc = 'forward a character — at the end, the ghost taken',
    run = forward,
  },
  ['<C-d>'] = {
    desc = 'delete the character at the cursor (Del)',
    run = function()
      local text, cur = line()
      if cur <= #text then
        put(text:sub(1, cur - 1) .. text:sub(char_end(text, cur) + 1), cur)
      end
    end,
  },
  ['<C-k>'] = {
    desc = 'kill to the end of the line',
    run = function()
      local text, cur = line()
      if cur <= #text then
        put(text:sub(1, cur - 1), cur)
      end
    end,
  },
  ['<C-t>'] = {
    desc = 'transpose the characters at the cursor',
    run = function()
      local text, cur = line()
      local swapped, pos = transposed(text, cur)
      if swapped then
        put(swapped, pos)
      end
    end,
  },
  ['<M-b>'] = {
    desc = 'back a word (S-Left)',
    run = function()
      local text, cur = line()
      put(text, M.word_back(text, cur))
    end,
  },
  ['<M-f>'] = {
    desc = 'forward a word (S-Right)',
    run = function()
      local text, cur = line()
      put(text, M.word_fwd(text, cur))
    end,
  },
  ['<M-BS>'] = {
    desc = 'kill the word before the cursor',
    run = function()
      local text, cur = line()
      local s = M.word_back(text, cur)
      if s < cur then
        put(text:sub(1, s - 1) .. text:sub(cur), s)
      end
    end,
  },
  ['<M-d>'] = {
    desc = 'kill the word after the cursor',
    run = function()
      local text, cur = line()
      local e = M.word_fwd(text, cur)
      if e > cur then
        put(text:sub(1, cur - 1) .. text:sub(e + 1), cur)
      end
    end,
  },
}

--- The ghost's keys, on only when the ghost is. `run` returns the
--- keys to hand back for the built-in key to act instead.
local ghost_keys = {
  ['<Right>'] = {
    desc = 'forward a character — at the end, the ghost taken',
    run = forward,
  },
  ['<C-n>'] = {
    desc = 'the echoes back the other way, one newer at a time; at the newest, the ghost taken; without one, the newer history (the built-in key)',
    run = function()
      local st = M._state
      if st and st.idx > 1 then
        st.idx = st.idx - 1
        draw() -- the text did not change: no CmdlineChanged will come
        return
      end
      if not take() then
        return keycode('<C-n>')
      end
    end,
  },
  ['<C-p>'] = {
    desc = 'the ghost echoes, one older at a time; without one, the older history (the built-in key)',
    run = function()
      local st = M._state
      if not (st and st.idx <= #st.echoes) then
        return keycode('<C-p>')
      end
      st.idx = st.idx + 1
      draw() -- the text did not change: no CmdlineChanged will come
    end,
  },
  ['<C-y>'] = {
    desc = 'take the echo the ghost is showing — the line becomes it',
    run = function()
      take() -- nothing to take: the key does nothing (no built-in job worth keeping)
    end,
  },
  ['<M-l>'] = {
    desc = 'take the echo the ghost is showing — the line becomes it',
    run = function()
      take()
    end,
  },
}

---------------------------------------------------------------------------
-- setup
---------------------------------------------------------------------------

--- GliterCmdGhost: Comment's ink on MsgArea's paper — the ghost is
--- drawn on the message area's row, and must not paint a window of
--- its own color over it. A plain link to Comment when the colors
--- cannot be read (winblend does the transparency where it can).
local function define_hl()
  local bg = vim.fn.synIDattr(vim.fn.hlID('MsgArea'), 'bg#')
  local fg = vim.fn.synIDattr(vim.fn.hlID('Comment'), 'fg#')
  if bg ~= '' and fg ~= '' then
    vim.api.nvim_set_hl(0, 'GliterCmdGhost', { default = true, fg = fg, bg = bg })
  else
    vim.api.nvim_set_hl(0, 'GliterCmdGhost', { default = true, link = 'Comment' })
  end
end

local function install(key, def)
  vim.keymap.set('c', key, function()
    if vim.fn.wildmenumode() ~= 0 then
      return menu_policy(key)
    end
    local ok, res = pcall(def.run)
    if not ok then
      vim.api.nvim_err_writeln('gliter.cmd: ' .. res)
      return ''
    end
    return res or ''
  end, { expr = true, desc = 'gliter.cmd: ' .. def.desc })
end

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})

  define_hl()
  vim.api.nvim_create_augroup('GliterCmd', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = 'GliterCmd',
    callback = define_hl,
  })

  for k, def in pairs(edit_keys) do
    install(k, def)
  end
  if M.options.ghost then
    for k, def in pairs(ghost_keys) do
      install(k, def)
    end
    vim.api.nvim_create_autocmd({ 'CmdlineEnter', 'CmdlineChanged' }, {
      group = 'GliterCmd',
      callback = function(ev)
        local ok, text = pcall(vim.fn.getcmdline)
        if ev.event == 'CmdlineEnter' or not (ok and M._state and M._state.text == text) then
          recompute()
        else
          draw() -- a cursor move: the ghost stays where it was
        end
      end,
    })
    vim.api.nvim_create_autocmd({ 'CmdlineLeave', 'VimResized' }, {
      group = 'GliterCmd',
      callback = function()
        M._state = nil
        pcall(close_float)
      end,
    })
  end

  return M
end

return M
