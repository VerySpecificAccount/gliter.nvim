--- Thin wrapper around prompts and notifications.
--- Always called as `ui.confirm(...)` (never cached in a local) so tests can replace them.
local config = require('gliter.netrw.config')

local M = {}

---@param msg string
---@param level? integer
function M.notify(msg, level)
  level = level or vim.log.levels.INFO
  if level < config.options.notify_level then
    return
  end
  vim.notify(msg, level, { title = 'gliter.netrw' })
end

--- Blocking multiple-choice prompt. Returns the 1-based choice, or 0 when dismissed.
---@param msg string
---@param choices string  e.g. "&Yes\n&No"
---@param default? integer
---@return integer
function M.confirm(msg, choices, default)
  local ok, res = pcall(vim.fn.confirm, msg, choices, default or 1, 'Question')
  return ok and res or 0
end

--- Yes/No prompt: `y` confirms, `n` (or Esc / Ctrl-C) declines, anything else is ignored.
--- Enter does nothing, so a stray Enter cannot confirm a deletion.
---@param msg string
---@return boolean
function M.yes_no(msg)
  vim.api.nvim_echo({ { msg .. '  [y/n]', 'Question' } }, true, {})
  local yes = { 'y', 'Y' }
  local no = { 'n', 'N', vim.keycode('<Esc>'), '\3' }
  while true do
    local key = vim.fn.getcharstr()
    if vim.tbl_contains(yes, key) then
      vim.cmd('redraw | echo ""')
      return true
    end
    if vim.tbl_contains(no, key) then
      vim.cmd('redraw | echo ""')
      return false
    end
  end
end

--- Blocking text prompt — vim.fn.input()'s, with the answer
--- remembered in the `@` history: <Up>/<Down> walk the answers given
--- before, and with gliter.cmd set up its readline keys edit the line
--- and the previous answer shows as a ghost after it. Returns nil
--- when cancelled or empty.
---@param prompt string
---@param default? string
---@param completion? string  e.g. 'dir'
---@return string?
function M.input(prompt, default, completion)
  local opts = { prompt = prompt, cancelreturn = '' }
  if default and default ~= '' then
    opts.default = default
  end
  if completion then
    opts.completion = completion
  end
  local ok, res = pcall(vim.fn.input, opts)
  if not ok or not res or res == '' then
    return nil
  end
  if vim.fn.histget('@', -1) ~= res then
    vim.fn.histadd('@', res)
  end
  return res
end

--- The hint the live prompt shows, on the cmdline's own row at the
--- right end: Comment's ink on MsgArea's paper, a float that never
--- takes focus and never paints a window of its own color over the
--- line.
local hint_win ---@type integer?
local hint_live = false ---@type boolean the live prompt is up
M.last_hint = nil ---@type string? the hint the live prompt is showing (for tests)
local function hint_close()
  if hint_win and vim.api.nvim_win_is_valid(hint_win) then
    vim.api.nvim_win_close(hint_win, true)
  end
  hint_win = nil
end

local function hint_show(msg)
  M.last_hint = msg
  if not hint_live or msg == nil or msg == '' then
    hint_close()
    return
  end
  -- the window work is scheduled: a CmdlineChanged that comes out of a
  -- gliter.cmd mapping (setcmdline()) fires inside a textlock that
  -- forbids changing text or windows, and the schedule lands after it
  -- lifts — still before the row is seen (and never once the prompt is
  -- down: hint_live says no)
  vim.schedule(function()
    if not hint_live or msg == nil or msg == '' then
      return
    end
    if vim.fn.hlexists('GliterNetrwHint') == 0 then
      local bg = vim.fn.synIDattr(vim.fn.hlID('MsgArea'), 'bg#')
      local fg = vim.fn.synIDattr(vim.fn.hlID('Comment'), 'fg#')
      if bg ~= '' and fg ~= '' then
        vim.api.nvim_set_hl(0, 'GliterNetrwHint', { default = true, fg = fg, bg = bg })
      else
        vim.api.nvim_set_hl(0, 'GliterNetrwHint', { default = true, link = 'Comment' })
      end
    end
    local width = math.min(vim.fn.strdisplaywidth(msg), math.max(8, vim.o.columns - 8))
    if vim.fn.strdisplaywidth(msg) > width then
      msg = msg:sub(1, width - 1) .. '…'
    end
    if not (hint_win and vim.api.nvim_win_is_valid(hint_win)) then
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = 'nofile'
      vim.bo[buf].bufhidden = 'wipe'
      vim.bo[buf].swapfile = false
      hint_win = vim.api.nvim_open_win(buf, false, {
        relative = 'editor',
        width = width,
        height = 1,
        row = math.max(0, vim.o.lines - 1),
        col = math.max(0, vim.o.columns - width - 1),
        style = 'minimal',
        border = 'none',
        zindex = 450,
        focusable = false,
      })
      vim.wo[hint_win].winblend = 100
      vim.wo[hint_win].winhighlight = 'Normal:GliterNetrwHint'
      vim.wo[hint_win].wrap = false
    else
      vim.api.nvim_win_set_config(hint_win, {
        relative = 'editor',
        width = width,
        height = 1,
        row = math.max(0, vim.o.lines - 1),
        col = math.max(0, vim.o.columns - width - 1),
      })
    end
    vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(hint_win), 0, -1, false, { msg })
    -- a float painted while the prompt is up is not composited on its
    -- own — the line redraws the message grid only — so the flush is
    -- asked for by name
    pcall(vim.api.nvim__redraw, { flush = true })
  end)
end

--- Blocking live prompt: input()'s cousin with a callback. After every
--- change `on_change(text)` runs — the live preview behind the
--- `%<mark>` regexp, say — and whatever it returns is shown as a hint
--- at the right end of the command line's row, above the ghost (the
--- hint wins the row; gliter.cmd trims itself around the ruler).
--- Enter accepts (the text, empty string included), Esc or Ctrl-C
--- cancels: nil comes back. With gliter.cmd set up its readline keys
--- edit the line and the previous answers ghost after it; <Up>/<Down>
--- walk the `@` history. A Enter that `on_enter` vetoes is not
--- input()'s to give, so it is not given: validate after.
---@param prompt string
---@param opts { on_change: fun(text: string): string? }
---@return string?
function M.live_input(prompt, opts)
  local aug = vim.api.nvim_create_augroup('GliterNetrwLive', { clear = true })
  vim.api.nvim_create_autocmd('CmdlineChanged', {
    group = aug,
    callback = function()
      local ok, msg = pcall(opts.on_change, vim.fn.getcmdline())
      hint_show(ok and msg or nil)
    end,
  })
  vim.api.nvim_create_autocmd('CmdlineLeave', {
    group = aug,
    callback = hint_close,
  })
  hint_live = true
  local ok, res = pcall(vim.fn.input, { prompt = prompt, cancelreturn = '' })
  hint_live = false
  vim.api.nvim_del_augroup_by_id(aug)
  hint_close()
  if not ok or not res or res == '' then
    return nil
  end
  if vim.fn.histget('@', -1) ~= res then
    vim.fn.histadd('@', res)
  end
  return res
end

return M
