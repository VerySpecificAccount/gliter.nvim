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
---@field shell string|false         run a shell command on the shell-marked entries, else on any marked entries, else on the entry under the cursor (`*` in the command stands for the files); the command runs in a terminal window, so interactive commands (sudo's password prompt) work
---@field run_each string|false      run a shell command on each of those entries separately, in a terminal, one after another (`*` = the current entry); also the `x` MARK kind: `%x` and the `*x` family mark entries for it
---@field file string|false          run the file command on the entry under the cursor and show its report in a floating window (default `F`)
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
---@field listing string|false      a shell command whose output replaces the netrw listing (e.g. 'eza -l', 'ls -ltrhF', 'ls -d */', 'tree -CF --dirsfirst'); false/nil = netrw's own listings
---@field keep_marks boolean        keep the marks when a window browses into another directory (default true: they follow you, so `y` here, <CR> there, `p` pastes into the directory you are in; false forgets them on every switch, so a stale set is never pasted into an unrelated directory)
---@field listing_default boolean   start every new netrw window in the custom listing slot — as if the user had pressed `i` into it; `i` can still cycle away, and the choice is remembered per window (default false)
---@field listing_color boolean     ask known commands for their colored output — `ls --color=always`, `tree -C`, `fd --color=always` — when the listing command carries no color flag of its own; the ANSI escapes become highlights (default true)
---@field listing_paths boolean     on the custom listing, read a token that names no entry of the listed directory as a path under it (`fd .`'s `sub/file.lua` opens) (default false)
---@field soft_colors boolean        soften the colors, dired-style: netrw's own listing groups (netrwDir, netrwExe, ...) and every ANSI color a custom listing command sends are muted into a background-aware pastel instead of the theme-bright originals (default true)
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
    file = 'F',
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
  -- A shell command whose output replaces the netrw listing (rendered by
  -- custom.lua, colored by color.lua): 'eza -l' for the details,
  -- 'eza -l --icons --git' for the works, 'ls -ltrhF' for the classic
  -- long listing, 'ls -d */' for directories only, 'tree -CF --dirsfirst'
  -- for an outline — anything that runs in a shell and prints entry names.
  -- nil (or false) keeps netrw's own listings and their styles, and
  -- nothing of the defaults is touched.
  listing = nil,
  -- Start every new netrw window in the custom listing slot (default
  -- false). `i` can still cycle away from it; once a window has left the
  -- custom slot (w:gliter_netrw_liststyle == false) settle() will not
  -- re-arm it, so the user's per-window choice is respected.
  listing_default = false,
  -- Keep the marks when a window switches to another directory (<CR> into a
  -- subdirectory, `-` up). Default true: they follow you, so `y` here,
  -- <CR> there, `p` pastes into the directory you are in. With false the
  -- marks belong to the listing they were set on and are forgotten on a
  -- switch, so a stale set is never pasted into an unrelated directory.
  keep_marks = true,
  -- Colors, on by default: a known listing command (`ls`, `tree`, `fd`,
  -- ...) is asked for its colored output — `ls --color=always`, `tree
  -- -C` — when the command carries no color flag of its own, and any
  -- command's ANSI escapes become highlights (color.lua), the way a
  -- terminal, or Emacs' dired, shows them. The option only adds the
  -- flag; ANSI output is read whatever it came from.
  listing_color = true,
  -- `fd .` prints paths under the listed directory (`sub/file.lua`),
  -- not its entries; with this on, a token that names no entry of the
  -- directory is read as a path under it — and opens. Default off: the
  -- plain listings (`ls`, `tree`) need nothing of it.
  listing_paths = false,
  -- Soft colors, on by default: netrw's own listing groups and every
  -- ANSI color a custom listing command sends are muted into a
  -- background-aware pastel — dired's calm — instead of the
  -- theme-bright originals (see soft.lua). false puts everything back
  -- exactly as it was.
  soft_colors = true,
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
