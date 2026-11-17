--- Highlights entries that carry a mark, in every netrw buffer.
--- Decorations are recomputed from the buffer text whenever netrw redraws it
--- (`on_lines`), so they survive refreshes, sorting, style changes and tree expansion.
local config = require('gliter.netrw.config')
local marks = require('gliter.netrw.marks')
local netrw = require('gliter.netrw.listing')

local M = {}

local ns = vim.api.nvim_create_namespace('gliter_netrw')
local pending = {}

function M.setup_highlights()
  local function link(name, target)
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  link('GliterNetrwCopy', 'DiffAdd')
  link('GliterNetrwMove', 'DiffChange')
  link('GliterNetrwDelete', 'DiffDelete')
  link('GliterNetrwShell', 'DiffText')
  link('GliterNetrwArchive', 'Todo')
  link('GliterNetrwRun', 'Search')
  link('GliterNetrwIndicator', 'Comment')
  -- The live preview behind the %<mark> regexp prompt, lit up like a search.
  link('GliterNetrwSearch', 'Search')
  -- In-place edit mode: live feedback as the listing is edited.
  link('GliterNetrwEditNew', 'DiffAdd')
  link('GliterNetrwEditRename', 'DiffChange')
  link('GliterNetrwEditDelete', 'DiffDelete')
end

---@param buf integer
function M.refresh(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  if marks.is_empty() or vim.bo[buf].filetype ~= 'netrw' then
    return
  end
  -- The listing text is being edited in place (see edit.lua); its contents are not a
  -- real directory listing right now, so mark decoration would just be noise.
  if vim.b[buf].gliter_netrw_editing then
    return
  end
  local ctx = netrw.context(buf)
  if not ctx then
    return
  end
  for _, e in ipairs(netrw.all(ctx)) do
    local kind = marks.kind(e.path)
    if kind then
      local group = ({ copy = 'GliterNetrwCopy', move = 'GliterNetrwMove', delete = 'GliterNetrwDelete', shell = 'GliterNetrwShell', archive = 'GliterNetrwArchive', run = 'GliterNetrwRun' })[kind]
      local indicator = config.options.indicators[kind]
      local opts = { end_col = e.end_col, hl_group = group }
      if indicator then
        opts.virt_text = { { indicator, 'GliterNetrwIndicator' } }
        opts.virt_text_pos = 'eol'
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, e.lnum - 1, e.col, opts)
    end
  end
end

--- Debounced refresh (netrw edits a buffer in many small steps while re-listing).
---@param buf integer
function M.schedule(buf)
  if pending[buf] then
    return
  end
  pending[buf] = true
  vim.schedule(function()
    pending[buf] = nil
    M.refresh(buf)
  end)
end

function M.refresh_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == 'netrw' then
      M.refresh(buf)
    end
  end
end

--- Keep a netrw buffer decorated for as long as it lives (attached once per buffer).
---@param buf integer
function M.watch(buf)
  if vim.b[buf].gliter_netrw_watching then
    return
  end
  vim.b[buf].gliter_netrw_watching = true
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      M.schedule(buf)
    end,
    on_reload = function()
      M.schedule(buf)
    end,
    on_detach = function()
      pending[buf] = nil
    end,
  })
  M.schedule(buf)
end

return M
