local M = {}

---@class GliterNetrwKeymaps
---@field yank string|false          toggle a copy mark on the entry (or each Visual line)
---@field move string|false          toggle a move mark on the entry (or each Visual line)
---@field delete string|false        toggle a delete mark on the entry (or each Visual line); `p` deletes delete-marked entries after confirmation
---@field archive string|false       toggle an archive mark on the entry (or each Visual line); `p` packs archive-marked entries into a new archive — or extracts them, when the entry itself is an archive
---@field yank_all string|false      toggle the copy mark on every entry
---@field move_all string|false      toggle the move mark on every entry
---@field delete_all string|false    toggle the delete mark on every entry
---@field archive_all string|false   toggle the archive mark on every entry
---@field paste string|false         apply the marks into the current directory (paste, delete, archive)
---@field edit string|false          toggle in-place editing of the listing (add / remove / rename entries by editing the buffer text); pressed again mid-edit, cancels
---@field edit_cancel string|false   cancel in-place editing, discarding the edits (apply is always `:w`)
---@field clear string|false         clear all marks (default `<Esc>`)
---@field copy_to string|false       copy the copy-marked entries (or the entry under the cursor) to a typed directory
---@field rename_to string|false     move the move-marked entries (or the entry under the cursor) to a typed directory / new name
---@field delete_now string|false    delete the delete-marked entries (or the entry under the cursor), after confirmation
---@field execute string|false       toggle the executable bit on the marked entries (or the entry under the cursor, or — in Visual mode — each entry of the selection)
---@field symlink string|false       symlink the marked entries (or the entry under the cursor) into a typed directory
---@field shell string|false         run a shell command on the shell-marked entries, else on any marked entries, else on the entry under the cursor (`*` in the command stands for the files)
---@field run_each string|false      run a shell command on each of those entries separately, in a terminal, one after another (`*` = the current entry); also the `x` MARK kind: `%x` and the `*x` family mark entries for it
---@field mkdir string|false         create a file, or a directory when the name ends in `/` (parents included)
---@field cd string|false            make the directory listed here the current working directory
---@field bookmark string|false       `<C-b>1`..`<C-b>9` point bookmark 1..9 at this directory; `<C-b>0` clears them all, `<C-b>l` lists them
---@field bookmark_jump string[]|false jump keys for slots 1..9 (default `<C-1>`..`<C-9>`); a jump to an unset slot points it at this directory first
---@field regex_prefix string|false  `%<key>` marks by regexp; the letter is the mark key itself (`%y` copy, `%m` move, `%d` delete, `%z` archive, `%!` shell, `%x` run)
---@field star_prefix string|false   `*<family>` marks a family with the default kind; a mark key in between — `*y.`, `*m/`, `*d@`, `*z*`, `*!*`, `*x.` — picks the kind for that press (and makes it the default)
---@field star_ext string|false      family key: mark every entry with a typed extension (default `.`)
---@field star_dirs string|false     family key: mark every directory (default `/`)
---@field star_links string|false    family key: mark every symlink (default `@`)
---@field star_exec string|false     family key: mark every executable (default `*`)
---@field preview string|false       where netrw's native `p` (preview) is moved when `paste` is `p`

---@class GliterNetrwConfig
---@field keys GliterNetrwKeymaps|false
---@field native_unmap string[]  netrw buffer keys to delete (default: gR + %)
---@field star_kind 'copy'|'move'|'delete'|'shell'|'archive'|'run'
---@field conflict 'ask'|'overwrite'|'skip'|'rename'
---@field indicators { copy: string|false, move: string|false, delete: string|false, shell: string|false, archive: string|false, run: string|false, copied: string|false, moved: string|false, new: string|false }
---@field edit { confirm: boolean }   `confirm`: ask before applying additions/renames/deletions
---@field notify_level integer    minimum vim.log.levels value to display
M.defaults = {
  keys = {
    yank = 'y',
    move = 'm',
    delete = 'd',
    archive = 'z',
    yank_all = 'Y',
    move_all = 'M',
    delete_all = 'gD',
    archive_all = 'Z',
    paste = 'p',
    edit = 'E',
    edit_cancel = 'q',
    clear = '<Esc>',
    preview = '<C-p>',
    copy_to = 'C',
    rename_to = 'R',
    delete_now = 'D',
    execute = 'X',
    symlink = 'S',
    shell = '!',
    run_each = 'x',
    mkdir = '+',
    cd = '<C-g>',
    bookmark = '<C-b>',
    bookmark_jump = { '<C-1>', '<C-2>', '<C-3>', '<C-4>', '<C-5>', '<C-6>', '<C-7>', '<C-8>', '<C-9>' },
    regex_prefix = '%',
    star_prefix = '*',
    star_ext = '.',
    star_dirs = '/',
    star_links = '@',
    star_exec = '*',
  },
  -- Kind of mark that the `*` family (`*.`, `*/`, `*@`, `**`) applies. This is the initial
  -- value; `*y.`, `*m/`, `*d@`, `*z*`, `*!*`, `*x.` and friends change it at runtime from
  -- inside a netrw buffer: the mark key picks the kind for that press and becomes the
  -- new default.
  star_kind = 'copy',
  -- netrw's own buffer-local keys removed in netrw buffers (gliter.netrw takes over the job).
  native_unmap = { 'gR', '+', '%' },
  conflict = 'ask',
  indicators = {
    copy = '  [copy]',
    move = '  [move]',
    delete = '  [delete]',
    shell = '  [shell]',    -- marked to run a shell command on (see `!`)
    archive = '  [archive]', -- marked to be packed into (or extracted from) an archive (see `p`)
    run = '  [run]',        -- marked for the one-at-a-time run (see `x`)
    copied = '  [copied]',  -- a line added by `p` in edit mode, pending a copy
    moved = '  [moved]',    -- a line added by `p` in edit mode, pending a move
    new = '  [new]',        -- a line typed in edit mode, pending creation
  },
  edit = { confirm = true },
  notify_level = vim.log.levels.INFO,
}

---@type GliterNetrwConfig
M.options = vim.deepcopy(M.defaults)

---@param opts? table
---@return GliterNetrwConfig
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(M.defaults), opts or {})
  return M.options
end

return M
