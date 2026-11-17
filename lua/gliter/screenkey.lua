--- gliter.screenkey — shows the keys you press, as you press them: a small
--- float above the cmdline, the newest key highlighted, the rest fading away
--- `timeout` milliseconds after the last press. For screencasts, demos and
--- pair sessions — the audience sees the keys, not your fingers.
---
--- The key list comes from `vim.on_key` — the keys as they are typed, before
--- any mapping eats them — and is only ever shown: nothing is intercepted,
--- nothing is replayed. Mouse events are left out (hover noise); so is
--- `<MouseMove>`'s whole family. `:GliterScreenkey` toggles it; the module
--- is opt-in like every gliter module, so naming it in setup() is the on
--- switch. The idea is older than the name: Emacs has shown keys since
--- the 1980s — `echo-keystrokes` echoing an unfinished sequence,
--- `view-lossage` (`C-h l`) listing the last ones — and showkey.el (Drew
--- Adams, 2015) made the showing live. screenkey.nvim (2024) brought it
--- into a float, under the name of the X11 screenkey tool that drew your
--- keystrokes over the screen for recordings. This is the light version:
--- one float, two colors, a timer.
local M = {}

M.did_setup = false

--- defaults — `timeout` ms of quiet clears the display, `max_keys` is how
--- many keys stay on screen, `row`/`col` position the float (0-based screen
--- cells; nil = bottom center).
M.defaults = {
  timeout = 2000,
  max_keys = 10,
  border = 'none',
  row = nil,
  col = nil,
}

M.options = vim.deepcopy(M.defaults)

local ns = vim.api.nvim_create_namespace('gliter_screenkey')
local buf = nil
local win = nil
local ring = {} ---@type string[]
local timer = nil
local enabled = false

local function close_float()
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  win = nil
end

local function render()
  close_float()
  if #ring == 0 then
    return
  end
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    buf = vim.api.nvim_create_buf(false, true)
  end
  local line = table.concat(ring, '  ')
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  -- everything but the newest key fades; the newest is lit
  local before = #line - #ring[#ring]
  if before > 0 then
    vim.api.nvim_buf_add_highlight(buf, ns, 'GliterScreenkey', 0, 0, before)
  end
  vim.api.nvim_buf_add_highlight(buf, ns, 'GliterScreenkeyNewest', 0, before, -1)
  local width = math.max(3, vim.fn.strdisplaywidth(line) + 2)
  if width > vim.o.columns then -- drop the oldest keys until it fits
    while #ring > 1 and vim.fn.strdisplaywidth(table.concat(ring, '  ')) + 2 > vim.o.columns do
      table.remove(ring, 1)
    end
    return render()
  end
  local row = M.options.row or (vim.o.lines - 3)
  local col = M.options.col or math.floor((vim.o.columns - width) / 2)
  win = vim.api.nvim_open_win(buf, false, {
    relative = 'editor',
    row = math.max(1, row),
    col = math.max(0, col),
    width = width,
    height = 1,
    focusable = false,
    style = 'minimal',
    border = M.options.border,
    noautocmd = true,
  })
  pcall(vim.cmd, 'redraw')
end

--- The vim.on_key body, split out so tests can drive it. Only the SECOND
--- argument counts: `typed` is the key as the user pressed it, and it is
--- empty exactly for the keys a mapping replays internally — those are not
--- presses, so they stay off the display (`<Leader>cj` shows as the three
--- keys you typed, not the multicursor plumbing it runs).
---@param raw string the key, post-mapping
---@param typed? string the key as typed; nil/empty = mapping-internal
function M._on_key(raw, typed)
  if not enabled then
    return
  end
  local key = typed
  if key == nil or key == '' then
    return
  end
  -- an Alt key arrives as ESC + char on the wire; name it instead of the
  -- raw keytrans soup
  local tok
  if #key == 2 and key:byte(1) == 27 then
    tok = '<M-' .. vim.fn.keytrans(key:sub(2)) .. '>'
  else
    tok = vim.fn.keytrans(key)
  end
  if tok:find('Mouse') or tok:find('ScrollWheel') then
    return -- hover, click and wheel noise
  end
  if #tok > 16 then -- a pasted chunk, not a key
    tok = tok:sub(1, 15) .. '…'
  end
  ring[#ring + 1] = tok
  while #ring > M.options.max_keys do
    table.remove(ring, 1)
  end
  if timer then
    vim.fn.timer_stop(timer)
  end
  timer = vim.fn.timer_start(M.options.timeout, function()
    timer = nil
    ring = {}
    close_float()
    pcall(vim.cmd, 'redraw')
  end)
  render()
end

--- Show or hide the key display.
---@return boolean the new state
function M.toggle()
  enabled = not enabled
  if not enabled then
    ring = {}
    close_float()
    pcall(vim.cmd, 'redraw')
  end
  vim.notify(('[gliter] screenkey %s'):format(enabled and 'on' or 'off'), vim.log.levels.INFO)
  return enabled
end

--- The display's current contents (tests, and your own statusline).
---@return string[]
function M.keys()
  return vim.deepcopy(ring)
end

function M.setup(opts)
  M.did_setup = true
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  local function link(name, target)
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  link('GliterScreenkey', 'Comment')
  link('GliterScreenkeyNewest', 'SpecialKey')
  enabled = true
  vim.on_key(function(raw, typed)
    M._on_key(raw, typed)
  end)
  vim.api.nvim_create_user_command('GliterScreenkey', function()
    M.toggle()
  end, { desc = 'gliter.screenkey: toggle the pressed-keys display' })
  return M
end

return M
