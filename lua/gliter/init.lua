--- gliter — one runtime path, several modules.
---
--- Modules are opt-in: setup() only sets up the modules you actually
--- name in its options. A module you leave out is not set up at
--- all — gliter installs nothing, maps nothing and creates no autocmds for
--- it. setup() with no table is a no-op.
---
--- Modules:
---   gliter.netrw          marks, one-key commands and in-place editing for
---                         the built-in netrw (Neovim 0.12+)
---   gliter.undotree       a <Leader>u toggle, colors and a bottom diff
---                         window for the built-in :Undotree viewer
---                         (Neovim 0.12+)
---   gliter.multicursor    keys for the built-in multicursors: one
---                         cursor, every line of a selection, every
---                         line below/above, every occurrence
---                         (Neovim 0.13+)
---   gliter.treesitterRE   expand-region for the treesitter age (works
---                         without a parser, too)
---   gliter.zoom           text-scale for the terminal, two
---                         engines: the current window/buffer
---                         redrawn in the Unicode Mathematical
---                         Alphanumeric alphabet (bold, monospace,
---                         small caps, squared, underlined — two
---                         direction tables you add styles to and
---                         remove them from), and <Leader>z's
---                         half-block glyph zoom with a big
---                         letter-sized cursor; per buffer, every
---                         other window untouched (Neovim 0.9+)
---   gliter.ctags          the built-in ctags support with better defaults,
---                         a one-command interface and quickfix (Neovim 0.10+)
---   gliter.make           per-filetype 'makeprg' and Emacs' *compilation*
---                         buffer: streaming, colored output whose errors
---                         fill the quickfix (Neovim 0.9+)
---   gliter.repl           a REPL per filetype with Spacemacs' send keys,
---                         and headless evaluation (Neovim 0.9+)
---   gliter.textobj        targets.vim's quotes and separators:
---                         objects that work on their delimiters
---                         and seek — the next pair after the
---                         cursor first, then back to the one
---                         before it, then the nearest by
---                         distance; in"/il" force a direction
---   gliter.sessions       :mksession with a memory: sessions saved in
---                         their project, a floating list to activate
---                         them, saving again updates
---   gliter.readme         the project's readme, opened or created by a
---                         key, every one you touched listed for quick
---                         access like recent files
---   gliter.justify        g= and :GliterJustify: reflow the paragraph
---                         (or the selection, or a range) and justify
---                         it — both margins flush, the way M-q fills
---   gliter.move          a visual move mode: <C-m> turns the
---                         selection into a thing the keys carry -
---                         h j k l, the goto motions 0 $ gg G f t
---                         F T and the word motions w e b W E B
---                         (line-wise, the cursor's line alone);
---                         C-m C-o/
---                         C-i walk this file's jumps (Vim's own
---                         jump list, other files' entries skipped,
---                         never taken), C-t transposes words, one
---                         undo for the session
---   gliter.matchit        M (the key you gave %) jumps between the
---                         words that bracket a block — if/end,
---                         function/endfunction, <div>/</div> — with
---                         the nesting counted; gM the other way;
---                         plain % when the cursor is on none of them
---   gliter.tohtml         :GliterTohtml: the buffer (or the selection)
---                         out as HTML with its syntax colors, as
---                         Markdown, or as PDF typeset by groff
---   gliter.w3            the web in a buffer: :GliterW3 <url> — curl and
---                         pandoc render the page (lynx without pandoc,
---                         w3m with the links taken out of the html,
---                         wls lists the site), links followable from the
---                         keyboard while a spinner covers the load; H
---                         goes back, R reloads, keywords search
---   gliter.cmd            readline's keys on the built-in command line
---                         (C-a/C-b/C-f/C-d/C-k/C-t, M-b/M-f, M-BS/M-d
---                         — Tab/S-Tab and the wildmenu untouched),
---                         and the history's continuation as a ghost
---                         after the line (fish's autosuggestion:
---                         C-p cycles the echoes, C-n cycles them back
---                         and takes the newest, C-y/M-l take whichever
---                         is showing) —
---                         input()'s prompts get the same ride
---   gliter.which          a light which-key: pause after a prefix and a
---                         popup lists the mappings that continue it,
---                         straight out of :map
---   gliter.screenkey      shows the keys you press as you press them —
---                         a float for screencasts and demos
---   gliter.pack           DEPRECATED, to be removed — the floating
---                         package menu over awesome-neovim
---
--- Usage (from your init.lua, which runs before plugin/ files):
---   require('gliter').setup { netrw = {} }            -- only netrw
---   require('gliter').setup { undotree = { panel_height = 6 } }
---   require('gliter').setup { multicursor = true }    -- true = defaults
---   require('gliter').setup {
---     netrw        = { star_kind = 'copy' },
---     treesitterRE = { keys = { expand_up = '<BS>' } },
---   }
---   require('gliter').setup { netrw = false }         -- explicitly off
---
--- A module you set up on its own (require('gliter.netrw').setup() straight
--- from your init.lua) keeps that configuration: just don't name it above.

local M = {}

--- The suite's version. gliter is versioned as ONE plugin; the
--- individual modules carry no versions of their own.
M._VERSION = 0

-- { '<option key>', '<module>' } — one row per module; add a row here when
-- adding a module (see the README's "Adding a module").
local modules = {
  { 'netrw',        'gliter.netrw' },
  { 'undotree',     'gliter.undotree' },
  { 'multicursor',  'gliter.multicursor' },
  { 'treesitterRE', 'gliter.treesitterRE' },
  { 'zoom',         'gliter.zoom' },
  { 'ctags',        'gliter.ctags' },
  { 'make',         'gliter.make' },
  { 'repl',         'gliter.repl' },
  { 'textobj',      'gliter.textobj' },
  { 'sessions',     'gliter.sessions' },
  { 'readme',       'gliter.readme' },
  { 'justify',      'gliter.justify' },
  { 'move',         'gliter.move' },
  { 'matchit',      'gliter.matchit' },
  { 'tohtml',       'gliter.tohtml' },
  { 'w3',           'gliter.w3' },
  { 'cmd',          'gliter.cmd' },
  { 'which',        'gliter.which' },
  { 'screenkey',    'gliter.screenkey' },
  { 'pack',         'gliter.pack' },
}

---@param opts table? one entry per module: a table = that module's options,
---true = the module's defaults, false or nil = module not set up.
function M.setup(opts)
  vim.g.loaded_gliter = true -- keeps plugin/gliter.lua from double-loading
  opts = (type(opts) == 'table') and opts or {}

  for _, m in ipairs(modules) do
    local o = opts[m[1]]
    if o ~= nil and o ~= false then
      require(m[2]).setup(o == true and {} or o)
    end
  end

  vim.api.nvim_create_user_command('GliterVersion', M.version, {
    desc = 'gliter: what is loaded, from where — and any other gliter copy on the runtimepath',
  })

  return M
end

--- :GliterVersion — what is actually loaded, from where: gliter's
--- version, every loaded module with the file it came from, and every
--- OTHER copy of gliter found on the runtimepath. The first thing to
--- run when a key does not behave: a second, stale gliter somewhere
--- in the rtp is behind more misbehavior than any bug (its setup runs
--- last and its maps win); `:verbose omap i"` names the exact file
--- behind a map.
function M.version()
  local lines = {}
  for _, m in ipairs(modules) do
    local ok, mod = pcall(require, m[2])
    if ok and type(mod) == 'table' then
      local rel = ('lua/%s'):format(m[2]:gsub('%.', '/'))
      local found = vim.api.nvim_get_runtime_file(rel .. '.lua', false)
      if not (found and found[1]) then -- a directory module: gliter/x/init.lua
        found = vim.api.nvim_get_runtime_file(rel .. '/init.lua', false)
      end
      local path = (found and found[1]) or '?'
      lines[#lines + 1] = ('  %-13s %s'):format(m[1], path)
    end
  end
  if #lines == 0 then
    lines[#lines + 1] = '  (no gliter module loaded yet)'
  end
  local copies = vim.api.nvim_get_runtime_file('lua/gliter/init.lua', true)
  local extra = #copies - 1
  local head = ('gliter v%s — %d module%s loaded'):format(
    tostring(M._VERSION), #lines, #lines == 1 and '' or 's')
  if extra > 0 then
    head = head .. ('  !! %d other gliter cop%s on the runtimepath:'):format(
      extra, extra == 1 and 'y' or 'ies')
    for i, c in ipairs(copies) do
      if i > 1 then
        head = head .. '\n  ' .. vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(c)))
      end
    end
  end
  vim.api.nvim_echo(
    vim.tbl_map(function(l)
      return { l, 'None' }
    end, vim.list_extend({ head }, lines)),
    true, {}
  )
end

return M
