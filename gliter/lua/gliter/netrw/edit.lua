--- In-place editing of a netrw listing.
---
--- `E` makes the CURRENT netrw buffer modifiable instead of opening a new window: add a
--- line to create a file (end it with `/` for a directory), delete a line to remove that
--- entry, edit a name in place to rename it. `:w` applies the diff to disk; `q` (or `E`
--- again, or any discard) cancels. Every ordinary Vim editing tool works on the listing
--- while it is open: macros, `:%s`, `<C-v>` block edits, `g<C-a>`...
---
--- One directory per edit session (the window's current netrw root).
--- Tree style mixes several directories into one buffer, so editing switches the window
--- to thin style (and hides the banner) for the duration and restores both afterwards.
---
--- Original entries are tracked with invisible extmarks, not line numbers, so they
--- follow the text through insertions and deletions exactly: a line that
--- keeps its mark but changes text is a rename, a mark that disappears (its line was
--- deleted) means delete, and any line with no mark is a new entry.
--- When the tracking itself is destroyed — netrw re-rendered the buffer —
--- plan() detects it (entries whose lines are still there, only unmarked)
--- and refuses to read it as delete-and-recreate: those pairs cancel, and
--- deletions that cannot be verified are skipped with a notice. A refresh
--- can at worst cancel an edit; it can never empty the files.
local config = require('gliter.netrw.config')
local fs = require('gliter.netrw.fs')
local marks = require('gliter.netrw.marks')
local netrw = require('gliter.netrw.listing')
local ui = require('gliter.netrw.ui')

local M = {}

local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

local ns = vim.api.nvim_create_namespace('gliter_netrw_edit') -- identity marks (invisible)
local mns = vim.api.nvim_create_namespace('gliter_netrw_edit_marks') -- copy/move/delete indicators

---@class GliterNetrwEditSession
---@field buf integer
---@field win integer
---@field ctx GliterNetrwCtx
---@field marks table<integer, GliterNetrwEntry>  extmark id -> original entry
---@field order GliterNetrwEntry[]                original entries, listing order
---@field group integer                         this session's augroup
---@field orig { modifiable: boolean, readonly: boolean, buftype: string, liststyle: integer, had_banner: boolean }
---@field saved_maps table[]                    buffer-local maps removed for editing
---@field pastes table<integer, { src: string, kind: 'copy'|'move' }>  identity marks of lines added by `p`
local active = {} ---@type table<integer, GliterNetrwEditSession>
local tmp_counter = 0

---------------------------------------------------------------------------
-- netrw's auto-refresh, suspended while a session runs
---------------------------------------------------------------------------

-- netrw re-lists its buffers behind Vim's back, which invalidates every
-- identity mark: the session would read the whole directory as "deleted,
-- and every line new". Two levers, both flipped for the duration of an
-- edit session:
--   * its AuNetrwEvent autocommands (FocusGained / ShellCmdPost →
--     LocalBrowseRefresh → every displayed netrw buffer re-listed) are
--     deleted — so much as switching the terminal window away and back
--     would otherwise rewrite the listing mid-edit. The whole *group* is
--     deleted, never the autocmds one by one: netrw installs them from
--     Vimscript, and `nvim_get_autocmds()` hands those back *without an
--     id*, so `nvim_del_autocmd(a.id)` fails on every one of them — a
--     previous version of this suspension therefore deleted nothing, and
--     :w after a focus change offered to delete and recreate the entire
--     directory. They are put back through netrw#Call, which resolves in
--     netrw's own script context, so the restored commands work whoever
--     recreated them.
--   * g:netrw_fastbrowse goes to 2: with the default 1 (or 0), netrw's
--     BufEnter (the FileExplorer group) re-browses every netrw buffer it
--     enters — same rewrite on every window/buffer switch. 2 makes it keep
--     the listing instead.
local AU = 'AuNetrwEvent'
---@type nil|{ fastbrowse: any, deleted: { event: string|string[], pattern: string, command: string }[] }
local saved_refresh = nil

local function suspend_netrw_refresh()
  if saved_refresh then
    return -- another edit session already holds the suspension
  end
  local deleted = {}
  local ok, list = pcall(vim.api.nvim_get_autocmds, { group = AU })
  if ok and type(list) == 'table' then
    for _, a in ipairs(list) do
      deleted[#deleted + 1] = {
        event = a.event,
        pattern = a.pattern or '*',
        command = a.command or '',
      }
    end
  end
  pcall(vim.api.nvim_del_augroup_by_name, AU)
  saved_refresh = { fastbrowse = vim.g.netrw_fastbrowse, deleted = deleted }
  vim.g.netrw_fastbrowse = 2
end

local function restore_netrw_refresh()
  local saved = saved_refresh
  if not saved then
    return
  end
  saved_refresh = nil
  if saved.fastbrowse == nil then
    vim.g.netrw_fastbrowse = nil -- it was unset before; let netrw default it again
  else
    vim.g.netrw_fastbrowse = saved.fastbrowse
  end
  -- netrw only installs those autocommands with fastbrowse <= 1; put them
  -- back only when there were some (a fastbrowse=2 setup never had them,
  -- and must not gain them from us).
  if #saved.deleted == 0 then
    return
  end
  pcall(vim.api.nvim_create_augroup, AU, { clear = false })
  for _, a in ipairs(saved.deleted) do
    -- `s:Func()` in the recorded command would resolve in *this* script's
    -- context once restored, not netrw's; netrw#Call runs it in netrw's own.
    local command = a.command ~= '' and a.command or 'call netrw#Call("LocalBrowseRefresh")'
    local fn = command:match('^%s*call%s+s:([%w#:.]+)%s*%(?')
    if fn then
      command = ('call netrw#Call("%s")'):format(fn)
    end
    pcall(vim.api.nvim_create_autocmd, a.event, {
      group = AU,
      pattern = a.pattern or '*',
      command = command,
    })
  end
end

local function trim(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

-- forward declaration: M.write recovers a re-rendered session with it, but
-- the definition needs paint_marks and netrw.context, defined further down
local resync_marks

--- A listing line turned back into a plain entry name: trimmed, trailing
--- `/` dropped, netrw's symlink target (`\t --> x`) dropped, and a trailing
--- decoration (`@` symlink, `*` executable, `|` fifo, `=` socket) dropped
--- when the name on disk is the undecorated one. A plain name is what the
--- clean listing carried, so this is how a line that netrw re-rendered
--- underneath the session compares against the tracked original.
---@param dir string
---@param line string
---@return string
local function plain_name(dir, line)
  local raw = trim((line:gsub('\t %-%->.*$', '')))
  raw = raw:gsub('/+$', '')
  if raw == '' or fs.exists(fs.join(dir, raw)) then
    return raw
  end
  return (raw:gsub('[@*|=]$', ''))
end

--- 0-based row of an identity mark, or nil when its line is gone. A mark whose whole span
--- was deleted (`dd`) is only hidden (`invalidate`), not removed, so it can still report a
--- position -- the line that slid up into its place. Treat that as deleted.
---@param buf integer
---@param id integer
---@return integer?
local function mark_row(buf, id)
  local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, buf, ns, id, { details = true })
  if not ok or not pos or not pos[1] then
    return nil
  end
  if pos[3] and pos[3].invalid then
    return nil
  end
  return pos[1]
end

---------------------------------------------------------------------------
-- rename ordering (handles swaps/cycles by parking one name under a temporary name)
---------------------------------------------------------------------------

local function tmp_name(dir)
  while true do
    tmp_counter = tmp_counter + 1
    local p = fs.join(dir, ('.gliter.netrw-tmp-%d-%d'):format(vim.uv.os_getpid(), tmp_counter))
    if not fs.exists(p) then
      return p
    end
  end
end

---@param renames { src: string, dst: string }[]
---@param dir string
local function order_renames(renames, dir)
  local steps, occupied, pending = {}, {}, {}
  for _, r in ipairs(renames) do
    occupied[r.src] = true
    pending[#pending + 1] = { cur = r.src, dst = r.dst }
  end
  while #pending > 0 do
    local progressed, rest = false, {}
    for _, op in ipairs(pending) do
      if not occupied[op.dst] then
        steps[#steps + 1] = { from = op.cur, to = op.dst }
        occupied[op.cur], occupied[op.dst] = nil, true
        progressed = true
      else
        rest[#rest + 1] = op
      end
    end
    pending = rest
    if #pending > 0 and not progressed then
      local op = pending[1]
      local tmp = tmp_name(dir)
      steps[#steps + 1] = { from = op.cur, to = tmp }
      occupied[op.cur], occupied[tmp] = nil, true
      op.cur = tmp
    end
  end
  return steps
end

--- Run rename steps; on failure, undo what already ran (best effort).
---@return boolean ok, string? err
local function execute_renames(steps)
  local done = {}
  for _, s in ipairs(steps) do
    local ok, err = fs.rename(s.from, s.to)
    if not ok then
      for i = #done, 1, -1 do
        fs.rename(done[i].to, done[i].from)
      end
      return false, err
    end
    done[#done + 1] = s
  end
  return true
end

---------------------------------------------------------------------------
-- plan: diff the buffer against the tracked original entries
---------------------------------------------------------------------------

---@class GliterNetrwEditPlan
---@field creates { path: string, is_dir: boolean, name: string }[]
---@field deletes GliterNetrwEntry[]
---@field renames { src: string, dst: string, from_name: string, to_name: string }[]
---@field pastes { src: string, kind: 'copy'|'move', name: string, dst: string }[]
---@field errors string[]
---@field paired integer  delete/create pairs dropped as no-ops (a re-render)
---@field skipped string[]  deletions not taken on destroyed tracking, by name

--- True when `name` is one of the entries the listing was built from.
---@param session GliterNetrwEditSession
---@param name string
---@return boolean
local function resulting_from_listing(session, name)
  for _, e in ipairs(session.order) do
    if e.name == name then
      return true
    end
  end
  return false
end

---@param session GliterNetrwEditSession
---@return GliterNetrwEditPlan
function M.plan(session)
  local buf, ctx = session.buf, session.ctx
  local creates, deletes, renames, errors = {}, {}, {}, {}
  local claimed = {}

  for id, entry in pairs(session.marks) do
    local row = mark_row(buf, id)
    if not row then
      deletes[#deletes + 1] = entry
    else
      claimed[row] = true
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
      local bare = plain_name(ctx.root, line)
      if bare == '' then
        deletes[#deletes + 1] = entry
      elseif bare ~= entry.name then
        if bare:find('/', 1, true) then
          errors[#errors + 1] =
            ('"%s" -> "%s": renaming cannot move into another directory (use %s to move).'):format(
              entry.name,
              bare,
              config.options.keys and config.options.keys.move or 'move'
            )
        elseif bare == '.' or bare == '..' then
          errors[#errors + 1] = ('"%s": "%s" is not a valid name.'):format(entry.name, bare)
        else
          renames[#renames + 1] =
            { src = entry.path, dst = fs.join(ctx.root, bare), from_name = entry.name, to_name = bare }
        end
      end
    end
  end

  -- Lines added by `p`: copied or moved from their source when saved.
  local paste_list = {}
  for id, p in pairs(session.pastes) do
    local row = mark_row(buf, id)
    if row then
      claimed[row] = true
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
      local bare = plain_name(ctx.root, line)
      if bare ~= '' then
        if bare:find('/', 1, true) or bare == '.' or bare == '..' then
          errors[#errors + 1] = ('"%s": a pasted entry needs a plain name.'):format(bare)
        else
          paste_list[#paste_list + 1] = { src = p.src, kind = p.kind, name = bare, dst = fs.join(ctx.root, bare) }
        end
      end
    end
  end

  local last = vim.api.nvim_buf_line_count(buf)
  for row = ctx.first - 1, last - 1 do
    if not claimed[row] then
      local raw = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
      local line = trim((raw:gsub('\t %-%->.*$', '')))
      local bare = plain_name(ctx.root, raw)
      if line ~= '' and bare ~= '' and bare ~= '.' and bare ~= '..' then
        local bad = false
        if bare:sub(1, 1) == '/' or bare:sub(1, 1) == '~' then
          errors[#errors + 1] = ('"%s": give a name relative to %s'):format(line, ctx.root)
          bad = true
        end
        for seg in bare:gmatch('[^/]+') do
          if seg == '.' or seg == '..' then
            errors[#errors + 1] = ('"%s": "." and ".." are not allowed in names.'):format(line)
            bad = true
            break
          end
        end
        if not bad then
          creates[#creates + 1] = { path = fs.join(ctx.root, bare), is_dir = line:sub(-1) == '/', name = bare }
        end
      end
    end
  end

  -- A create that carries the name of a deleted entry is not a change at all:
  -- the line is still in the listing, only its identity mark was lost — which
  -- is what a netrw re-render of the buffer looks like (every mark wiped,
  -- every line reading as brand-new), and also what `dd` followed by retyping
  -- the same name looks like. Neither may pass as "delete the file, then
  -- create an empty one over it": the pairs are dropped as no-ops, so the
  -- worst a re-render can do is cancel the edit — never empty the files.
  local paired = 0
  local skipped = {}
  local deleted_named = {}
  for _, e in ipairs(deletes) do
    deleted_named[e.name] = false
  end
  if next(deleted_named) then
    local kept_creates = {}
    for _, c in ipairs(creates) do
      if deleted_named[c.name] ~= nil then
        deleted_named[c.name] = true
        paired = paired + 1
      else
        kept_creates[#kept_creates + 1] = c
      end
    end
    creates = kept_creates
    local kept_deletes = {}
    for _, e in ipairs(deletes) do
      if not deleted_named[e.name] then
        kept_deletes[#kept_deletes + 1] = e
      end
    end
    deletes = kept_deletes
  end
  -- Same evidence, wider blast radius: once a same-name pair shows the
  -- tracking was destroyed, NO invalid mark proves a deletion anymore. A
  -- deletion is the one irreversible act in the plan, so those whose files
  -- still sit on disk are not taken on that evidence — they are skipped and
  -- reported, and the user re-states them (E, dd, :w) if they were meant.
  if paired > 0 then
    local kept_deletes = {}
    for _, e in ipairs(deletes) do
      if fs.exists(e.path) then
        skipped[#skipped + 1] = e.name
      else
        kept_deletes[#kept_deletes + 1] = e
      end
    end
    deletes = kept_deletes
  end

  if #errors == 0 then
    local resulting = {}
    for _, e in ipairs(session.order) do
      resulting[e.name] = true
    end
    for _, e in ipairs(deletes) do
      resulting[e.name] = nil
    end
    for _, r in ipairs(renames) do
      resulting[r.from_name] = nil
    end
    local function claim(name, label)
      if resulting[name] then
        errors[#errors + 1] = ('"%s" already exists or is claimed twice (%s).'):format(name, label)
      end
      resulting[name] = true
    end
    for _, r in ipairs(renames) do
      claim(r.to_name, 'rename')
      -- Not in the listing (e.g. hidden) but on disk: fs.rename would overwrite it.
      if not resulting_from_listing(session, r.to_name) and fs.exists(r.dst) then
        errors[#errors + 1] = ('"%s" already exists on disk.'):format(r.to_name)
      end
    end
    -- A name a rename frees may be recreated in the same plan (rename x to y,
    -- then add a new x); anything else that exists on disk must not pass
    -- validation — fs.touch refuses to truncate, but catching it here keeps
    -- the plan from half-applying (deletes and renames first, the create
    -- failing only after they have run).
    local freed = {}
    for _, r in ipairs(renames) do
      freed[r.from_name] = true
    end
    for _, c in ipairs(creates) do
      claim(c.name, 'new')
      if fs.exists(c.path) and not freed[c.name] then
        errors[#errors + 1] = ('"%s" already exists on disk.'):format(c.name)
      end
    end
    for _, p in ipairs(paste_list) do
      claim(p.name, 'paste')
      if not resulting_from_listing(session, p.name) and fs.exists(p.dst) then
        errors[#errors + 1] = ('"%s" already exists on disk.'):format(p.name)
      end
    end
  end

  return { creates = creates, deletes = deletes, renames = renames, pastes = paste_list, errors = errors, paired = paired, skipped = skipped }
end

---------------------------------------------------------------------------
-- apply
---------------------------------------------------------------------------

---@class GliterNetrwEditResult
---@field created string[]
---@field renamed { from: string, to: string }[]
---@field deleted string[]
---@field failed { path: string, op: string, err: string }[]

---@param plan GliterNetrwEditPlan
---@param ctx GliterNetrwCtx
---@return GliterNetrwEditResult
function M.apply(plan, ctx)
  local res = { created = {}, renamed = {}, deleted = {}, failed = {}, pasted = {} }

  for _, e in ipairs(plan.deletes) do
    local ok, err = fs.remove(e.path)
    if ok then
      res.deleted[#res.deleted + 1] = e.path
      marks.remove({ e.path })
    else
      res.failed[#res.failed + 1] = { path = e.path, op = 'delete', err = tostring(err) }
    end
  end

  if #plan.renames > 0 then
    local steps = order_renames(plan.renames, ctx.root)
    local ok, err = execute_renames(steps)
    if ok then
      for _, r in ipairs(plan.renames) do
        res.renamed[#res.renamed + 1] = { from = r.src, to = r.dst }
        marks.rename(r.src, r.dst)
      end
    else
      for _, r in ipairs(plan.renames) do
        res.failed[#res.failed + 1] = { path = r.src, op = 'rename', err = tostring(err) }
      end
    end
  end

  for _, c in ipairs(plan.creates) do
    local ok, err
    if c.is_dir then
      ok, err = fs.mkdirp(c.path)
    else
      ok, err = fs.mkdirp(fs.dirname(c.path))
      if ok then
        ok, err = fs.touch(c.path)
      end
    end
    if ok then
      res.created[#res.created + 1] = c.path
    else
      res.failed[#res.failed + 1] = { path = c.path, op = 'create', err = tostring(err) }
    end
  end

  for _, p in ipairs(plan.pastes or {}) do
    local ok, err
    if p.kind == 'copy' then
      ok, err = fs.copy(p.src, p.dst)
    else
      ok, err = fs.rename(p.src, p.dst)
      if not ok then
        -- Different filesystem: copy, then remove the source.
        ok, err = fs.copy(p.src, p.dst)
        if ok then
          ok, err = fs.remove(p.src)
        end
      end
    end
    if ok then
      res.pasted[#res.pasted + 1] = p
      marks.remove({ p.src })
    else
      res.failed[#res.failed + 1] = { path = p.src, op = p.kind, err = tostring(err) }
    end
  end

  return res
end

---------------------------------------------------------------------------
-- confirm / write / cancel
---------------------------------------------------------------------------

---@param plan GliterNetrwEditPlan
local function confirm_plan(plan)
  local total = #plan.creates + #plan.renames + #plan.deletes + #plan.pastes
  local lines, max = {}, 10
  local function add(s)
    if #lines < max then
      lines[#lines + 1] = s
    elseif #lines == max then
      lines[#lines + 1] = '…'
    end
  end
  for _, p in ipairs(plan.pastes) do
    add(('%s +%s'):format(p.kind, p.name))
  end
  for _, c in ipairs(plan.creates) do
    add(('+ %s%s'):format(c.name, c.is_dir and '/' or ''))
  end
  for _, r in ipairs(plan.renames) do
    add(('~ %s -> %s'):format(r.from_name, r.to_name))
  end
  for _, d in ipairs(plan.deletes) do
    add(('- %s%s'):format(d.name, d.is_dir and '/' or ''))
  end
  local msg = ('Apply %d change%s?\n\n%s'):format(total, total == 1 and '' or 's', table.concat(lines, '\n'))
  return ui.yes_no(msg)
end

---@param buf integer
---@param opts? { refresh_dirs: boolean, reveal: { win: integer, path: string } }
local function finish(buf, opts)
  local session = active[buf]
  if not session then
    return
  end
  active[buf] = nil

  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    vim.bo[buf].modifiable = session.orig.modifiable
    vim.bo[buf].readonly = session.orig.readonly
    vim.bo[buf].buftype = session.orig.buftype
    vim.bo[buf].modified = false
    vim.b[buf].gliter_netrw_editing = nil
  end
  pcall(vim.api.nvim_del_augroup_by_id, session.group)
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_del_user_command, buf, 'GliterNetrwWrite')
    pcall(vim.keymap.del, 'ca', 'w', { buffer = buf })
  end
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, mns, 0, -1)
    local km = config.options.keys or {}
    for _, lhs in ipairs({ km.yank, km.paste, km.yank_all, km.clear, km.edit_cancel }) do
      if lhs then
        pcall(vim.keymap.del, 'n', lhs, { buffer = buf })
        pcall(vim.keymap.del, 'x', lhs, { buffer = buf })
      end
    end
  end
  -- Put back every buffer-local map that was removed for editing (netrw's and ours).
  pcall(function()
    require('gliter.netrw.keymaps').restore(buf, session.saved_maps)
  end)

  local win = session.win
  if vim.api.nvim_win_is_valid(win) then
    if session.orig.liststyle ~= netrw.THIN then
      vim.w[win].netrw_liststyle = session.orig.liststyle
    end
    -- (the banner: g:netrw_banner was never touched, so the refresh
    -- below re-lists with it, exactly as it was)
  end

  -- Put the suspension back *before* refreshing: netrw's listing code reads
  -- g:netrw_fastbrowse while it renders (bufhidden, auto-refresh setup).
  if not next(active) then
    restore_netrw_refresh()
  end

  if opts and opts.refresh_dirs then
    netrw.refresh_dirs(opts.dirs or { session.ctx.root }, opts.reveal)
  elseif vim.api.nvim_win_is_valid(win) then
    netrw.refresh_win(win)
  end
end

--- Cancel the edit session, discarding any in-buffer changes.
---@param buf integer
function M.cancel(buf)
  local session = active[buf]
  if not session then
    return
  end
  if vim.bo[buf].modified then
    if not ui.yes_no('Discard edits to this listing?') then
      return
    end
  end
  finish(buf)
  ui.notify('Edit cancelled.')
end

---@param buf integer
function M.write(buf)
  local session = active[buf]
  if not session then
    return
  end
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  local plan = M.plan(session)
  if #plan.errors > 0 then
    for _, e in ipairs(plan.errors) do
      ui.notify(e, ERROR)
    end
    return
  end
  if #plan.creates == 0 and #plan.deletes == 0 and #plan.renames == 0 and #plan.pastes == 0 then
    vim.bo[buf].modified = false
    if (plan.paired or 0) > 0 or #(plan.skipped or {}) > 0 then
      -- nothing real changed, yet entries had lost their tracking marks: the
      -- listing was re-rendered underneath the session. Re-attach the marks
      -- and stay in it — the buffer keeps its (pending) edits.
      resync_marks(session)
      ui.notify('The listing was refreshed underneath the edit; nothing changed on disk. Editing on.')
      return
    end
    ui.notify('No changes.')
    finish(buf)
    return
  end
  if config.options.edit.confirm and not confirm_plan(plan) then
    return
  end

  local res = M.apply(plan, session.ctx)
  vim.bo[buf].modified = false
  if (plan.paired or 0) > 0 then
    ui.notify(('%d entries re-appeared without their tracking mark (the listing was refreshed); left untouched.'):format(plan.paired))
  end
  if #(plan.skipped or {}) > 0 then
    ui.notify(('Deletions not verifiable after the refresh, left untouched: %s.'):format(table.concat(plan.skipped, ', ')), WARN)
  end
  -- A confirmed write consumes the whole clipboard: every mark is cleared,
  -- not just the ones this write executed — the listing on disk is the truth
  -- now, and leftover [copy]/[move] tags would point at stale intents.
  marks.clear()

  local copied, moved = 0, 0
  for _, p in ipairs(res.pasted) do
    if p.kind == 'copy' then
      copied = copied + 1
    else
      moved = moved + 1
    end
  end
  local parts = {}
  if #res.created > 0 then
    parts[#parts + 1] = ('created %d'):format(#res.created)
  end
  if copied > 0 then
    parts[#parts + 1] = ('copied %d'):format(copied)
  end
  if moved > 0 then
    parts[#parts + 1] = ('moved %d'):format(moved)
  end
  if #res.renamed > 0 then
    parts[#parts + 1] = ('renamed %d'):format(#res.renamed)
  end
  if #res.deleted > 0 then
    parts[#parts + 1] = ('deleted %d'):format(#res.deleted)
  end
  if #parts > 0 then
    ui.notify(table.concat(parts, ', ') .. '.')
  end
  for i, f in ipairs(res.failed) do
    if i > 3 then
      ui.notify(('…and %d more errors.'):format(#res.failed - 3), ERROR)
      break
    end
    ui.notify(('%s (%s): %s'):format(fs.basename(f.path), f.op, f.err), ERROR)
  end

  local dirs = { session.ctx.root }
  for _, p in ipairs(res.pasted) do
    if p.kind == 'move' then
      dirs[#dirs + 1] = fs.dirname(p.src)
    end
  end
  local reveal_path = res.created[1]
    or (res.renamed[1] and res.renamed[1].to)
    or (res.pasted[1] and res.pasted[1].dst)
    or nil
  finish(buf, {
    refresh_dirs = true,
    dirs = dirs,
    reveal = reveal_path and { win = session.win, path = reveal_path } or nil,
  })
end

--- Original entry whose identity mark is still on `row` (0-based), if any.
---@param session GliterNetrwEditSession
---@param row integer
---@return GliterNetrwEntry?
local function entry_on_row(session, row)
  for id, entry in pairs(session.marks) do
    if mark_row(session.buf, id) == row then
      return entry
    end
  end
  return nil
end

--- Original entries whose identity mark is still in the buffer (not deleted with `dd`).
---@param session GliterNetrwEditSession
---@return GliterNetrwEntry[]
local function live_originals(session)
  local out = {}
  for id, entry in pairs(session.marks) do
    if mark_row(session.buf, id) then
      out[#out + 1] = entry
    end
  end
  return out
end

--- Lines added by `p` that are still in the buffer.
---@param session GliterNetrwEditSession
---@return { id: integer, p: { src: string, kind: 'copy'|'move' }, row: integer }[]
local function live_pastes(session)
  local out = {}
  for id, p in pairs(session.pastes) do
    local row = mark_row(session.buf, id)
    if row then
      out[#out + 1] = { id = id, p = p, row = row }
    end
  end
  return out
end

--- Identity mark of a line added by `p`, if one sits on `row` (0-based).
---@param session GliterNetrwEditSession
---@param row integer
---@return integer?
local function paste_on_row(session, row)
  for _, lp in ipairs(live_pastes(session)) do
    if lp.row == row then
      return lp.id
    end
  end
  return nil
end

--- Show the copy/move/delete indicator next to every marked original entry and every line
--- added by `p`.
---@param session GliterNetrwEditSession
local function paint_marks(session)
  local buf = session.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, mns, 0, -1)
  local function tag(row, kind)
    local indicator = kind and config.options.indicators[kind]
    if indicator then
      pcall(vim.api.nvim_buf_set_extmark, buf, mns, row, 0, {
        virt_text = { { indicator, 'GliterNetrwIndicator' } },
        virt_text_pos = 'eol',
      })
    end
  end
  local claimed = {}
  for id, entry in pairs(session.marks) do
    local row = mark_row(buf, id)
    if row then
      claimed[row] = true
      tag(row, marks.kind(entry.path))
    end
  end
  for _, lp in ipairs(live_pastes(session)) do
    claimed[lp.row] = true
    tag(lp.row, lp.p.kind == 'copy' and 'copied' or 'moved')
  end
  -- Any other non-blank line is a brand-new entry (created on `:w`) — unless
  -- it merely repeats an original entry's name. That is what every line looks
  -- like after netrw re-rendered the buffer underneath the session (each
  -- identity mark lost, the whole directory reading as "new"); a name the
  -- directory already has is not a creation, and flagging a whole listing
  -- `[new]` after a focus change reads as exactly the catastrophe `:w` must
  -- never perform. (plan() still refuses such lines as claimed twice.)
  local originals = {}
  for _, e in ipairs(session.order) do
    originals[e.name] = true
  end
  for row = session.ctx.first - 1, vim.api.nvim_buf_line_count(buf) - 1 do
    if not claimed[row] then
      local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
      local bare = plain_name(session.ctx.root, line)
      if bare ~= '' and bare ~= '.' and bare ~= '..' and not originals[bare] then
        tag(row, 'new')
      end
    end
  end
end

--- Re-attach identity marks after netrw re-rendered the buffer underneath the
--- session (a refresh that got past the suspension): every mark is gone, but
--- the entries are still there as plain lines. A line whose name matches an
--- original entry becomes that entry again, so pending edits — renames,
--- deletions, new lines — survive the refresh instead of reading as
--- delete-everything/create-everything. Lines added by `p` cannot be told
--- apart anymore: they stay as plain (create) lines.
---@param session GliterNetrwEditSession
function resync_marks(session)
  local buf = session.buf
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local fresh = netrw.context(buf, session.win)
  if fresh then -- the banner may have come back: follow the new first line
    session.ctx = fresh
  end
  local by_name = {}
  for _, e in ipairs(session.order) do
    by_name[e.name] = by_name[e.name] or e
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local new_marks = {}
  local last = vim.api.nvim_buf_line_count(buf)
  for row = session.ctx.first - 1, last - 1 do
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ''
    local bare = plain_name(session.ctx.root, line)
    local e = bare ~= '' and by_name[bare] or nil
    if e then
      by_name[bare] = nil -- one line per entry: a duplicate stays unclaimed
      local id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
        end_row = row,
        end_col = #line,
        right_gravity = true,
        end_right_gravity = true,
        invalidate = true,
        undo_restore = true,
      })
      new_marks[id] = e
    end
  end
  session.marks = new_marks
  session.pastes = {}
  paint_marks(session)
  return true
end

--- Repaint the hints after any text change, so a hint never lingers on (or slides onto)
--- the wrong line after `dd`, `o`, undo, etc.
---@param session GliterNetrwEditSession
local function watch_text(session)
  local buf, scheduled = session.buf, false
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if active[buf] ~= session then
        return true -- session over: detach
      end
      if not scheduled then
        scheduled = true
        vim.schedule(function()
          scheduled = false
          if active[buf] == session then
            paint_marks(session)
          end
        end)
      end
    end,
  })
end

--- Mark (`kind`) the original entry on the cursor line, or on every line of `range`.
--- Works inside edit mode because the listing lines keep their identity marks.
--- A line added by `p` (tagged [copied]/[moved]) is pending, not an entry: pressing the key
--- again cancels it, by removing that line.
---@param buf integer
---@param kind GliterNetrwMarkKind
---@param range? integer[]  {first, last}, 1-based
function M.mark(buf, kind, range)
  local session = active[buf]
  if not session then
    return
  end
  local first, last
  if range then
    first, last = range[1], range[2]
  else
    first = vim.api.nvim_win_get_cursor(session.win)[1]
    last = first
  end

  local paths, pending = {}, {}
  for row = first - 1, last - 1 do
    local pid = paste_on_row(session, row)
    if pid then
      pending[#pending + 1] = { id = pid, row = row }
    else
      local entry = entry_on_row(session, row)
      if entry then
        paths[#paths + 1] = entry.path
      end
    end
  end
  if #paths == 0 and #pending == 0 then
    return ui.notify('No original entry on this line.', WARN)
  end

  -- Remove pending lines bottom-up, so the rows still to be removed keep their numbers.
  table.sort(pending, function(a, b)
    return a.row > b.row
  end)
  for _, pe in ipairs(pending) do
    vim.api.nvim_buf_set_lines(buf, pe.row, pe.row + 1, false, {})
    session.pastes[pe.id] = nil
  end

  if #paths > 0 then
    marks.toggle(kind, paths)
  end
  paint_marks(session)

  if #paths == 0 then
    return ui.notify('Cancelled pending paste.')
  end
  if not range and last < vim.api.nvim_buf_line_count(buf) then
    vim.api.nvim_win_set_cursor(session.win, { last + 1, 0 })
  end
  local status = marks.status()
  ui.notify(status ~= '' and ('Marked: ' .. status) or 'No marks.')
end

--- Toggle the copy mark on every original entry in the listing (Y, same as normal mode):
--- unmarks them all if they already carry it, otherwise marks them all.
---@param buf integer
function M.mark_all(buf)
  local session = active[buf]
  if not session then
    return
  end
  local paths = vim.tbl_map(function(e)
    return e.path
  end, live_originals(session))
  if #paths == 0 then
    return ui.notify('Nothing to mark: the listing is empty.', WARN)
  end
  marks.toggle_all('copy', paths)
  paint_marks(session)
  local status = marks.status()
  ui.notify(status ~= '' and ('Marked: ' .. status) or 'No marks.')
end

--- Esc inside edit mode: clear every mark. Lines already added by `p` stay pending.
---@param buf integer
function M.clear_marks(buf)
  local session = active[buf]
  if not session then
    return
  end
  marks.clear()
  paint_marks(session)
  ui.notify('Marks cleared.')
end

--- Name for a copy of `base` that `is_free` accepts: `foo_copy.txt`, then `foo_copy_2.txt`.
--- Directories have no extension to keep: `dir` -> `dir_copy`.
---@param base string
---@param is_dir boolean
---@param is_free fun(name: string): boolean
---@return string
local function copy_name(base, is_dir, is_free)
  local stem, ext = base, ''
  if not is_dir then
    local a, b = base:match('^(.+)(%.[^.]+)$')
    if a then
      stem, ext = a, b
    end
  end
  local i = 1
  while true do
    local cand = i == 1 and (stem .. '_copy' .. ext) or ('%s_copy_%d%s'):format(stem, i, ext)
    if is_free(cand) then
      return cand
    end
    i = i + 1
  end
end

--- `p` inside edit mode: add the copy/move-marked entries as new lines below the
--- cursor. They are copied or moved when the listing is saved with `:w`. A copy whose
--- name is already taken here (e.g. `file` copied within its own directory) becomes
--- `file_copy` — and pasting the same entry again takes the next free name:
--- `file_copy_2`, `file_copy_3`, ...
---@param buf integer
function M.paste(buf)
  local session = active[buf]
  if not session then
    return
  end
  local ctx = session.ctx

  local sources = {}
  local any = false
  for _, kind in ipairs({ 'copy', 'move' }) do
    for _, path in ipairs(marks.list(kind)) do
      any = true
      sources[#sources + 1] = { path = path, kind = kind }
    end
  end
  if not any then
    return ui.notify('Nothing to paste. Mark with y (copy) or m (move) first.', WARN)
  end

  -- A new line may not reuse a name already in this listing or on disk.
  local taken = {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    local name = (trim(line):gsub('/+$', ''))
    if name ~= '' then
      taken[name] = true
    end
  end
  local function is_free(name)
    return not taken[name] and not fs.exists(fs.join(ctx.root, name))
  end

  local names = {}
  for i, s in ipairs(sources) do
    local base = fs.basename(s.path)
    local bare = base
    if s.kind == 'copy' and not is_free(bare) then
      bare = copy_name(bare, fs.is_dir(s.path), is_free)
    end
    taken[bare] = true
    -- Directories keep the trailing `/` the listing shows for them, so the
    -- pending line reads as the directory it is.
    names[i] = fs.is_dir(s.path) and (bare .. '/') or bare
  end

  local row = vim.api.nvim_win_get_cursor(session.win)[1] -- 1-based; new lines go after it
  vim.api.nvim_buf_set_lines(buf, row, row, false, names)
  for i, s in ipairs(sources) do
    local r = row + i - 1 -- 0-based row of the new line
    local id = vim.api.nvim_buf_set_extmark(buf, ns, r, 0, {
      end_row = r,
      end_col = #names[i],
      right_gravity = true,
      end_right_gravity = true,
      invalidate = true,
      undo_restore = true,
    })
    session.pastes[id] = { src = s.path, kind = s.kind }
  end
  -- The marks have done their job — their lines now show [copied]/[moved]
  -- instead of [copy]/[move]. Cancelling a pending line (the mark key on it)
  -- drops the paste; re-marking pastes it somewhere else.
  marks.remove(vim.tbl_map(function(s)
    return s.path
  end, sources))
  paint_marks(session)
  ui.notify(('Added %d line%s. :w to copy or move.'):format(#sources, #sources == 1 and '' or 's'))
end

--- Start in-place editing of `ctx`'s directory.
---@param ctx GliterNetrwCtx
function M.start(ctx)
  local buf, win = ctx.buf, ctx.win
  if active[buf] then
    return
  end
  if ctx.style == netrw.TREE then
    return ui.notify('In-place editing needs a flat listing; tree style is not supported.', WARN)
  end

  -- The entry under the cursor when E was pressed, captured BEFORE the
  -- style switch and the clean re-render below: both shift line numbers,
  -- so the cursor is put back on the SAME entry afterwards, not left
  -- clamped to whatever line its old number happens to be now.
  local keep_path = nil
  do
    local e0 = netrw.entry_at_cursor(ctx)
    if e0 then
      keep_path = e0.path
    end
  end

  local orig_liststyle = ctx.style
  if ctx.style ~= netrw.THIN then
    vim.w[win].netrw_liststyle = netrw.THIN
    netrw.refresh_win(win)
    -- A refresh can hand the window a fresh buffer altogether (netrw's
    -- own re-list does that on argv/arglist listings): adopt whichever
    -- buffer the window ends up showing, or the session below would
    -- edit a buffer nobody looks at.
    buf = vim.api.nvim_win_get_buf(win)
  end

  local fresh = netrw.context(buf, win)
  if not fresh then
    vim.w[win].netrw_liststyle = orig_liststyle
    return ui.notify('Could not start editing: lost netrw context.', ERROR)
  end
  ctx = fresh

  local orig = {
    modifiable = vim.bo[buf].modifiable,
    readonly = vim.bo[buf].readonly,
    buftype = vim.bo[buf].buftype,
    liststyle = orig_liststyle,
    had_banner = ctx.first > 1,
  }

  vim.b[buf].gliter_netrw_editing = true -- set early: guards other buffer-text watchers below
  -- netrw marks its listing `readonly`; clear that too, or writing the listing text
  -- raises "W10: Changing a readonly file".
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true

  -- The banner goes away in place — NOT through netrw's own I (banner
  -- toggle): that one re-lists via :e, and a re-list can swap the window
  -- onto a different buffer (argv listings, :args directories), which is
  -- how an edit session used to lose its context before starting. The
  -- listing after the session (the refresh in finish) brings the banner
  -- back on its own: g:netrw_banner was never touched.
  if orig.had_banner then
    vim.api.nvim_buf_set_lines(buf, 0, ctx.first - 1, false, {})
    ctx.first = 1
  end

  local entries = netrw.all(ctx)

  -- Re-render as a clean, undecorated listing: just the name, with a trailing `/` for
  -- directories. netrw's own thin-style text marks symlinks/executables/fifos/sockets
  -- with a trailing `@`/`*`/`|`/`=`, which would make an untouched entry look "renamed"
  -- the moment it's compared back against its plain name; and a plain name is just
  -- easier to edit.
  local clean = {}
  for i, e in ipairs(entries) do
    clean[i] = e.name .. (e.is_dir and '/' or '')
  end
  vim.api.nvim_buf_set_lines(buf, ctx.first - 1, -1, false, clean)
  if keep_path then
    for i, e in ipairs(entries) do
      if e.path == keep_path then
        vim.api.nvim_win_call(win, function()
          vim.api.nvim_win_set_cursor(win, { ctx.first - 1 + i, 0 })
        end)
        break
      end
    end
  end

  -- Track each entry with a span over its own (now-clean) line, invalidated when that
  -- span is fully deleted -- e.g. by `dd` removing the whole line -- so a deletion is
  -- unambiguous, while editing the text in place (a rename, even retyping the whole
  -- name) keeps the mark anchored to its line.
  local marks, order = {}, {}
  for i, e in ipairs(entries) do
    local row = ctx.first - 1 + i - 1
    local id = vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      end_row = row,
      end_col = #clean[i],
      -- right_gravity: an insertion at the mark's own position (e.g. `O` above it) pushes the
      -- mark down with its line instead of leaving it on the new, unrelated line.
      right_gravity = true,
      end_right_gravity = true,
      invalidate = true,
      undo_restore = true,
    })
    marks[id] = e
    order[#order + 1] = e
  end

  local group = vim.api.nvim_create_augroup(('GliterNetrwEdit%d'):format(buf), { clear = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = buf,
    callback = function()
      M.write(buf)
    end,
  })
  -- The buffer leaving without a write (a `:bd`, a wipe from elsewhere)
  -- must not leave the refresh suspended for the rest of the session.
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    group = group,
    buffer = buf,
    callback = function()
      if active[buf] then
        active[buf] = nil
        if not next(active) then
          restore_netrw_refresh()
        end
      end
    end,
  })

  -- `:w` with a filename argument (`:w newfile`) does not fire BufWriteCmd for this buffer;
  -- route it to the same apply step instead of letting Vim try to write a nameless buffer.
  vim.api.nvim_buf_create_user_command(buf, 'GliterNetrwWrite', function()
    M.write(buf)
  end, { nargs = '*', bang = true })
  vim.keymap.set('ca', 'w', function()
    if vim.fn.getcmdtype() == ':' and vim.fn.getcmdline():match('^%s*w$') then
      return 'GliterNetrwWrite'
    end
    return 'w'
  end, { buffer = buf, expr = true, silent = true })

  -- netrw re-lists (and so re-locks) its buffer on window/buffer events; keep it writable
  -- for as long as the edit session is active.
  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter', 'CursorHold', 'FocusGained' }, {
    group = group,
    buffer = buf,
    callback = function()
      if active[buf] then
        vim.bo[buf].readonly = false
        vim.bo[buf].modifiable = true
      end
    end,
  })

  active[buf] = { buf = buf, win = win, ctx = ctx, marks = marks, order = order, group = group, orig = orig, pastes = {} }
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].modified = false

  -- netrw's auto-refresh (BufEnter on buffer switches, FocusGained when the
  -- terminal window changes) would re-list the buffer mid-edit; hold it off
  -- for as long as the session runs.
  suspend_netrw_refresh()

  -- Remove every netrw / gliter.netrw buffer-local key so Vim's own keys work in the listing;
  -- `finish` restores them.
  active[buf].saved_maps = require('gliter.netrw.keymaps').suspend(buf)

  -- Copy-mark (y, Y), apply (p) and clear (Esc) also work in edit mode. m and d keep Vim's meaning here
  -- (`dd` deletes a line, which is how entries are removed while editing).
  local km = config.options.keys or {}
  local function visual_range()
    local a, b = vim.fn.line('v'), vim.fn.line('.')
    if a > b then
      a, b = b, a
    end
    vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'nx', false)
    return { a, b }
  end
  local function edit_map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = 'gliter.netrw (edit): ' .. desc })
  end
  if km.yank then
    edit_map('n', km.yank, function()
      M.mark(buf, 'copy')
    end, 'copy mark')
    edit_map('x', km.yank, function()
      M.mark(buf, 'copy', visual_range())
    end, 'copy mark on selection')
  end
  if km.yank_all then
    edit_map('n', km.yank_all, function()
      M.mark_all(buf)
    end, 'toggle copy mark on every entry')
  end
  if km.clear then
    edit_map('n', km.clear, function()
      M.clear_marks(buf)
    end, 'clear all marks')
  end
  if km.paste then
    edit_map('n', km.paste, function()
      M.paste(buf)
    end, 'apply marks')
  end
  -- The cancel key (default `q`) leaves the edit (asking before discarding unsaved
  -- changes). `:w` applies. Note: while `q` is the cancel key it cannot record macros.
  if km.edit_cancel then
    edit_map('n', km.edit_cancel, function()
      M.cancel(buf)
    end, 'cancel the edit (discard, :w applies)')
  end
  paint_marks(active[buf])
  watch_text(active[buf])

  local msg = 'Editing listing: add/remove/rename lines, :w to apply'
  local cancels = {}
  if km.edit then
    cancels[#cancels + 1] = km.edit
  end
  if km.edit_cancel then
    cancels[#cancels + 1] = km.edit_cancel
  end
  if #cancels > 0 then
    msg = msg .. ', ' .. table.concat(cancels, ' or ') .. ' to cancel.'
  else
    msg = msg .. '.'
  end
  ui.notify(msg)
end

--- Start editing, or cancel if already editing.
---@param ctx GliterNetrwCtx
function M.toggle(ctx)
  if active[ctx.buf] then
    M.cancel(ctx.buf)
  else
    M.start(ctx)
  end
end

---@param buf integer
---@return boolean
function M.is_active(buf)
  return active[buf] ~= nil
end

return M
