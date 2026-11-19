--- gliter.netrw — marks, one-key commands and in-place editing for
--- Neovim's built-in netrw (no separate explorer buffer). Neovim 0.12+;
--- the full tour is doc/gliter.netrw.md.

local M = {}

if vim.fn.has('nvim-0.12') == 0 then
  function M.setup()
    vim.notify('[gliter] netrw needs Neovim 0.12+ (the built-in netrw it enhances)', vim.log.levels.WARN)
  end
  return M
end

local config = require('gliter.netrw.config')

M.did_setup = false

---@param opts? table
function M.setup(opts)
  config.setup(opts)
  M.did_setup = true

  -- :GliterNetrw* — the same as p / <Esc> / E inside a netrw buffer.
  vim.api.nvim_create_user_command('GliterNetrwPaste', function()
    require('gliter.netrw.actions').paste()
  end, { desc = 'Apply the marks into the current netrw directory' })
  vim.api.nvim_create_user_command('GliterNetrwClear', function()
    require('gliter.netrw.actions').clear()
  end, { desc = 'Clear the gliter.netrw marks' })
  vim.api.nvim_create_user_command('GliterNetrwEdit', function()
    require('gliter.netrw.actions').edit_toggle()
  end, { desc = 'Toggle in-place editing of the current netrw listing (add/remove/rename in place)' })
  vim.api.nvim_create_user_command('GliterNetrwBookmarks', function()
    require('gliter.netrw.bookmarks').list()
  end, { desc = 'List the gliter.netrw bookmarks (slots 1-9)' })

  local group = vim.api.nvim_create_augroup('GliterNetrw', { clear = true })
  local decor = require('gliter.netrw.decor')
  local keymaps = require('gliter.netrw.keymaps')

  decor.setup_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = decor.setup_highlights,
  })

  -- A netrw window that switches to another directory forgets the marks:
  -- they belong to the listing you set them on, and pasting a stale set
  -- into an unrelated directory is the one surprise this plugin must not
  -- produce. netrw gives every directory its own buffer (this buffer is
  -- wiped when you enter another one), so the switch is seen where the
  -- new buffer is announced: the window's previous netrw root. A refresh
  -- of the same directory — <C-l>, a sort, a style change — keeps the
  -- marks, of course.
  local listing = require('gliter.netrw.listing')
  local marks_mod = require('gliter.netrw.marks')
  local function check_root_switch(buf)
    local ctx = listing.context(buf)
    if not ctx then
      return
    end
    local prev = vim.w[ctx.win].gliter_netrw_root
    vim.w[ctx.win].gliter_netrw_root = ctx.root
    if prev and prev ~= ctx.root then
      marks_mod.clear()
    end
  end

  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'netrw',
    callback = function(args)
      -- Defer so netrw has finished installing its own buffer maps first.
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(args.buf) and vim.bo[args.buf].filetype == 'netrw' then
          check_root_switch(args.buf)
          -- The custom listing, when one is configured (see custom.lua),
          -- replaces the listing text now: the keys attach right after and
          -- read its flag to decide which of netrw's own keys the buffer
          -- may keep, and the decorations parse the text it left.
          require('gliter.netrw.custom').render(args.buf)
          keymaps.attach(args.buf)
          decor.watch(args.buf)
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'GliterNetrwClipboard',
    callback = decor.refresh_all,
  })
end

return M
