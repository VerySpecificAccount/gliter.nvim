--- gliter.undotree — extra features for the built-in :Undotree viewer
--- (the `nvim.undotree` dist plugin, Neovim 0.12+).
---
--- WHAT IT DOES
---   * Loads the viewer itself (:packadd nvim.undotree) and maps a toggle
---     key (default <Leader>u): open the tree, press it again to close it —
---     from the tree window, the edited buffer or the diff panel alike.
---     (The built-in open() only closes when the current buffer is the
---     edited buffer or the tree itself; from the diff panel it opens a
---     SECOND tree window.)
---   * Re-colors the built-in tree with the classic undo-tree palette:
---
---         |  /  \  connectors   ->  UndotreeBranch      (Constant)
---         *  node glyph         ->  UndotreeNode        (Question)
---         *  current node       ->  UndotreeNodeCurrent (Statement)
---         seq number            ->  UndotreeSeq         (Comment)
---         seq of current state  ->  UndotreeCurrent     (Statement)
---         (time stamp)          ->  UndotreeTimeStamp   (Function)
---
---     All groups use `default = true` links, so `:hi UndotreeNode ...`
---     overrides still work.
---
---   * Shows the diff of each undo step in ONE window at the bottom of the
---     screen, full width: a "- seq: X -" / "+ seq: Y +" header followed by
---     a unified diff between the state you came from and the state under
---     the cursor, colored via `filetype=diff`, plus ++/~~/--/-v signs and
---     DiffAdd/DiffChange line highlights in the edited buffer. If regex
---     syntax is disabled (`:syntax off`, -u NONE), window-local
---     DiffAdd/DiffDelete/... matches color the panel instead.
---     The panel auto-opens when the nvim.difftool module is loaded
---     (difftool = true loads it for you); press `D` in the tree to
---     toggle it manually at any time.
---
--- USAGE (init.lua)
---   require('gliter.undotree').setup()
---
---   require('gliter.undotree').setup {
---     toggle = '<Leader>u', -- open/close key; false = no mapping
---     difftool = true,     -- also :packadd nvim.difftool ('auto' panel)
---     diff_panel = 'auto', -- 'auto' | true | false
---     panel_height = 10,   -- height of the bottom diff window
---   }

local M = {}

M.did_setup = false

if vim.fn.has('nvim-0.12') == 0 then
  function M.setup()
    vim.notify('[gliter] undotree needs Neovim 0.12+ (built-in :Undotree viewer)', vim.log.levels.WARN)
  end
  return M
end

-- Namespace of the built-in viewer (runtime/pack/dist/opt/nvim.undotree).
-- We deliberately reuse it: recolored connector lines are written back into
-- the viewer's own extmarks (same ids), so its clear/redraw lifecycle stays
-- the single source of truth.
local NS = vim.api.nvim_create_namespace('nvim.undotree')
local SIGN_GROUP = 'gliter-undotree'

-- state per open tree: S[tree_buf] = {...}
local S = {}

------------------------------------------------------------------------ utils

-- Neovim 0.12 renamed vim.diff() -> vim.text.diff() and the option
-- 'output' -> 'result_type'; support both spellings. ctxlen=3 mirrors the
-- plain `diff` command defaults, which show 3 context lines.
local function run_diff(a, b, result_type)
  local o = { result_type = result_type }
  if result_type == 'unified' then
    o.ctxlen = 3
  end
  if vim.text and vim.text.diff then
    return vim.text.diff(a, b, o)
  end
  o.output = o.result_type
  o.result_type = nil
  return vim.diff(a, b, o)
end

local function is_branch_char(c)
  return c == '|' or c == '/' or c == '\\'
end

local function chunk_text(c)
  if type(c) == 'string' then
    return c
  end
  if type(c) == 'table' then
    return c[1] or c.text or ''
  end
  return ''
end

--- Seq number of a rendered node line such as "| * |    12    (3 seconds ago)".
local function seq_of_line(line)
  if not line then
    return nil
  end
  return tonumber(line:match('%*[%s|]*(%d+)'))
end

-------------------------------------------------------------- highlight setup

-- Defaults of the classic palette; `hi def link` semantics, so any
-- pre-existing `:hi Undotree*` overrides keep working. UndotreeNext/Head/
-- Help*/Saved* are kept for parity with the classic group set even though
-- the built-in view has no markers for them ({num}, [num], "s"/"S", help
-- lines).
local function define_highlights()
  local links = {
    UndotreeNode = 'Question',
    UndotreeNodeCurrent = 'Statement',
    UndotreeTimeStamp = 'Function',
    UndotreeFirstNode = 'Function',
    UndotreeBranch = 'Constant',
    UndotreeSeq = 'Comment',
    UndotreeCurrent = 'Statement',
    UndotreeNext = 'Type',
    UndotreeHead = 'Identifier',
    UndotreeHelp = 'Comment',
    UndotreeHelpKey = 'Function',
    UndotreeHelpTitle = 'Type',
    UndotreeSavedSmall = 'WarningMsg',
    UndotreeSavedBig = 'MatchParen',
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

-- Classic diff signs for the edited buffer.
local function define_signs()
  vim.fn.sign_define('UndotreeAdd', { text = '++', texthl = 'DiffAdd' })
  vim.fn.sign_define('UndotreeChg', { text = '~~', texthl = 'DiffChange' })
  vim.fn.sign_define('UndotreeDel', { text = '--', texthl = 'DiffDelete' })
  vim.fn.sign_define('UndotreeDelEnd', { text = '-v', texthl = 'DiffDelete' })
end

------------------------------------------------------- coloring of the tree

-- Window-local matches on the tree window. They are live regexes, so they
-- survive the viewer's re-renders without any extra work, and they take
-- precedence over the viewer's `syntax region Comment start="(" end=")"`.
local function decorate_static(st)
  if not vim.api.nvim_win_is_valid(st.win) then
    return
  end
  pcall(vim.fn.clearmatches, st.win)
  pcall(vim.api.nvim_win_call, st.win, function()
    -- | / \ connectors (constant), also those inside node lines
    vim.fn.matchadd('UndotreeBranch', '[|/\\\\]', 10)
    -- "*" node glyph (space- or line-start delimited)
    vim.fn.matchadd('UndotreeNode', '\\(^\\| \\)\\zs\\*', 10)
    -- sequence number
    vim.fn.matchadd('UndotreeSeq', ' \\zs\\d\\+\\ze ', 10)
    -- "(...)" time stamp, higher priority so date "/" stays Function-colored
    vim.fn.matchadd('UndotreeTimeStamp', '(.*)$', 20)
  end)
end

-- Highlight the current state's node glyph + seq number (the current line's
-- "*" and its number get the "current" colors).
local function refresh_current(st)
  if not (vim.api.nvim_win_is_valid(st.win) and vim.api.nvim_buf_is_valid(st.buf)) then
    return
  end
  for _, id in ipairs(st.cur_matches or {}) do
    pcall(vim.fn.matchdelete, id, st.win)
  end
  st.cur_matches = {}

  local cur
  if vim.api.nvim_buf_is_valid(st.src) then
    pcall(function()
      cur = vim.fn.undotree(st.src).seq_cur
    end)
  end
  if not cur then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)
  for i, l in ipairs(lines) do
    if seq_of_line(l) == cur then
      -- " \zs<num>\ze  (" -- anchor on the opening paren of the time stamp
      -- so numbers inside "(5 minutes ago)" are not caught on this line
      local pat_node = ('\\%%%dl\\(^\\| \\)\\zs\\*'):format(i)
      local pat_seq = ('\\%%%dl \\zs\\d\\+\\ze \\+('):format(i)
      pcall(vim.api.nvim_win_call, st.win, function()
        local a = vim.fn.matchadd('UndotreeNodeCurrent', pat_node, 30)
        local b = vim.fn.matchadd('UndotreeCurrent', pat_seq, 30)
        if a and a > 0 then
          st.cur_matches[#st.cur_matches + 1] = a
        end
        if b and b > 0 then
          st.cur_matches[#st.cur_matches + 1] = b
        end
      end)
      break
    end
  end
end

-- Connector-only lines (" | ", "|\", " /") are extmark virt_lines rendered
-- with a plain 'Normal' chunk by the viewer. matchadd() cannot reach virtual
-- text, so rewrite the viewer's own extmarks in place, splitting each line
-- into branch-colored chunks.
local function color_virt_line(text)
  local chunks = {}
  local i, n = 1, #text
  while i <= n do
    local branch = is_branch_char(text:sub(i, i))
    local j = i
    while j < n and is_branch_char(text:sub(j + 1, j + 1)) == branch do
      j = j + 1
    end
    chunks[#chunks + 1] = { text:sub(i, j), branch and 'UndotreeBranch' or 'Normal' }
    i = j + 1
  end
  if #chunks == 0 then
    chunks[1] = { '', 'Normal' }
  end
  return chunks
end

local function color_connectors(tree_buf)
  if not vim.api.nvim_buf_is_valid(tree_buf) then
    return
  end
  local marks = vim.api.nvim_buf_get_extmarks(tree_buf, NS, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    local id, row, col = m[1], m[2], m[3]
    local vls = (m[4] or {}).virt_lines
    if vls then
      local new_vls = {}
      for k, vl in ipairs(vls) do
        local text = ''
        for _, c in ipairs(vl) do
          text = text .. chunk_text(c)
        end
        new_vls[k] = color_virt_line(text)
      end
      pcall(vim.api.nvim_buf_set_extmark, tree_buf, NS, row, col, {
        id = id,
        virt_lines = new_vls,
      })
    end
  end
end

------------------------------------------------------------- diff panel

local function panel_hide(st)
  if not st.panel then
    return
  end
  if vim.api.nvim_win_is_valid(st.panel.win) then
    pcall(vim.api.nvim_win_close, st.panel.win, true)
  end
  st.panel = nil

  -- drop signs + changed-text highlights from the edited buffer
  if st.src and vim.api.nvim_buf_is_valid(st.src) then
    pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = st.src })
  end
  if st.src_win and vim.api.nvim_win_is_valid(st.src_win) then
    for _, id in ipairs(st.matches or {}) do
      pcall(vim.fn.matchdelete, id, st.src_win)
    end
  end
  st.matches = {}
end

-- One diff window per tree, full width, at the very bottom of the screen.
local function panel_create(st)
  if st.panel and vim.api.nvim_win_is_valid(st.panel.win) then
    return
  end
  if not vim.api.nvim_win_is_valid(st.win) then
    return
  end

  local height = math.max(3, math.floor(tonumber(st.opts.panel_height) or 10))

  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[pbuf].buftype = 'nofile'
  vim.bo[pbuf].bufhidden = 'wipe'
  vim.bo[pbuf].swapfile = false
  vim.bo[pbuf].buflisted = false
  pcall(vim.api.nvim_buf_set_name, pbuf, ('gliter-undotree-diff:%d'):format(st.buf))

  -- Open below the tree first, then move the window to the very bottom of
  -- the screen at full width (the `:botright` position). enter=false plus
  -- nvim_win_call() keep the focus in the tree.
  local ok, pwin = pcall(vim.api.nvim_open_win, pbuf, false, {
    split = 'below',
    height = height,
    win = st.win,
  })
  if not ok or not pwin then
    pcall(vim.api.nvim_buf_delete, pbuf, { force = true })
    return
  end
  pcall(vim.api.nvim_win_call, pwin, function()
    vim.cmd('wincmd J')
  end)
  -- the move may round the height; pin it exactly
  pcall(vim.api.nvim_win_set_height, pwin, height)

  vim.wo[pwin].winfixheight = true
  vim.wo[pwin].number = false
  vim.wo[pwin].relativenumber = false
  vim.wo[pwin].cursorline = false
  vim.wo[pwin].signcolumn = 'no'
  vim.wo[pwin].wrap = false
  vim.wo[pwin].list = false
  vim.wo[pwin].spell = false
  vim.wo[pwin].foldenable = false
  vim.wo[pwin].foldcolumn = '0'
  st.panel = { win = pwin, buf = pbuf }

  -- filetype=diff loads syntax/diff.vim: "+" -> DiffAdd, "-" -> DiffDelete,
  -- "@@" -> Identifier, "---/+++" -> Type. Without it the whole panel is
  -- plain, uncolored text.
  pcall(function()
    vim.bo[pbuf].filetype = 'diff'
  end)

  -- Fallback for configs with regex syntax off (`:syntax off`, -u NONE,
  -- treesitter-only setups): syntax/diff.vim never loads, so color the
  -- panel with window-local matches on the standard Diff* groups (which
  -- always exist, unlike the lowercase diffAdded & co). The matches die
  -- with the window, so nothing needs cleaning up.
  local ok, cur_syn = pcall(function()
    return vim.b[pbuf].current_syntax
  end)
  if not (ok and cur_syn == 'diff') then
    pcall(vim.api.nvim_win_call, pwin, function()
      vim.fn.matchadd('DiffAdd', '^+', 10)
      vim.fn.matchadd('DiffDelete', '^-', 10)
      vim.fn.matchadd('DiffChange', '^!', 10)
      vim.fn.matchadd('Identifier', '^@@', 11)
      vim.fn.matchadd('Type', [[\v^(\+\+\+|---|diff\ )]], 12)
    end)
  end
end

-- Signs in the sign column + whole-line highlights in the edited buffer.
local function mark_changes(st, hunks)
  if st.src_win and vim.api.nvim_win_is_valid(st.src_win) then
    for _, id in ipairs(st.matches or {}) do
      pcall(vim.fn.matchdelete, id, st.src_win)
    end
  end
  st.matches = {}
  if not vim.api.nvim_buf_is_valid(st.src) then
    return
  end
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = st.src })

  -- refresh the window showing the target buffer (it may have changed)
  local sw = vim.fn.bufwinid(st.src)
  st.src_win = (sw and sw > 0) and sw or nil

  local last = vim.api.nvim_buf_line_count(st.src)
  local add_lines, chg_lines = {}, {}

  for _, h in ipairs(hunks) do
    local a_start, a_count, b_start, b_count = h[1], h[2], h[3], h[4]
    if a_count == 0 then -- pure addition
      for l = b_start, b_start + b_count - 1 do
        add_lines[#add_lines + 1] = l
      end
    elseif b_count == 0 then -- pure deletion: sign only (text is gone)
      local l = math.max(1, math.min(a_start, last))
      local name = (a_start > last) and 'UndotreeDelEnd' or 'UndotreeDel'
      pcall(vim.fn.sign_place, 0, SIGN_GROUP, name, st.src, { lnum = l })
    else -- change
      for l = b_start, b_start + b_count - 1 do
        chg_lines[#chg_lines + 1] = l
      end
    end
  end

  for _, l in ipairs(add_lines) do
    pcall(vim.fn.sign_place, 0, SIGN_GROUP, 'UndotreeAdd', st.src, {
      lnum = math.max(1, math.min(l, last)),
    })
  end
  for _, l in ipairs(chg_lines) do
    pcall(vim.fn.sign_place, 0, SIGN_GROUP, 'UndotreeChg', st.src, {
      lnum = math.max(1, math.min(l, last)),
    })
  end

  local function place(group, lines)
    for i = 1, #lines, 8 do -- matchaddpos accepts at most 8 positions
      local chunk = {}
      for j = i, math.min(i + 7, #lines) do
        chunk[#chunk + 1] = lines[j]
      end
      if st.src_win and vim.api.nvim_win_is_valid(st.src_win) then
        pcall(vim.api.nvim_win_call, st.src_win, function()
          local id = vim.fn.matchaddpos(group, chunk)
          if id and id > 0 then
            st.matches[#st.matches + 1] = id
          end
        end)
      end
    end
  end
  place('DiffAdd', add_lines)
  place('DiffChange', chg_lines)
end

-- Diff old state (a_seq) vs new state (b_seq). The buffer is currently at
-- b_seq; a_seq's content is fetched by hopping states with :earlier/:later
-- under eventignore=all, then hopping right back.
local function diff_update(st, a_seq, b_seq)
  if not (st.panel and vim.api.nvim_win_is_valid(st.panel.win)) then
    return
  end
  if not vim.api.nvim_buf_is_valid(st.src) then
    return
  end
  local src = st.src

  local new_lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
  local old_lines = new_lines

  if a_seq ~= b_seq then
    local dist = b_seq - a_seq
    local back, fwd = 'earlier', 'later'
    if dist < 0 then
      back, fwd = 'later', 'earlier'
      dist = -dist
    end

    local ei = vim.o.eventignore
    vim.o.eventignore = 'all'

    local view
    local sw = vim.fn.bufwinid(src)
    if sw and sw > 0 then
      pcall(vim.api.nvim_win_call, sw, function()
        view = vim.fn.winsaveview()
      end)
    end

    pcall(function()
      vim.api.nvim_buf_call(src, function()
        vim.cmd(('silent %s %d'):format(back, dist))
      end)
      old_lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
      vim.api.nvim_buf_call(src, function()
        vim.cmd(('silent %s %d'):format(fwd, dist))
      end)
    end)

    if view then
      pcall(vim.api.nvim_win_call, sw, function()
        vim.fn.winrestview(view)
      end)
    end
    vim.o.eventignore = ei

    -- make sure we are back where we started
    local now = vim.fn.undotree(src).seq_cur
    if now ~= b_seq then
      pcall(vim.api.nvim_buf_call, src, function()
        vim.cmd.undo { b_seq, mods = { silent = true } }
      end)
      now = vim.fn.undotree(src).seq_cur
    end
    if now ~= b_seq then
      vim.notify(
        ('[gliter] undotree: could not return to undo state %d'):format(b_seq),
        vim.log.levels.WARN
      )
    end
  end

  -- trailing newline, like classic temp-file diffs (keeps "\ No newline at
  -- end of file" markers out of the panel)
  local a = #old_lines > 0 and table.concat(old_lines, '\n') .. '\n' or ''
  local b = #new_lines > 0 and table.concat(new_lines, '\n') .. '\n' or ''
  local unified = run_diff(a, b, 'unified') or ''
  local hunks = run_diff(a, b, 'indices') or {}

  local adds, dels = 0, 0
  for _, h in ipairs(hunks) do
    dels = dels + h[2]
    adds = adds + h[4]
  end

  -- panel content, header first
  local out = { ('- seq: %d -'):format(a_seq), ('+ seq: %d +'):format(b_seq) }
  if unified ~= '' then
    for l in unified:gmatch('[^\n]+') do
      out[#out + 1] = l
    end
  end
  local pbuf = st.panel.buf
  if vim.api.nvim_buf_is_valid(pbuf) then
    pcall(function()
      vim.bo[pbuf].modifiable = true
      vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, out)
      vim.bo[pbuf].modifiable = false
    end)
  end

  -- panel statusline: "5 ++++--" summary bar
  local pwin = st.panel.win
  if vim.api.nvim_win_is_valid(pwin) then
    local width = math.max(vim.api.nvim_win_get_width(pwin) - 4, 4)
    local total = adds + dels
    local nadd, ndel = adds, dels
    if total > width and total > 0 then
      nadd = math.floor(adds * width / total)
      ndel = width - nadd
    end
    pcall(function()
      vim.wo[pwin].statusline = (' %d %s%s'):format(total, ('+'):rep(nadd), ('-'):rep(ndel))
    end)
  end

  mark_changes(st, hunks)
end

local function panel_toggle(st)
  if st.panel and vim.api.nvim_win_is_valid(st.panel.win) then
    panel_hide(st)
    return
  end
  panel_create(st)
  local cur = 0
  pcall(function()
    cur = vim.fn.undotree(st.src).seq_cur or 0
  end)
  local a
  if st.prev_seq ~= cur and st.prev_seq then
    a = st.prev_seq
  else
    a = math.max(cur - 1, 0)
  end
  diff_update(st, a, cur)
end

--------------------------------------------------------- event handlers

local function on_cursor_moved(st)
  if st.dead then
    return
  end
  if not (vim.api.nvim_buf_is_valid(st.buf) and vim.api.nvim_buf_is_valid(st.src)) then
    return
  end
  -- the viewer's own CursorMoved handler (registered first) has already
  -- undone the buffer to the state under the cursor
  local cur = vim.fn.undotree(st.src).seq_cur
  refresh_current(st)
  if st.prev_seq ~= cur then
    diff_update(st, st.prev_seq, cur)
    st.prev_seq = cur
  end
end

local function on_src_changed(st)
  if st.dead then
    return
  end
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  -- the viewer has just re-rendered the tree; redo the virt_line colors
  color_connectors(st.buf)
  refresh_current(st)
  if not vim.api.nvim_buf_is_valid(st.src) then
    return
  end
  local cur = vim.fn.undotree(st.src).seq_cur or 0
  st.prev_seq = cur
  -- refresh the panel to show the latest change
  if st.panel and vim.api.nvim_win_is_valid(st.panel.win) and cur > 0 then
    diff_update(st, cur - 1, cur)
  end
end

local function cleanup(st)
  if st.dead then
    return
  end
  st.dead = true
  panel_hide(st)
  if st.src_win and vim.api.nvim_win_is_valid(st.src_win) then
    for _, id in ipairs(st.matches or {}) do
      pcall(vim.fn.matchdelete, id, st.src_win)
    end
  end
  if st.src and vim.api.nvim_buf_is_valid(st.src) then
    pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = st.src })
  end
  if vim.api.nvim_win_is_valid(st.win) then
    pcall(vim.fn.clearmatches, st.win)
  end
  if st.group then
    pcall(vim.api.nvim_del_augroup_by_id, st.group)
  end
  S[st.buf] = nil
end

----------------------------------------------------------- per-tree setup

local function setup_tree(tree_buf, opts)
  if S[tree_buf] then
    S[tree_buf].opts = opts
    return
  end
  local w
  pcall(function()
    w = vim.b[tree_buf].nvim_is_undotree
  end)
  if not w then
    return
  end

  -- find the source buffer (b.nvim_undotree = tree window id)
  local src
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local ok, v = pcall(function()
      return vim.b[b].nvim_undotree
    end)
    if ok and v == w then
      src = b
      break
    end
  end
  if not src then
    return
  end

  local sw = vim.fn.bufwinid(src)

  local st = {
    buf = tree_buf,
    win = w,
    src = src,
    src_win = (sw and sw > 0) and sw or nil,
    prev_seq = 0,
    matches = {},
    cur_matches = {},
    opts = opts,
  }
  S[tree_buf] = st

  decorate_static(st)
  color_connectors(tree_buf)
  refresh_current(st)

  local group = vim.api.nvim_create_augroup(('gliter.undotree.%d'):format(tree_buf), { clear = true })
  st.group = group

  -- registered after the viewer's own autocmds, so we always run after it
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = group,
    buffer = tree_buf,
    callback = function()
      on_cursor_moved(st)
    end,
  })
  vim.api.nvim_create_autocmd({ 'TextChanged', 'InsertLeave' }, {
    group = group,
    buffer = src,
    callback = function()
      on_src_changed(st)
    end,
  })
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(w),
    callback = function()
      cleanup(st)
    end,
  })

  -- D in the tree toggles the diff window
  pcall(vim.keymap.set, 'n', 'D', function()
    panel_toggle(st)
  end, { buffer = tree_buf, silent = true })

  st.prev_seq = vim.fn.undotree(src).seq_cur or 0

  local want_panel
  if opts.diff_panel == true then
    want_panel = true
  elseif opts.diff_panel == false then
    want_panel = false
  else -- 'auto': only when nvim.difftool is loaded
    want_panel = vim.g.loaded_difftool ~= nil
  end

  if want_panel then
    panel_create(st)
    if st.prev_seq > 0 then
      -- on open, show the diff of the latest change
      diff_update(st, st.prev_seq - 1, st.prev_seq)
    end
  end
end

------------------------------------------------------------------- public

-- The <Leader>u toggle: open the tree, or close it from any of its windows
-- — the tree itself, the edited buffer or gliter's diff panel. The built-in
-- require('undotree').open() (and :Undotree) only close when the current
-- buffer is the edited buffer (b:nvim_undotree) or the tree buffer
-- (b:nvim_is_undotree); pressed in the diff panel — or any other buffer —
-- it opens a second tree window instead. This one knows the panel belongs
-- to the tree and closes it. Closing the tree window takes the panel with
-- it (the WinClosed cleanup does that).
local function toggle_tree()
  local cur = vim.api.nvim_get_current_buf()

  -- inside the tree window: b:nvim_is_undotree holds its window id
  local ok, w = pcall(function()
    return vim.b[cur].nvim_is_undotree
  end)
  if ok and w and vim.api.nvim_win_is_valid(w) then
    vim.api.nvim_win_close(w, true)
    return
  end

  -- inside the diff panel: close the tree it belongs to
  for _, st in pairs(S) do
    if st.panel and st.panel.buf == cur and vim.api.nvim_win_is_valid(st.win) then
      vim.api.nvim_win_close(st.win, true)
      return
    end
  end

  -- the edited buffer (the built-in open() closes it) or any other buffer
  -- (it opens the tree for that buffer)
  require('undotree').open()
end

--- Configure the built-in :Undotree viewer.
--- @param opts table? {
---   toggle: string|false open/close key (default '<Leader>u'),
---   difftool: boolean :packadd nvim.difftool (default true),
---   diff_panel: 'auto'|boolean, panel_height: integer }
function M.setup(opts)
  opts = vim.tbl_deep_extend('force', {
    toggle = '<Leader>u',
    difftool = true,
    diff_panel = 'auto',
    panel_height = 10,
  }, opts or {})

  M.did_setup = true

  -- The viewer (and optionally difftool) are dist plugins behind :packadd;
  -- load them here so :Undotree works out of the box — no packadd lines in
  -- your init.lua anymore. The require-first check skips the packadd when
  -- the pack is already on the runtimepath.
  if not pcall(require, 'undotree') then
    pcall(vim.cmd, 'packadd nvim.undotree')
  end
  if opts.difftool then
    pcall(vim.cmd, 'packadd nvim.difftool')
  end

  if opts.toggle and opts.toggle ~= '' then
    vim.keymap.set('n', opts.toggle, toggle_tree, {
      desc = 'Undo tree: open (press again to close, works from the diff panel too)',
    })
  end

  define_highlights()
  define_signs()

  local group = vim.api.nvim_create_augroup('gliter.undotree', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'nvim-undotree',
    callback = function(ev)
      setup_tree(ev.buf, opts)
    end,
  })
  -- a colorscheme switch wipes non-default groups; put the palette back
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = define_highlights,
  })

  -- decorate a tree that is already open
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local ok, is_tree = pcall(function()
      return vim.b[b].nvim_is_undotree
    end)
    if ok and is_tree then
      setup_tree(b, opts)
    end
  end
end

return M
