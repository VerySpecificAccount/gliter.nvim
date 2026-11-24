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

  -- Neovim 0.12 ships its own directory browser (augroup `nvim.dir`) that
  -- competes with netrw's `FileExplorer` autocmds: whichever runs first
  -- wins the directory, and nvim.dir yields a `directory` buffer that is
  -- not netrw at all — so nothing here (custom listing, keys, marks)
  -- applies and <CR> on a directory opens "old netrw". gliter.netrw is
  -- built on netrw, so it claims directories for it: make sure netrw's
  -- handlers exist (the plugin can be absent when the runtime's optional
  -- package was never added), then drop nvim.dir. No paths are hardcoded:
  -- `packadd` and `runtime!` resolve netrw wherever this Neovim keeps it.
  local function claim_directories()
    local function has_netrw_handlers()
      return vim.fn.exists('#FileExplorer#BufEnter') == 1
    end
    if not has_netrw_handlers() then
      pcall(vim.cmd, 'silent! packadd netrw') -- the optional package, if any
    end
    if not has_netrw_handlers() then
      -- the plugin file may have been skipped (g:loaded_netrwPlugin set
      -- without its autocmds, the snacks.explorer/oil.nvim style init
      -- line): clear the marker and source it again. g:loaded_netrw is
      -- cleared too — it guards the AUTOLOAD half (netrw#LocalBrowseCheck
      -- and friends), and without it every directory buffer would stay
      -- empty with E117 on its hook
      vim.g.loaded_netrwPlugin = nil
      vim.g.loaded_netrw = nil
      pcall(vim.cmd, 'silent! runtime! plugin/netrwPlugin.vim')
    end
    -- only drop nvim.dir when netrw can actually take over: never leave
    -- directories with no handler at all
    if has_netrw_handlers() then
      pcall(vim.api.nvim_del_augroup_by_name, 'nvim.dir')
    end
  end
  claim_directories()
  -- nvim.dir can be created after this setup runs (init.lua is read before
  -- the runtime's plugin/ files), and `nvim <dir>` opens its directory on
  -- VimEnter: claim again right before it
  vim.api.nvim_create_autocmd('VimEnter', {
    once = true,
    callback = claim_directories,
  })

  -- When a listing command is configured, plug `i` into netrw's own map
  -- installation via g:Netrw_UserMaps. netrw reads that list in
  -- s:NetrwMakeMaps and installs the entries AFTER its own maps on every
  -- browse — no race, no schedule, reinstalled automatically on every
  -- directory entry and relist. The global function is the target.
  if type(config.options.listing) == 'string' and config.options.listing ~= '' then
    local maps = vim.g.Netrw_UserMaps or {}
    -- idempotent: remove any prior gliter entry for 'i'
    maps = vim.tbl_filter(function(m) return m[1] ~= 'i' end, maps)
    table.insert(maps, { 'i', 'GliterNetrwCycleStyle' })
    vim.g.Netrw_UserMaps = maps

    _G.GliterNetrwCycleStyle = function(islocal)
      local win     = vim.api.nvim_get_current_win()
      local cur_buf = vim.api.nvim_get_current_buf()
      local style   = vim.w[win].netrw_liststyle or vim.g.netrw_liststyle or 0
      if vim.w[win].gliter_netrw_liststyle then
        -- custom slot → back to thin (0). Set false, not nil: nil means
        -- "never initialized" and listing_default would re-arm it on the
        -- next settle. false means "user explicitly left the custom slot".
        vim.w[win].gliter_netrw_liststyle = false
        vim.w[win].netrw_liststyle = 0
        require('gliter.netrw.custom').clear(cur_buf)
      elseif style >= 3 then
        -- tree (3) → custom slot
        vim.w[win].gliter_netrw_liststyle = true
        vim.w[win].netrw_liststyle = 0 -- keep thin for netrw root tracking
        vim.b[cur_buf].gliter_netrw_custom_tick = nil
        vim.b[cur_buf].gliter_netrw_settled_tick = nil
        local s = require('gliter.netrw')._settle
        if type(s) == 'function' then pcall(s, cur_buf) end
      else
        -- 0→1→2→3: let netrw do it; <Plug>NetrwRefresh with remap ('m')
        -- so the plug expands. Do NOT set netrw_liststyle ourselves here —
        -- netrw's s:NetrwListStyle does (w:netrw_liststyle+1)%MAXLIST and
        -- also updates g:netrw_list_cmd; duplicating that logic is lossy.
        local keys = vim.api.nvim_replace_termcodes('<Plug>NetrwRefresh', true, false, true)
        -- Advance the style first the way netrw's own function would, then
        -- refresh. We can't call s:NetrwListStyle (SNR varies), and
        -- netrw#NetrwListStyle doesn't exist as an autoload export.
        -- Setting the var + refreshing matches what that function does for
        -- the cases we care about (styles 0-2).
        vim.w[win].netrw_liststyle = style + 1
        vim.api.nvim_feedkeys(keys, 'm', false)
      end
    end

    vim.cmd([[
      function! GliterNetrwCycleStyle(islocal) abort
        call luaeval("_G.GliterNetrwCycleStyle(_A)", a:islocal)
        return ''
      endfunction
    ]])
  end

  local group = vim.api.nvim_create_augroup('GliterNetrw', { clear = true })
  local decor = require('gliter.netrw.decor')
  local keymaps = require('gliter.netrw.keymaps')

  decor.setup_highlights()
  local soft = require('gliter.netrw.soft')
  soft.apply_netrw()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = group,
    callback = function()
      decor.setup_highlights()
      soft.apply_netrw()
    end,
  })

  -- Marks are shared across windows and tabs, and (keep_marks, on by
  -- default) they FOLLOW the window that browses: `y` here, <CR> into a
  -- subdirectory, `p` pastes into the directory you are in. A refresh of
  -- the same directory — <C-l>, a sort, a style change — keeps them of
  -- course; keep_marks = false forgets them on a switch instead, so a
  -- stale set is never pasted into an unrelated directory. netrw gives
  -- every directory its own buffer (this buffer is wiped when you enter
  -- another one), so the switch is seen where the new buffer is
  -- announced: the window's previous netrw root.
  local listing = require('gliter.netrw.listing')
  local marks_mod = require('gliter.netrw.marks')
  local custom = require('gliter.netrw.custom')
  local function check_root_switch(buf)
    local ctx = listing.context(buf)
    if not ctx then
      return
    end
    local prev = vim.w[ctx.win].gliter_netrw_root
    vim.w[ctx.win].gliter_netrw_root = ctx.root
    if prev and prev ~= ctx.root and not config.options.keep_marks then
      marks_mod.clear()
    end
  end

  -- Everything that has to happen after netrw has (re-)listed a buffer:
  -- the custom listing re-renders (netrw rewrote the buffer under it),
  -- netrw's re-installed keys give way to the parser-driven ones again,
  -- and the marks decorate. Every step is guarded — a buffer nobody
  -- re-listed costs a changedtick compare — so this runs far more often
  -- than strictly needed, on purpose: netrw re-lists its buffers from
  -- more corners than its filetype announcements cover (entering a
  -- buffer again, gaining focus, its own refresh after a shell command),
  -- and a listing that survives them all is the point. Each step is
  -- also isolated: one of them failing (a listing command that misbehaves,
  -- a shape nobody planned for) must not take the keys or the marks
  -- down with it.
  ---@param buf integer
  local function settle(buf)
    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= 'netrw' then
      return
    end
    if vim.b[buf].gliter_netrw_editing then
      return -- edit mode owns the buffer (see edit.lua)
    end
    -- isolated: a context this code cannot parse must not take the keys or
    -- the marks down with it — a half-settled buffer is the one bug this
    -- plugin cannot afford (a netrw window without its keys)
    pcall(check_root_switch, buf)
    pcall(soft.apply_netrw)
    -- listing_default: arm the custom slot on first entry into every new
    -- window. The sentinel is tri-state: nil = never touched (arm it now
    -- if listing_default is set), true = custom slot active, false = user
    -- explicitly left the custom slot (do not re-arm — respect the choice).
    local ctx = listing.context(buf)
    if
      ctx
      and vim.w[ctx.win].gliter_netrw_liststyle == nil
      and config.options.listing_default == true
      and type(config.options.listing) == 'string'
      and config.options.listing ~= ''
    then
      vim.w[ctx.win].gliter_netrw_liststyle = true
    end
    -- Render the custom listing when the sentinel is true (armed by
    -- listing_default above, or by the user pressing `i` into the slot).
    if ctx and vim.w[ctx.win].gliter_netrw_liststyle == true then
      pcall(custom.render, buf)
    end
    pcall(keymaps.attach, buf)
    pcall(decor.watch, buf) -- the marks' own watcher, once per buffer
    pcall(decor.refresh, buf)
    -- the stamp: this exact listing (changedtick) has been settled. The
    -- SafeState net below compares it, so a settled buffer costs nothing
    -- and an unsettled one is caught wherever it came from.
    pcall(function()
      vim.b[buf].gliter_netrw_settled_tick = vim.b[buf].changedtick
    end)
  end
  -- for ops.open (the custom listing's <CR>): the settle that follows a
  -- directory browse runs RIGHT THERE, synchronously — not only on the
  -- schedule — so the very next key lands on the finished listing, its
  -- keys attached, instead of racing them
  M._settle = settle

  -- Everything that has to happen after netrw has (re-)listed a buffer
  -- runs once the redraw has gone quiet (see settle above): never
  -- mid-listing — a half-written buffer is not a listing to parse, its
  -- shapes are not the final ones, and parsing them is how a custom
  -- listing comes to look "unreadable".
  local settle_timers = {} ---@type table<integer, integer>
  ---@param buf integer
  local function settle_when_quiet(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if settle_timers[buf] then
      pcall(vim.fn.timer_stop, settle_timers[buf])
    end
    settle_timers[buf] = vim.fn.timer_start(50, function()
      settle_timers[buf] = nil
      settle(buf)
    end)
  end

  -- The watch itself: once per buffer, on its lines — every re-list
  -- rewrites them, whatever corner it came from, and the lines changing
  -- is the one signal all of those corners share. Our own renders fire
  -- it too; the guards turn that second pass into a no-op.
  ---@param buf integer
  local function watch(buf)
    -- deferred callers (the schedule below) can arrive after the buffer
    -- was wiped — netrw churns buffers on every browse — and vim.b[buf]
    -- on a dead id throws before anything can guard it
    if not vim.api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= 'netrw' then
      return
    end
    if vim.b[buf].gliter_netrw_settling then
      return
    end
    vim.b[buf].gliter_netrw_settling = true
    vim.api.nvim_buf_attach(buf, false, {
      on_lines = function()
        settle_when_quiet(buf)
      end,
      on_reload = function()
        settle_when_quiet(buf)
      end,
      on_detach = function()
        if settle_timers[buf] then
          pcall(vim.fn.timer_stop, settle_timers[buf])
          settle_timers[buf] = nil
        end
        -- A buffer that was unloaded (netrw `bd`s the ones it is not
        -- showing) can come back loaded with the flag still set — and
        -- watch() would take it for an attached one and never re-attach.
        -- Cleared here, the next announcement re-attaches the watch.
        pcall(function()
          if vim.api.nvim_buf_is_valid(buf) then
            vim.b[buf].gliter_netrw_settling = nil
          end
        end)
      end,
    })
  end

  -- A buffer that IS a directory but never became netrw's: plugins that
  -- open paths as plain buffers — a picker that bufadd()s the directory
  -- and switches to it (snacks.picker's jump action, and anything else
  -- built the same way) — can slip past netrw's FileExplorer hook when
  -- the switch happens with events quiet or ignored around it, and the
  -- window fills with an EMPTY buffer named after the directory. The
  -- invariant claimed here: a plain, unmodified, EMPTY buffer whose name
  -- is a directory is nobody's — netrw's own entry point
  -- (netrw#LocalBrowseCheck, the very function its BufEnter hook calls)
  -- takes it over and lists it, and the listing then announces FileType
  -- netrw, which settles the buffer — keys, marks, the custom listing —
  -- exactly as if the hook had run. Budgeted: a buffer that fails to
  -- convert three times is left alone until it is entered again.
  local adopt_tries = {} ---@type table<integer, integer>
  ---@param buf integer
  local function adopt_orphan_dir(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    -- LocalBrowseCheck lists into the CURRENT buffer alone, so the
    -- orphan is only adopted while it is the one on screen
    if vim.api.nvim_get_current_buf() ~= buf then
      return
    end
    if vim.bo[buf].filetype == 'netrw' or vim.bo[buf].buftype ~= '' then
      return -- netrw's already, or not a plain file buffer at all
    end
    if vim.b[buf].gliter_netrw_editing then
      return
    end
    if vim.bo[buf].modified or vim.api.nvim_buf_line_count(buf) ~= 1 then
      return -- something is in it, or was: it is somebody's buffer
    end
    local first = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
    if first ~= '' then
      return
    end
    local name = vim.api.nvim_buf_get_name(buf)
    if name == '' or vim.fn.isdirectory(name) ~= 1 then
      return
    end
    local tries = adopt_tries[buf] or 0
    if tries >= 3 then
      return
    end
    adopt_tries[buf] = tries + 1
    pcall(vim.fn['netrw#LocalBrowseCheck'], name)
    if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].filetype == 'netrw' then
      adopt_tries[buf] = nil -- converted: the budget comes back
    end
  end

  -- The announcements: the filetype (fresh buffers, style cycles, some
  -- re-lists) and the buffer/window being entered (netrw re-lists a
  -- buffer on entry whenever g:netrw_fastbrowse allows, and its own
  -- filetype does not always come back with that re-list). Deferred one
  -- event-loop turn so netrw has finished whatever it was doing first;
  -- the watch above catches anything the announcements still miss.
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'netrw',
    callback = function(args)
      vim.schedule(function()
        settle(args.buf)
        watch(args.buf)
      end)
    end,
  })
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = group,
    callback = function(args)
      -- The filetype is checked INSIDE the schedule, not here: this group
      -- is created before netrw loads, so on a fresh buffer it runs its
      -- BufEnter handler FIRST — before netrw's own FileExplorer handler
      -- has had its turn and set the filetype. Checked synchronously, a
      -- brand-new netrw buffer reads as ft="" and is never settled.
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(args.buf) then
          return
        end
        if vim.bo[args.buf].filetype == 'netrw' then
          settle(args.buf)
          watch(args.buf)
        else
          -- not netrw's (yet?): a directory that arrived as an empty
          -- plain buffer — the snacks.recent shape — is adopted here
          adopt_orphan_dir(args.buf)
        end
      end)
    end,
  })

  -- THE SAFETY NET. Everything above listens for announcements — the
  -- filetype, a buffer or window being entered, the lines changing. One
  -- path makes none: with g:netrw_fastbrowse at its default 2, netrw's
  -- buffer REUSE (browsing a directory whose buffer still exists) jumps
  -- to it under eventignore=all and skips the re-list entirely — no
  -- BufEnter, no FileType, not one line touched. No announcement, no
  -- settle — and whatever that buffer was, it stays that way. The
  -- same quiet is how a directory opened as a plain buffer (see
  -- adopt_orphan_dir) can sit on screen with no event at all.
  -- SafeState fires whenever Vim comes back to waiting for input, which
  -- is after every one of those silent paths has run its course: the
  -- buffer the keys land on is checked, and settled when its listing is
  -- not the one this plugin settled (the changedtick stamp) — or
  -- adopted, when it is an empty buffer named after a directory. The
  -- check is two option reads on a non-netrw buffer and a compare on a
  -- settled one — the net costs nothing when everything else worked.
  vim.api.nvim_create_autocmd('SafeState', {
    group = group,
    callback = function()
      pcall(function()
        local buf = vim.api.nvim_get_current_buf()
        if vim.bo[buf].filetype ~= 'netrw' then
          pcall(adopt_orphan_dir, buf)
          return
        end
        if vim.b[buf].gliter_netrw_editing then
          return
        end
        if vim.b[buf].gliter_netrw_settled_tick == vim.b[buf].changedtick then
          -- Tick matches last settle. The only case we still need to act on
          -- is fastbrowse buffer reuse with the custom slot active: netrw
          -- jumped here silently (eventignore=all, no re-list, no line change),
          -- the tick never moved, but the buffer shows plain netrw text because
          -- render never ran. The sentinel tells us whether the custom slot is
          -- selected; the gliter_netrw_custom flag tells us whether the custom
          -- text is actually in the buffer right now.
          local win = vim.api.nvim_get_current_win()
          if vim.w[win].gliter_netrw_liststyle == true and not vim.b[buf].gliter_netrw_custom then
            -- custom slot selected but text not showing: force a re-render
            pcall(function() vim.b[buf].gliter_netrw_custom_tick = nil end)
            pcall(function() vim.b[buf].gliter_netrw_settled_tick = nil end)
            -- fall through to settle()
          else
            return
          end
        end
        vim.schedule(function()
          settle(buf)
        end)
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
