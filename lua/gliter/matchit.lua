--- gliter.matchit — `%` for keywords: the key you gave the matchit job (M
--- by default) jumps between the words that bracket a block — `if` and
--- `end`, `function` and `endfunction`, `<div>` and `</div>` — with the
--- nesting counted, exactly the way `%` counts brackets. gM (g%'s job)
--- walks the other way. On a word that is none of them the key falls back
--- to plain `%`: brackets, and everything `'matchpairs'` holds.
---
--- The chains, per filetype, are three Vim regexes — openers (`if`, `for`,
--- `function`, ...), closers (`end`, `endif`, `fi`, ...), middles
--- (`else`, `elseif`, `catch`, ...) — and the walk is the bracket walk:
---   M   on an opener or a middle  → its matching closer, nesting counted
---       on a closer              → its matching opener
---   gM  on a closer or a middle  → its matching opener
---       on an opener             → its matching closer
--- so the two keys differ only on the middle words: on `else`, M goes to
--- the end of the block and gM back to its start. In Visual mode the
--- selection extends to the match; after an operator (`dM`, `cM`) the
--- whole match word is included, the way `d%` includes both brackets.
--- A count keeps Vim's own `[count]%` (go to N% of the file).
---
--- matchit.vim (Benji Fisher, from Raul Segura Acevedo's 1996 script) is
--- the reference and does more: backreferences, comment skipping, `%`
--- from anywhere on the line, `[%`/`]%`/`i%`. gliter.matchit is the walk
--- and nothing more; for the rest, `:packadd matchit` or vim-matchup.
local M = {}

M.did_setup = false

--- The built-in chains. Each entry: `opens` / `middles` / `closes` —
--- three Vim regexes. Override or extend through `setup { words = ... }`
--- (a per-filetype table merged over this one; the filetype name is the
--- key, `vim.bo.filetype` verbatim).
M.builtin_words = {
  lua = {
    opens = [[\<\%(if\|for\|while\|do\|function\|repeat\)\>]],
    middles = [[\<\%(elseif\|else\)\>]],
    closes = [[\<\%(end\|until\)\>]],
  },
  vim = {
    opens = [[\<\%(fu\%[nction]\|def\|if\|for\|wh\%[ile]\|try\)\>]],
    middles = [[\<\%(elsei\%[f]\|else\|cat\%[ch]\|final\%[ly]\)\>]],
    closes = [[\<\%(endf\%[unction]\|enddef\|endif\|endfo\%[r]\|endw\%[hile]\|endt\%[ry]\)\>]],
  },
  sh = {
    opens = [[\<\%(if\|for\|while\|until\|case\|select\)\>]],
    middles = [[\<\%(then\|do\|else\|elif\)\>]],
    closes = [[\<\%(fi\|done\|esac\)\>]],
  },
  zsh = {
    opens = [[\<\%(if\|for\|while\|until\|case\|select\)\>]],
    middles = [[\<\%(then\|do\|else\|elif\)\>]],
    closes = [[\<\%(fi\|done\|esac\)\>]],
  },
  c = {
    opens = [[^#\s*if\%(n\=def\)\=\>\|/\*]],
    middles = [[^#\s*el\%(se\|if\%(n\=def\)\=\)\>]],
    closes = [[^#\s*endif\>\|\*/]],
  },
  cpp = {
    opens = [[^#\s*if\%(n\=def\)\=\>\|/\*]],
    middles = [[^#\s*el\%(se\|if\%(n\=def\)\=\)\>]],
    closes = [[^#\s*endif\>\|\*/]],
  },
}

M.defaults = {
  keys = {
    match = 'M', -- n/x/o: jump to the matching word — keyword chains when
                 -- the cursor is on one, plain % otherwise
    back = 'gM', -- n/x/o: the same walk, the other way (differs only on
                 -- the middle words: else/elseif/catch)
  },
  words = {}, -- your chains, merged over the built-ins:
              -- { ruby = { opens = ..., middles = ..., closes = ... } }
  tags = { 'html', 'xhtml', 'xml' }, -- filetypes where <tag> ↔ </tag>
                                     -- matching is on
}

M.options = vim.deepcopy(M.defaults)
M.words = {}

---------------------------------------------------------------------------
-- the member under the cursor
---------------------------------------------------------------------------

--- Compile and cache the three patterns of `ft`, plus the union pattern
--- (as source, for match()/search(), which want strings).
---@param ft string
---@return { opens: vim.regex, middles: vim.regex?, closes: vim.regex, union_source: string }?
local compiled = {}
local function patterns(ft)
  local w = M.words[ft]
  if not w then
    return nil
  end
  if compiled[ft] == nil then
    local parts = {}
    for _, k in ipairs({ 'opens', 'middles', 'closes' }) do
      if w[k] and w[k] ~= '' then
        parts[#parts + 1] = '\\%(' .. w[k] .. '\\)'
      end
    end
    if #parts == 0 then
      compiled[ft] = false
    else
      local out, ok = {}, true
      for _, k in ipairs({ 'opens', 'middles', 'closes' }) do
        if w[k] and w[k] ~= '' then
          local o, re = pcall(vim.regex, '\\C' .. w[k])
          ok = ok and o
          out[k] = o and re or nil
        end
      end
      out.union_source = '\\C' .. table.concat(parts, '\\|')
      compiled[ft] = ok and out or false
    end
  end
  return compiled[ft] or nil
end

--- The keyword member covering the cursor on the current line, if any.
--- Returns its class ('open' | 'middle' | 'close'), the member text, and
--- its 0-based byte span on the line. Exposed for tests.
---@param pat { opens: vim.regex, middles: vim.regex?, closes: vim.regex, union_source: string }
---@return { kind: string, text: string, s: integer, e: integer }?
function M.keyword_at(pat)
  local line = vim.fn.getline('.')
  local col = vim.fn.col('.') -- 1-based
  local pos = 0
  while true do
    local s = vim.fn.match(line, pat.union_source, pos)
    if s < 0 then
      return nil
    end
    local e = vim.fn.matchend(line, pat.union_source, pos)
    -- covering: starts at or before the cursor, ends after it
    if s <= col - 1 and e >= col then
      local text = line:sub(s + 1, e)
      local kind = nil
      if pat.opens:match_str(text) then
        kind = 'open'
      end
      if pat.middles and pat.middles:match_str(text) then
        kind = 'middle'
      end
      if pat.closes:match_str(text) then
        kind = 'close'
      end
      if kind then
        return { kind = kind, text = text, s = s, e = e }
      end
    end
    pos = s + 1
  end
end

---------------------------------------------------------------------------
-- the walk
---------------------------------------------------------------------------

local MAX_STEPS = 10000

--- Step through the union matches, counting nesting, to the target member.
--- `dir` is 1 (forward, to the closer) or -1 (backward, to the opener);
--- the cursor must sit on the start of the current member. `middle_stops`
--- (the gM-on-an-opener case) makes a middle word at the same level a
--- target too — the previous member of the chain, g%'s walk. Returns
--- true when the cursor was moved to the target, false when the file
--- never balances (the cursor is restored then).
---@param pat table
---@param dir integer
---@param middle_stops? boolean
---@return boolean moved
local function walk(pat, dir, middle_stops)
  local view = vim.fn.winsaveview()
  local depth = 0
  for _ = 1, MAX_STEPS do
    local found = vim.fn.search(pat.union_source, dir > 0 and 'W' or 'bW')
    if found == 0 then
      vim.fn.winrestview(view)
      return false
    end
    local line = vim.fn.getline('.')
    local col = vim.fn.col('.')
    local e = vim.fn.matchend(line, pat.union_source, col - 1)
    if e < 0 then
      vim.fn.winrestview(view)
      return false
    end
    local text = line:sub(col, e)
    if pat.middles and pat.middles:match_str(text) then
      if middle_stops and depth == 0 then
        return true
      end
      -- middles never nest and never stop the walk
    elseif pat.closes:match_str(text) then
      if dir > 0 then
        if depth == 0 then
          return true
        end
        depth = depth - 1
      else
        depth = depth - 1
      end
    elseif pat.opens:match_str(text) then
      if dir < 0 then
        if depth == 0 then
          return true
        end
        depth = depth + 1
      else
        depth = depth + 1
      end
    end
  end
  vim.fn.winrestview(view)
  return false
end

---------------------------------------------------------------------------
-- tags: <div> ↔ </div>, same-name nesting counted, self-closing skipped
---------------------------------------------------------------------------

--- The tag covering the cursor on the current line: name, whether it
--- closes, whether it is self-closing, and its 0-based byte span.
---@return { name: string, closing: boolean, selfclosing: boolean, s: integer, e: integer }?
local function tag_at()
  local line = vim.fn.getline('.')
  local col = vim.fn.col('.') - 1
  local pos = 0
  while true do
    local s = vim.fn.match(line, '<[^>]*>', pos)
    if s < 0 then
      return nil
    end
    local e = vim.fn.matchend(line, '<[^>]*>', pos)
    if s <= col and col < e then
      local text = line:sub(s + 1, e)
      local closing = text:match('^<%s*/')
      local selfclosing = text:match('/>%s*$') ~= nil
      local name = text:match('^<%s*/%s*([%w%.%-:]+)') or text:match('^<%s*([%w%.%-:]+)')
      if name then
        return { name = name, closing = closing ~= nil, selfclosing = selfclosing, s = s, e = e }
      end
    end
    pos = s + 1
  end
end

--- The union pattern that matches both edges of a `name` tag.
---@param name string
---@return string
local function tag_union(name)
  local esc = name:gsub('[\\%[%]^$~*.]', '\\%1')
  return '\\%(</\\|<\\)' .. esc .. '[^>]*>'
end

--- Walk tags of the same name; `dir` as in `walk`. Returns true on a move.
---@param name string
---@param dir integer
---@return boolean moved
local function walk_tags(name, dir)
  local union = tag_union(name)
  local view = vim.fn.winsaveview()
  local depth = 0
  for _ = 1, MAX_STEPS do
    if vim.fn.search(union, dir > 0 and 'W' or 'bW') == 0 then
      vim.fn.winrestview(view)
      return false
    end
    local line = vim.fn.getline('.')
    local col = vim.fn.col('.')
    local e = vim.fn.matchend(line, union, col - 1)
    if e < 0 then
      vim.fn.winrestview(view)
      return false
    end
    local text = line:sub(col, e)
    local closing = text:match('^<%s*/')
    local selfclosing = text:match('/>%s*$') ~= nil
    if selfclosing then
      -- counts for nothing, in either direction
    elseif closing then
      if dir > 0 and depth == 0 then
        return true
      end
      depth = depth - 1
    else
      if dir < 0 and depth == 0 then
        return true
      end
      depth = depth + 1
    end
  end
  vim.fn.winrestview(view)
  return false
end

---------------------------------------------------------------------------
-- the mapping bodies
---------------------------------------------------------------------------

--- Plain `%` — the built-in, unremapped, count and all. What runs when the
--- cursor is on no keyword and no tag.
local function native_percent()
  local count = vim.v.count > 0 and vim.v.count or ''
  local mode = vim.fn.mode():sub(1, 1)
  if mode == 'v' or mode == 'V' or vim.fn.mode() == '\22' then
    vim.api.nvim_feedkeys(count .. '%', 'nx', false)
  else
    vim.cmd('normal! ' .. count .. '%')
  end
end

--- The shared body of M / gM, exposed for tests. `dir`: 1 = towards the
--- closer, -1 = towards the opener. `omode`: truthy when running as an
--- operator-pending mapping (dM, cM, ...) — the mapping passes it
--- explicitly, because mode() is not reliable inside a mapping callback.
---@param dir integer
---@param omode? boolean
function M.jump(dir, omode)
  if vim.v.count > 0 then -- [count]% is Vim's own: go to N% of the file
    native_percent()
    return
  end
  local ft = vim.bo.filetype
  local pat = patterns(ft)
  local member, is_tag

  if vim.tbl_contains(M.options.tags, ft) then
    member = tag_at()
    is_tag = true
  end
  if not member and pat then
    member = M.keyword_at(pat)
    is_tag = false
  end
  if not member then
    return native_percent()
  end

  -- where the walk goes
  local towards
  if is_tag then
    towards = member.closing and -1 or 1
  else
    towards = member.kind == 'close' and -1 or dir
  end

  local op = omode == true -- operator-pending: dM, cM, ...
  if op then
    -- select the match, whole word included when the walk runs forward —
    -- dM deletes what d% would, keyword edition. The o-mode mapping is an
    -- Ex-command mapping (see setup), the one form whose end-of-mapping
    -- Visual state the operator takes over.
    vim.cmd('normal! v')
  end

  local view = vim.fn.winsaveview()
  local moved
  -- the walk starts at the member's first byte (col is 0-based, and so is
  -- the member's `s`)
  vim.api.nvim_win_set_cursor(0, { vim.fn.line('.'), member.s })
  if is_tag then
    moved = walk_tags(member.name, towards)
    if moved and op and towards > 0 then
      local e = vim.fn.matchend(vim.fn.getline('.'), tag_union(member.name), vim.fn.col('.') - 1)
      if e > vim.fn.col('.') then
        vim.api.nvim_win_set_cursor(0, { vim.fn.line('.'), e - 1 }) -- the tag's last byte
      end
    end
  else
    -- gM on an opener: the previous member of the chain at this level —
    -- an elseif/else before it, a sibling's closer, the enclosing opener
    moved = walk(pat, towards, member.kind == 'open' and towards < 0)
    if moved and op and towards > 0 then
      local e = vim.fn.matchend(vim.fn.getline('.'), pat.union_source, vim.fn.col('.') - 1)
      if e > vim.fn.col('.') then
        vim.api.nvim_win_set_cursor(0, { vim.fn.line('.'), e - 1 }) -- the word's last byte
      end
    end
  end
  if not moved then
    if op then
      -- nothing matched: leave Visual and put the cursor back on the
      -- operator's start — the empty region makes the operator a no-op
      vim.cmd('normal! ' .. vim.keycode('<Esc>'))
    end
    vim.fn.winrestview(view)
  end
end

---------------------------------------------------------------------------
-- setup
---------------------------------------------------------------------------

function M.setup(opts)
  M.did_setup = true
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  M.words = vim.tbl_deep_extend('force', vim.deepcopy(M.builtin_words), M.options.words or {})
  compiled = {}

  local keys = M.options.keys
  if keys and keys.match then
    vim.keymap.set({ 'n', 'x' }, keys.match, function()
      M.jump(1)
    end, { silent = true, desc = 'gliter.matchit: jump to the matching keyword / tag / bracket' })
    -- o-mode as an Ex-command mapping: when the command ends Vim is (still)
    -- in Visual mode, and the pending operator takes the selection over —
    -- the one mapping form for which Vim does that
    vim.keymap.set('o', keys.match, ':<C-U>lua require("gliter.matchit").jump(1, true)<CR>', {
      silent = true,
      desc = 'gliter.matchit: the matching keyword / tag / bracket, for operators (dM, cM)',
    })
  end
  if keys and keys.back then
    vim.keymap.set({ 'n', 'x' }, keys.back, function()
      M.jump(-1)
    end, { silent = true, desc = 'gliter.matchit: the same walk, the other way' })
    vim.keymap.set('o', keys.back, ':<C-U>lua require("gliter.matchit").jump(-1, true)<CR>', {
      silent = true,
      desc = 'gliter.matchit: the other way, for operators',
    })
  end
  return M
end

return M
