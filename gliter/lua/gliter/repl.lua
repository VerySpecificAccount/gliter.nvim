--- gliter.repl — SLIME's good half for the built-in terminal: one REPL per
--- filetype, Spacemacs' shell-layer keys, iron.nvim's sending (Neovim
--- 0.9+).
---
--- WHAT IT DOES
---   * One REPL per filetype (programs = 'python3 -i', 'lua -i', ...),
---     opened in a bottom terminal window on the first send — auto_start
---     (default) — and kept for the session: closing its window (q) does
---     not kill it, sends keep going to the hidden terminal, and the
---     toggle key (or a jump-send) brings the window back.
---   * The keys are Spacemacs' shell layer, one Leader shorter:
---       <Leader>ls  Visual  send the selection to the REPL, stay here
---       <Leader>lS  Visual  send the selection and JUMP to the REPL,
---                           in insert mode — comint's other half
---       <Leader>ll  Normal  send the current line, cursor to the next:
---                           hold the key, walk the file into the REPL
---       <Leader>lb  Normal  send the whole buffer
---       <Leader>le  n + x   EVALUATE, headless: the line / the
---                           selection runs through the interpreter with
---                           no REPL at all — the output lands in
---                           gliter.make's compilation buffer, so
---                           tracebacks are jumpable (like `SPC l e`)
---   * Sends are chansend()s on the terminal's job: the REPL sees the
---     text as if typed, program output stays in the terminal, and the
---     cursor never leaves the source buffer unless a key asked for it.
---     A multi-line selection is dedented (the common indentation goes;
---     the relative structure stays), and the interpreters that need a
---     blank line after a block to run it (the classic python REPL's
---     `...` prompt) get one — extra_newline.
---
--- USAGE (from your init.lua)
---   require('gliter.repl').setup()                     -- defaults
---   require('gliter.repl').setup { height = 16 }
---   require('gliter').setup { repl = true }            -- through gliter
---
---   :GliterRepl            show/hide the REPL of this filetype
---   :GliterReplSendLine    the <Leader>ll action
---   :GliterReplSendBuffer  the <Leader>lb action
---   :GliterReplEval        the <Leader>le action

local M = {}

M.did_setup = false

if vim.fn.has('nvim-0.9') == 0 then
  function M.setup()
    vim.notify('[gliter] repl needs Neovim 0.9+ (jobstart term, chansend)', vim.log.levels.WARN)
  end
  return M
end

local defaults = {
  keys = {
    send_selection = '<Leader>ls', -- Visual: send the selection, stay here
    send_selection_jump = '<Leader>lS', -- Visual: send it and jump in
    send_line = '<Leader>ll', -- send the current line (cursor moves down)
    send_buffer = '<Leader>lb', -- send the whole buffer
    eval = '<Leader>le', -- n + x: headless evaluate, no REPL opened
    toggle = false, -- e.g. '<Leader>li': show/hide the REPL window
  },
  -- one REPL per filetype; a table row works too:
  --   python = { cmd = 'ptipython -i' }
  programs = {
    python = 'python3 -i',
    lua = 'lua -i',
    javascript = 'node -i',
    sh = 'bash',
    haskell = 'ghci',
  },
  -- headless evaluators for <Leader>le: the interpreter that runs the
  -- snippet without any REPL (its output goes through gliter.make)
  eval_programs = {
    python = 'python3',
    lua = 'lua',
    javascript = 'node',
    sh = 'bash',
    haskell = 'runhaskell',
  },
  -- interpreters that want a blank line after a block before they run
  -- it — the classic python REPL keeps showing `...` until one arrives
  extra_newline = { python = true },
  auto_start = true, -- a send with no live REPL starts one (false: notify)
  height = 12, -- the REPL window's height
  position = 'botright', -- 'botright' (bottom) | 'vertical' (right side)
  dedent = true, -- strip a selection's common indentation before sending
}
local cfg = vim.deepcopy(defaults)

local repls = {} -- [ft] = { buf, win, job, cmd }

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = 'gliter.repl' })
end

------------------------------------------------------------------ state --

--- Is the REPL of `ft` alive (a buffer, and a job that is still running)?
---@param ft string
---@return table? r
local function live(ft)
  local r = repls[ft]
  if not r or not vim.api.nvim_buf_is_valid(r.buf) then
    repls[ft] = nil
    return nil
  end
  if not (r.job and vim.fn.jobwait({ r.job }, 0)[1] == -1) then
    repls[ft] = nil
    return nil
  end
  return r
end

--- The program row for `ft`: a string, or { cmd = '...' }.
---@param ft string
---@return string? cmd
local function program_of(ft)
  local p = cfg.programs[ft]
  if type(p) == 'table' then
    return p.cmd or p[1]
  end
  if p == false then
    return nil
  end
  return p
end

--- Start `cmd` as a terminal in the current buffer, return its job id —
--- jobstart()'s `term = true` is the modern door; termopen() the old
--- one, called WITHOUT its optional {opts} dict (an empty Lua table no
--- longer crosses the fn bridge as a dictionary, and termopen(cmd, {})
--- rejects it — the E475 of Neovim 0.11+).
---@param cmd string
---@return integer? id, string? err
local function term_open(cmd)
  local ok, id = pcall(vim.fn.jobstart, cmd, { term = true })
  if ok and type(id) == 'number' and id > 0 then
    return id
  end
  local err = id
  ok, id = pcall(vim.fn.termopen, cmd)
  if ok and type(id) == 'number' and id > 0 then
    return id
  end
  return nil, tostring(id or err)
end

--- Open the REPL window for a fresh terminal.
local function open_split()
  if cfg.position == 'vertical' then
    vim.cmd('rightbelow 60vnew')
  else
    vim.cmd(('botright %dnew'):format(math.max(1, cfg.height)))
  end
end

--- Start the REPL of `ft` (its window opens; the focus stays where it
--- was unless `enter`). Returns its state table, or nil (with a notice).
---@param ft string
---@param enter? boolean
---@return table?
local function start(ft, enter)
  local cmd = program_of(ft)
  if not cmd then
    if next(cfg.programs) == nil then
      notify('no repl.programs at all — add one, e.g. programs = { ' .. ft .. " = 'python3 -i' }")
    else
      notify(("no REPL program for filetype '%s' — add programs['%s']"):format(ft, ft), vim.log.levels.WARN)
    end
    return nil
  end
  local cur = vim.api.nvim_get_current_win()
  open_split()
  local win = vim.api.nvim_get_current_win()
  local id, err = term_open(cmd)
  if not id then
    pcall(vim.api.nvim_win_close, win, true)
    return notify('[gliter] repl: ' .. (err or 'cannot start') .. ' — is the interpreter installed?', vim.log.levels.ERROR)
  end
  local buf = vim.api.nvim_win_get_buf(win)
  vim.bo[buf].bufhidden = 'hide' -- q on the window does not kill the REPL
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  -- the process ended: the slot is free for a fresh start
  vim.api.nvim_create_autocmd('TermClose', {
    buffer = buf,
    callback = function()
      if repls[ft] and repls[ft].buf == buf then
        repls[ft] = nil
      end
    end,
  })
  vim.keymap.set('n', 'q', function()
    local jid = vim.b[buf].terminal_job_id
    if jid and vim.fn.jobwait({ jid }, 0)[1] == -1 then
      return notify('still running — the REPL stays: i to use it, :bd! to kill it')
    end
    pcall(vim.api.nvim_win_close, win, true)
  end, { buffer = buf, silent = true, desc = 'gliter.repl: hide the REPL window (it stays alive)' })

  repls[ft] = { buf = buf, win = win, job = id, cmd = cmd }
  if enter then
    vim.cmd('startinsert')
  elseif vim.api.nvim_win_is_valid(cur) then
    vim.api.nvim_set_current_win(cur)
  end
  return repls[ft]
end

--- The live REPL of `ft`, started when auto_start says so.
---@param ft string
---@return table?
local function ensure(ft)
  local r = live(ft)
  if r then
    return r
  end
  if not cfg.auto_start then
    notify(("no live REPL for '%s' (auto_start = false)"):format(ft), vim.log.levels.WARN)
    return nil
  end
  return start(ft)
end

--- Show the REPL window of `ft` (open it again if it was hidden), and
--- optionally enter it.
---@param ft string
---@param enter? boolean
local function show(ft, enter)
  local r = ensure(ft)
  if not r then
    return
  end
  for _, w in ipairs(vim.fn.win_findbuf(r.buf)) do
    r.win = w
    if enter then
      vim.api.nvim_set_current_win(w)
      vim.cmd('startinsert')
    end
    return
  end
  local cur = vim.api.nvim_get_current_win()
  open_split()
  local win = vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_win_set_buf, win, r.buf)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  r.win = win
  if enter then
    vim.cmd('startinsert')
  elseif vim.api.nvim_win_is_valid(cur) then
    vim.api.nvim_set_current_win(cur)
  end
end

------------------------------------------------------------------ send --

--- Drop the common indentation of a block of lines (the relative
--- structure stays: what a nested block needs, what a stray column does
--- not), and the empty lines around it.
---@param lines string[]
---@return string[]
local function normalize(lines)
  while #lines > 0 and lines[1]:find('^%s*$') do
    table.remove(lines, 1)
  end
  while #lines > 0 and lines[#lines]:find('^%s*$') do
    table.remove(lines)
  end
  if cfg.dedent and #lines > 1 then
    local min = math.huge
    for _, l in ipairs(lines) do
      if l:find('%S') then
        min = math.min(min, #(l:match('^%s*')))
      end
    end
    if min ~= math.huge and min > 0 then
      for i, l in ipairs(lines) do
        lines[i] = l:sub(min + 1)
      end
    end
  end
  return lines
end

--- Send text to the REPL of `ft` (starting one when auto_start allows).
---@param ft string
---@param text string the code, newline-terminated lines
---@return boolean sent
local function send(ft, text)
  local r = ensure(ft)
  if not r then
    return false
  end
  local lines = normalize(vim.split(text, '\n', { plain = true }))
  if #lines == 0 then
    return false
  end
  local payload = table.concat(lines, '\n') .. '\n'
  if cfg.extra_newline[ft] and (#lines > 1 or lines[#lines]:find(':%s*$')) then
    payload = payload .. '\n' -- run the block, do not keep the ... prompt
  end
  local ok = pcall(vim.fn.chansend, r.job, payload)
  if not ok then
    repls[ft] = nil
    return notify('the REPL is no longer running', vim.log.levels.WARN)
  end
  return true
end

--- The live Visual selection (v to .): '< '> are only written when
--- Visual mode ends, and the mapping fires before that.
---@return string[]
local function selection_lines()
  local vs, ve = vim.fn.getpos('v'), vim.fn.getpos('.')
  local first = math.min(vs[2], ve[2])
  local last = math.max(vs[2], ve[2])
  return vim.api.nvim_buf_get_lines(0, first - 1, last, false)
end

-------------------------------------------------------------------- api --

--- Leave Visual mode (a Visual-invoked mapping that opens windows
--- should not leave a selection dangling in the source window).
local function leave_visual()
  if vim.fn.mode():find('^[vV\22]') then
    vim.cmd('normal! ' .. vim.api.nvim_replace_termcodes('<Esc>', true, false, true))
  end
end

--- <Leader>ls / <Leader>lS — send the Visual selection to the REPL of
--- this buffer's filetype; `jump` also focuses the REPL in insert mode.
---@param jump? boolean
function M.send_selection(jump)
  local ft = vim.bo.filetype
  if not program_of(ft) then
    return notify(("no REPL program for filetype '%s' — add programs['%s']"):format(ft ~= '' and ft or "''", ft), vim.log.levels.WARN)
  end
  local lines = selection_lines() -- read live: v to .
  leave_visual()
  if not send(ft, table.concat(lines, '\n')) then
    return
  end
  if jump then
    show(ft, true)
  end
end

--- <Leader>ll — send the current line, then move to the next: hold the
--- key and the file walks into the REPL, a line per press.
function M.send_line()
  local ft = vim.bo.filetype
  local line = vim.api.nvim_get_current_line()
  if line == '' then
    return
  end
  if send(ft, line) then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if row < vim.api.nvim_buf_line_count(0) then
      vim.cmd('normal! j')
    end
  end
end

--- <Leader>lb — send the whole buffer to the REPL of its filetype.
function M.send_buffer()
  local ft = vim.bo.filetype
  send(ft, table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n'))
end

--- <Leader>le — EVALUATE, headless: the line (Normal) or the selection
--- (Visual) runs through eval_programs[filetype] with no REPL involved.
--- The output goes to gliter.make's compilation buffer when it is around
--- (tracebacks jumpable, errors in the quickfix), else to a notice.
function M.eval()
  local ft = vim.bo.filetype
  local interp = cfg.eval_programs[ft]
  if not interp then
    local hint = program_of(ft)
        and ("— add eval_programs['%s']"):format(ft)
        or ("— no REPL program either; add programs['%s'] first"):format(ft)
    return notify(("no headless evaluator for filetype '%s' %s"):format(ft ~= '' and ft or "''", hint), vim.log.levels.WARN)
  end
  local visual = vim.fn.mode():find('^[vV\22]') ~= nil
  local lines = visual and selection_lines() or { vim.api.nvim_get_current_line() }
  if visual then
    leave_visual()
  end
  lines = normalize(lines)
  if #lines == 0 then
    return
  end
  local tmp = vim.fn.tempname()
  if not pcall(vim.fn.writefile, lines, tmp) then
    return notify('cannot write the snippet to a temp file', vim.log.levels.ERROR)
  end
  local cmd = interp .. ' < ' .. vim.fn.shellescape(tmp)
  local ok, err = pcall(function()
    require('gliter.make').run(nil, {
      cmd = cmd,
      title = ('gliter eval (%s)'):format(ft),
      tmp = tmp,
    })
  end)
  if not ok then
    -- gliter.make not usable: the snippet still runs, the result is only
    -- said — set gliter.make up for the full output (+ jumpable errors)
    vim.fn.jobstart(cmd, {
      on_exit = function(_, code)
        vim.schedule(function()
          notify(('eval %s (exit %d) — set gliter.make up for the full output'):format(code == 0 and 'done' or 'failed', code),
            code == 0 and vim.log.levels.INFO or vim.log.levels.WARN)
        end)
      end,
    })
  end
end

--- <Leader>li (toggle) — show the REPL window of this buffer's
--- filetype, or hide it when it is on screen. The REPL itself stays.
function M.toggle()
  local ft = vim.bo.filetype
  local r = live(ft)
  if not r then
    return show(ft, true)
  end
  for _, w in ipairs(vim.fn.win_findbuf(r.buf)) do
    pcall(vim.api.nvim_win_close, w, false)
    return
  end
  show(ft, true)
end

--- The REPL state of a filetype, if one is live: { buf, win, job, cmd }.
---@param ft? string
---@return table?
function M.repl(ft)
  return live(ft or vim.bo.filetype)
end

------------------------------------------------------------------ setup --

---@param opts? table
function M.setup(opts)
  M.did_setup = true
  opts = (type(opts) == 'table') and opts or {}
  for k, v in pairs(opts) do
    if k == 'keys' or k == 'programs' or k == 'eval_programs' or k == 'extra_newline' then
      cfg[k] = vim.tbl_extend('force', cfg[k] or {}, (type(v) == 'table') and v or {})
    else
      cfg[k] = v
    end
  end

  local function map(modes, key, fn, desc)
    if key then
      vim.keymap.set(modes, key, fn, { silent = true, desc = 'gliter.repl: ' .. desc })
    end
  end
  map('x', cfg.keys.send_selection, function()
    M.send_selection(false)
  end, 'send the selection to the REPL, stay here')
  map('x', cfg.keys.send_selection_jump, function()
    M.send_selection(true)
  end, 'send the selection and jump to the REPL')
  map('n', cfg.keys.send_line, M.send_line, 'send the current line to the REPL')
  map('n', cfg.keys.send_buffer, M.send_buffer, 'send the whole buffer to the REPL')
  map({ 'n', 'x' }, cfg.keys.eval, M.eval, 'evaluate the line/selection headless (no REPL)')
  map('n', cfg.keys.toggle, M.toggle, 'show/hide the REPL window (the REPL stays)')

  vim.api.nvim_create_user_command('GliterRepl', M.toggle, { desc = 'gliter.repl: show/hide the REPL of this filetype' })
  vim.api.nvim_create_user_command('GliterReplSendLine', M.send_line, { desc = 'gliter.repl: send the current line' })
  vim.api.nvim_create_user_command('GliterReplSendBuffer', M.send_buffer, { desc = 'gliter.repl: send the whole buffer' })
  vim.api.nvim_create_user_command('GliterReplEval', M.eval, { desc = 'gliter.repl: evaluate the line/selection headless' })

  return M
end

return M
