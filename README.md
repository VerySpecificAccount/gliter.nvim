# gliter

**Emacs ideas, Neovim-native.** A suite of opt-in Neovim plugins that
improve what Neovim already ships — no framework, no dependencies,
every module stands alone.

[![Neovim 0.9+](https://img.shields.io/badge/Neovim-0.9%2B-57A143?logo=neovim&logoColor=white)](https://neovim.io)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/VerySpecificAccount/gliter?style=social)](https://github.com/VerySpecificAccount/gliter/stargazers)

<!-- TODO: 1200x600 demo GIF — 4 panels: netrw marks, multicursor, which-key popup, make buffer -->

**17 modules. One namespace. One runtime path.** Opt in to what you
want; nothing loads without a `setup()` call. [Jump to the modules ↓](#modules)

---

### Why gliter?

- **No framework, no dependencies.** Every module is a plain
  `setup(opts)` returning table.
- **Opt-in by design.** `setup()` touches only the modules you name.
- **Improves, never replaces.** A module earns its seat only by making
  something Neovim already ships nicer to use.
- **One namespace, one runtime path.** `gliter.<name>`, every module
  standing on its own.
- **Stolen from Emacs — with receipts.** Every module cites the Emacs
  package it ported (see [Stolen from Emacs](#stolen-from-emacs)).

The interfaces are borrowed from Emacs — on purpose, in broad
daylight; the "Stolen from Emacs" section below is the itemized
receipt. And a module earns its seat in the suite by one rule only:
make something Neovim already ships nicer to use, and replace none
of it.

Every module is opt-in. `setup()` touches only the modules you name
in its options; a module you leave out is never loaded, and nothing
at all happens without a `setup()` call.

## Modules

| Module | Needs | Adds | Stolen from |
| ------ | ----- | ---- | ----------- |
| [`gliter.netrw`](doc/gliter.netrw.md) | Neovim 0.12+ | marks, bookmarks, one-key commands, regexp marking with a live highlight and in-place editing for the built-in netrw | dired (1986) + wdired |
| [`gliter.undotree`](doc/gliter.undotree.md) | Neovim 0.12+ | a `<Leader>u` toggle, colors and a bottom diff window for the built-in `:Undotree` | undo-tree (2009) |
| [`gliter.multicursor`](doc/gliter.multicursor.md) | Neovim 0.13+ | keys for the built-in multicursors: `<M-i>` puts one on every line of the selection, `<Leader>cj`/`<Leader>ck` place one and step, `<M-a>` on every occurrence, `<C-n>`/`<C-p>` walk them, `<C-s>`/`<C-m>` skip, `<C-b>`/`<C-f>` remove one | multiple-cursors (2012) |
| [`gliter.treesitterRE`](doc/gliter.treesitterRE.md) | Neovim 0.9+ | expand-region: one key grows the selection up a semantic ladder (parser optional) | expand-region (2011) |
| [`gliter.ctags`](doc/gliter.ctags.md) | Neovim 0.10+ | the built-in ctags support with better defaults, a one-command interface and quickfix | etags (mid-1980s) |
| [`gliter.make`](doc/gliter.make.md) | Neovim 0.9+ | per-filetype `'makeprg'` and the `*compilation*` buffer: streaming, terminal-colored output whose errors fill the quickfix — plus a runner (run the file, the selection, a grep, shells) through one settable output function | compile (mid-1980s) |
| [`gliter.repl`](doc/gliter.repl.md) | Neovim 0.9+ | a REPL per filetype with Spacemacs' send keys (`<Leader>ls`/`lS`/`ll`/`lb`) and headless evaluation (`<Leader>le`) | SLIME (2003) |
| [`gliter.textobj`](doc/gliter.textobj.md) | Neovim 0.9+ | targets.vim's quote and separator objects: `vi"` exactly where Vim's own works, seeking where it gives up — the next pair after the cursor first (the gap between two strings takes the next string, like `in"`), then back to the pair before it, then the nearest one by distance. `in"`/`il"`, `i,` between the commas | targets.vim (2014) |
| [`gliter.sessions`](doc/gliter.sessions.md) | Neovim 0.9+ | `:mksession` with a memory: `<Leader>ss` saves the session into its project and remembers it, `<Leader>sl` lists every known session in a float — `<CR>` activates, `d` deletes, saving again updates | desktop.el (1990s) |
| [`gliter.readme`](doc/gliter.readme.md) | Neovim 0.9+ | `<Leader>rr` opens (or creates) the project's readme — the name is an option — and `<Leader>rl` lists every readme you touched, most recent first: `<CR>` opens, `<C-t>`/`<C-w>`/`<C-v>` open it in a tab or a split, `d` forgets | recentf (2002) |
| [`gliter.justify`](doc/gliter.justify.md) | Neovim 0.9+ | `g=` and `:GliterJustify`: reflow the paragraph (or the selection, or a range) to the width and justify it — both margins flush, the last line ragged | fill.el (1980s) + justify.vim (1998) |
| [`gliter.matchit`](doc/gliter.matchit.md) | Neovim 0.9+ | `M` (the key you gave `%`) jumps between the words that bracket a block — `if`/`end`, `function`/`endfunction`, `<div>`/`</div>` — nesting counted; `gM` the other way; plain `%` on everything else | matchit.vim (1996) |
| [`gliter.tohtml`](doc/gliter.tohtml.md) | Neovim 0.10+ | `:GliterTohtml`: the buffer (or the selection) out as HTML with its syntax colors, as Markdown, or as PDF typeset by groff | 2html.vim (2001) + htmlize.el (1997) + troff (1973) |
| [`gliter.w3`](doc/gliter.w3.md) | Neovim 0.10+ | the web in a buffer: `:GliterW3 <url>` — curl fetches and pandoc renders the page (lynx without pandoc, w3m with the links taken out of the html, wls lists the site); links followable from the keyboard while a spinner covers the load, `]l`/`[l` walk them, `gl` quickfixes them, `H` goes back, `R` reloads, keywords search DuckDuckGo | W3 (1993) → eww (2013) → viww (2026) |
| [`gliter.cmd`](doc/gliter.cmd.md) | Neovim 0.10+ | readline's keys on the built-in command line — C-a/C-b/C-f/C-d/C-k/C-t, M-b/M-f, M-BS/M-d, each editing the line the way `setcmdline()` allows; Tab/S-Tab untouched, the wildmenu keeps its own keys (C-e reverts it, Right walks it, the edit keys sleep while it is up) — and fish's ghost: the history's continuation dimmed after the line (`:w` with ` file` after it — Enter runs `:w` alone, `C-n` or `C-f`/`C-e`/`Right` at the end takes the echo, `C-p` cycles the echoes, one older at a time); input()'s prompts — netrw's `%`, w3's address — get the same ride, their answers in the `@` history | readline (1988) + fish (2005) |
| [`gliter.which`](doc/gliter.which.md) | Neovim 0.10+ | a light which-key: pause after a prefix (`<Leader>`, `g`, `z`, ...) and a popup lists the mappings that continue it, straight out of `:map` | guide-key (2012) → which-key.el (2015) → which-key.nvim (2021) |
| [`gliter.screenkey`](doc/gliter.screenkey.md) | Neovim 0.9+ | shows the keys you press as you press them — a float for screencasts and demos | echo-keystrokes / view-lossage (1980s) → showkey.el (2015) → screenkey.nvim (2024) |
| ~~[`gliter.pack`](doc/gliter.pack.md)~~ | Neovim 0.10+ | **deprecated** — use [store.nvim](https://github.com/alex-popov-tech/store.nvim) instead | package.el + MELPA (2007/2012) |

## Not everything needs a module

Commenting, for instance, is built into Neovim 0.10+ — `gc` toggles
comments as an operator, `gcc` the line — so gliter ships no
`gliter.comment`. A prefix key is all that is missing, and that is one
line, not a module:

```lua
vim.keymap.set("", "<leader>c", "gc", { remap = true, desc = "Toggle comment" })
```

The suite's rule is exactly this: a module has to make something Neovim
already ships nicer to use. When Neovim already ships the whole feature,
the README is where it goes, not the runtime path.

## The default setup

The table under this fold is every option of every module, with its
default — copy rows out of it into your own `setup` call:

<details>
<summary>The full options table — every option, every module</summary>

```lua
require('gliter').setup {
  netrw = {
    keys = {                     -- set any key to false to disable it
      -- marks
      yank = 'y',                -- toggle a copy mark
      move = 'm',                -- toggle a move mark
      delete = 'd',              -- toggle a delete mark
      archive = 'z',             -- toggle an archive mark
      yank_all = 'Y',            -- copy mark on every entry
      move_all = 'M',            -- move mark on every entry
      delete_all = 'gD',         -- delete mark on every entry
      archive_all = 'Z',         -- archive mark on every entry
      paste = 'p',               -- apply the marks
      clear = '<Esc>',           -- clear all marks
      -- commands
      copy_to = 'C',             -- copy marked to a typed directory
      rename_to = 'R',           -- move/rename marked
      delete_now = 'D',          -- delete marked after confirmation
      execute = 'X',             -- toggle the executable bit (Visual
                                 -- mode too: on the selection)
      symlink = 'S',             -- symlink marked into a directory
      shell = '!',               -- run a shell command on the marks
      run_each = 'x',            -- shell command one entry at a time;
                                 -- %x / *x mark entries for it
      mkdir = '+',               -- create a file, or a directory ending in /
      cd = '<C-g>',              -- :cd to the listed directory
      -- bookmarks
      bookmark = '<C-b>',        -- <C-b>1..9 bookmark this directory;
                                 -- <C-b>0 clears all; <C-b>l lists them
      bookmark_jump = { '<C-1>', '<C-2>', '<C-3>', '<C-4>', '<C-5>',
                        '<C-6>', '<C-7>', '<C-8>', '<C-9>' },
                                 -- jump to bookmark 1..9; an unset slot
                                 -- is pointed here first
      -- bulk marking
      regex_prefix = '%',        -- %y %m %d %z %! %x mark by regexp
                                 -- (%x = the one-at-a-time run)
      star_prefix = '*',         -- *. */ *@ ** (and *<mark><family>,
                                 -- run_each's x included: *x.)
      star_ext = '.',            --   family: by extension
      star_dirs = '/',           --   family: directories
      star_links = '@',          --   family: symlinks
      star_exec = '*',           --   family: executables
      -- edit mode
      edit = 'E',                -- toggle in-place editing of the listing
      edit_cancel = 'q',         -- cancel the edit (apply is always :w)
      -- other
      preview = '<C-p>',         -- where netrw's own preview goes when paste is p
    },
    star_kind = 'copy',          -- 'copy' | 'move' | 'delete' | 'archive' |
                                 -- 'shell' | 'run': kind the plain `*`
                                 -- family marks with
    conflict = 'ask',            -- 'ask' | 'overwrite' | 'skip' | 'rename' on paste
    indicators = {               -- the [tag] next to marked lines; false hides one
      copy = '  [copy]',
      move = '  [move]',
      delete = '  [delete]',
      shell = '  [shell]',
      archive = '  [archive]',
      run = '  [run]',
      copied = '  [copied]',
      moved = '  [moved]',
      new = '  [new]',
    },
    edit = { confirm = true },   -- ask before applying edits with :w
    notify_level = vim.log.levels.INFO,
    native_unmap = { 'gR', '+', '%' }, -- netrw keys removed in netrw buffers
  },
  undotree = {
    toggle = '<Leader>u',        -- open the tree, or close it from inside it
    difftool = true,             -- :packadd nvim.difftool — the diff panel's engine
    diff_panel = 'auto',         -- 'auto' | true | false
    panel_height = 10,           -- height of the bottom diff window
  },
  multicursor = {
    keys = {                      -- every name to its key; set one to
                                 -- false to unmap it, the ones you
                                 -- leave out keep these defaults
      clear      = '<Esc>',      -- clear all multicursors
      follow     = '<C-=>',      -- toggle 'follow': do motions replay
                                 -- at every cursor or not (q=)
      insert     = '<M-i>',      -- n: a cursor at the cursor position
                                 -- (a count passes through: 1<M-i> adds,
                                 -- 2<M-i> removes); x: a cursor on every
                                 -- line of the selection, at the
                                 -- selection's column
      below      = '<Leader>cj', -- n: place a cursor and move down
                                 -- (3<Leader>cj: cursors on three lines,
                                 -- you on the third)
      above      = '<Leader>ck', -- n: place a cursor and move up
      skip_next  = '<C-s>',      -- skip: no cursor at the match under
                                 -- the cursor, move to the next match
      skip_prev  = '<C-m>',      -- skip backwards: previous match, no
                                 -- cursor placed (<C-m> is <CR>: in
                                 -- quickfix windows Enter keeps its
                                 -- builtin jump)
      remove_prev = '<C-b>',     -- remove the previous cursor [up]
      remove_next = '<C-f>',     -- remove the next cursor [down]
      all        = '<M-a>',      -- n+x: a cursor at every occurrence of
                                 -- the word / the selection
      next       = '<C-n>',      -- n+x: a cursor at the next occurrence
      prev       = '<C-p>',      -- n+x: a cursor at the previous occurrence
      next_reset = '<Leader>cn', -- n+x: reset the search pattern, then
                                 -- the next occurrence
      prev_reset = '<Leader>cp', -- n+x: reset the pattern, previous one
    },
    extra_keys = {},             -- raw { mode, key, rhs, opts } rows on
                                 -- top of the named keys above
  },
  treesitterRE = {
    keys = {
      expand       = '<M-n>',    -- cycle same-level nodes (wraps around)
      contract     = '<M-p>',    -- the same cycle, backwards
      expand_right = '<M-f>',    -- grow the selection one word right
      expand_left  = '<M-b>',    -- grow the selection one word left
      expand_up    = '<BS>',      -- the ladder
      expand_down  = '<M-BS>',   -- walk the ladder back down
      left_out     = '<M-u>',    -- push the left edge out by one character
      left_in      = '<M-o>',    -- pull the left edge in by one character
      hop_word     = '<M-w>',    -- viw at the edge of the last lateral motion
      next_sibling = 'gl',       -- next sibling; climbs a level when out
      prev_sibling = 'gh',       -- previous sibling
      next_scope   = 'gj',       -- next function / if / loop / ...
      prev_scope   = 'gk',       -- previous function / if / loop / ...
    },
  },
  zoom = {                       -- not in the Modules table above — the
                                 -- module and its keys live in
                                 -- doc/gliter.zoom.md
    keys = {
      increase = '<Leader>=',    -- grow: the glyph scale while the glyph
                                 -- zoom is on, the style level otherwise
                                 -- (this buffer only)
      decrease = '<Leader>-',    -- shrink: the glyph scale while the glyph
                                 -- zoom is on (past the smallest it turns
                                 -- the glyphs off), the style level
                                 -- otherwise (negative = smaller)
      reset = '<Leader>0',       -- both engines off, 'wrap' restored
      glyph = '<Leader>z',       -- glyph zoom: toggle (a count sets the
                                 -- scale)
    },
    echo = true,                 -- say the state on every change
    styles = {                   -- the STYLE ladders — the fonts: entry 1
                                 -- of zoom_in is level 1, entry 2 level 2,
                                 -- ...; entry 1 of zoom_out is level -1.
                                 -- ADD, REMOVE or REORDER entries freely —
                                 -- the number of entries IS the number of
                                 -- levels; every style that ships is in a
                                 -- ladder by default, trim to taste
                                 -- (:GliterZoomStyles prints them all live)
      zoom_in = {
        'bold',                  -- 𝐛𝐨𝐥𝐝 — level 1
        'italic',                -- 𝑖𝑡𝑎𝑙𝑖𝑐
        'bold_italic',           -- 𝒃𝒐𝒍𝒅 𝒊𝒕𝒂𝒍𝒊𝒄
        'script',                -- 𝓈𝒸𝓇𝒾𝓅𝓉 (cursive)
        'bold_script',           -- 𝓫𝓸𝓵𝓭 𝓼𝓬𝓻𝓲𝓹𝓽
        'fraktur',               -- 𝔣𝔯𝔞𝔨𝔱𝔲𝔯 (gothic)
        'bold_fraktur',          -- 𝖋𝖗𝖆𝖐𝖙𝖚𝖗 𝖇𝖔𝖑𝖉
        'double_struck',         -- 𝕕𝕠𝕦𝕓𝕝𝕖 𝕤𝕥𝕣𝕦𝕔𝕜
        'sans',                  -- 𝗌𝖺𝗇𝗌
        'sans_bold',             -- 𝘀𝗮𝗻𝘀 𝗯𝗼𝗹𝗱
        'sans_italic',           -- 𝘴𝘢𝘯𝘴 𝘪𝘵𝘢𝘭𝘪𝘤
        'sans_bold_italic',      -- 𝙨𝙖𝙣𝙨 𝙗𝙤𝙡𝙙 𝙞𝙩𝙖𝙡𝙞𝙘
        'mono',                  -- 𝚖𝚘𝚗𝚘 (monospace)
        'underlined',            -- 𝘂̲𝗻̲𝗱̲𝗲̲𝗿̲𝗹̲𝗶̲𝗻̲𝗲̲𝗱̲
        'circled',               -- Ⓒⓘⓡⓒⓛⓔⓓ (ambiguous width in some
                                 -- terminals)
        'squared',               -- 🅢🅠🅤🅐🅡🅔🅓 (blocks; 2 cells per char)
        'fullwidth',             -- ｆｕｌｌｗｉｄｔｈ — 2 cells per char, the
                                 -- huge one
      },
      zoom_out = {
        'smallcaps',             -- ꜱᴍᴀʟʟ ᴄᴀᴩꜱ — level -1
        'superscript',           -- ˢᵘᵖᵉʳˢᶜʳⁱᵖᵗ — level -2
      },
    },
    margin = 20,                 -- lines rendered above/below the viewport
    nui = 'auto',                -- 'auto' | true | false: NuiText when
                                 -- nui.nvim is installed
    hl_mode = 'combine',         -- 'combine' keeps the buffer's colors
                                 -- under the styled glyphs; 'replace'
                                 -- paints them flat
    glyph = {                    -- the <Leader>z engine: the thin
                                 -- sub-pixel font — one bitmap pixel is
                                 -- half a cell wide, half a cell tall
                                 -- (the | look), a letter 5 pixels wide
                                 -- by 5 tall plus a blank sixth row (the
                                 -- line gap): 3 cells by 3 rows a line
                                 -- at scale 1, every scale growing each
                                 -- font pixel to s×s sub-pixels (no
                                 -- stretching)
      max_scale = 4,             -- deepest scale: 1 = the small thin
                                 -- letters, 2 = 6x6, 3 = 9x9, 4 = 12x12
      hl_group = 'Normal',       -- the color of unhighlighted glyph cells
      skip_cursor_line = false,  -- true keeps the cursor line real text
      cursor = true,             -- draw the cursor BIG: the letter under
                                 -- the cursor is painted in the cursor's
                                 -- colors across all of its rows — the
                                 -- terminal's own 1-cell cursor cannot
                                 -- show which 3-cells-wide (at x1) letter
                                 -- it is on; false = the plain small one
      -- the 16 sub-pixel characters by bitmask (TL*8 + TR*4 + BL*2 +
      -- BR*1); braille dots by default — the lightest, most readable
      -- spelling (the solid half-blocks are denser, the shades between):
      -- quads = { ' ', '▗', '▖', '▄', '▝', '▐', '▞', '▟', '▘', '▚', '▌', '▙', '▀', '▜', '▛', '█' },
      quads = { '⠀', '⢠', '⡄', '⣤', '⠘', '⢸', '⡜', '⣼', '⠃', '⢣', '⡇', '⣧', '⠛', '⢻', '⡟', '⣿' },
      -- quads = { ' ', '░', '░', '▒', '░', '▒', '▒', '▓', '░', '▒', '▒', '▓', '▒', '▓', '▓', '█' },
      font = {},                 -- your own glyphs, merged over the
                                 -- built-ins: rows separated by '/',
                                 -- 1 = pixel on — ['A'] = '01110/10001/11111/10001/10001/00000'
    },
  },
  ctags = {
    keys = {
      list = '<Leader>]',        -- tags of the word under the cursor, in a
                                 -- vertical picker
      quickfix = '<Leader>[',    -- the same matches, in the quickfix list
      generate = false,          -- e.g. '<Leader>tg'; :GliterCtags generate
                                 -- works without a key
    },
    bin = 'ctags',               -- universal-ctags or exuberant-ctags
    tags_file = nil,             -- nil = stdpath('data')/gliter/tags/<hash>;
                                 -- 'tags' = the project root
    root_markers = { '.git', '.hg', '.svn', 'Makefile', 'package.json',
                     'go.mod', 'Cargo.toml', 'pyproject.toml', 'setup.py' },
    excludes = { '.git', '.hg', '.svn', 'node_modules', 'target', 'dist',
                 'build', '.cache', '.venv', 'venv', '__pycache__', '.npm',
                 '.cargo', '.rustup', '.pyenv', '.mypy_cache', '.pytest_cache',
                 '.tox' },          -- dirs ctags never walks into
    extra_args = {},             -- appended to the ctags command line
    auto_generate = true,        -- regenerate (debounced) on :w, once the
                                 -- project has a tags file
    skip_home_root = true,       -- $HOME (a dotfiles .git) is no project:
                                 -- its files get single-file tags
    max_entries = 300000,        -- entries parsed for list/quickfix; a
                                 -- runaway tags file truncates, not hangs
    warn_mb = 50,                -- a tags file over this warns the root is
                                 -- too broad
    quickfix = { open = true, height = 10 },
  },
  make = {
    keys = {
      run = '<Leader>lm',         -- run the build (Spacemacs' compile key);
                                 -- a second press restarts it
      show = false,               -- e.g. '<Leader>ls'; :GliterMakeShow too
      stop = false,               -- e.g. '<Leader>lk'; :GliterMakeStop too
      run_file = '<Leader>lr',    -- run the current file; the Visual twin
                                 -- of the key runs the live selection
      grep = '<Leader>lp',        -- ripgrep a pattern into the quickfix
    },
    programs = {                 -- 'makeprg' per filetype; '*' = the rest,
      ['*'] = 'make',            -- a row set to false leaves that one alone
      cmake = 'cmake --build build',
      go = 'go build ./...',
      rust = 'cargo build',
      zig = 'zig build',
      -- python = 'python -m py_compile %',  -- syntax check only
      python = 'pypy3 %',        -- run the file: real tracebacks
      tex = 'latexmk -pdf -interaction=nonstopmode %',
    },
    errorformats = {             -- 'errorformat' per filetype: a LIST, each
                                 -- entry tried on a line of its own before
                                 -- Vim's default (like Emacs'
                                 -- compilation-error-regexp-alist; a merged
                                 -- format cannot backtrack — the bare
                                 -- `File "x.py", line 2` of python syntax
                                 -- errors needs its own try)
      rust = { '%E%.%#-->\\ %f:%l:%c,%Wwarning:%m' },
      python = { '  File "%f"\\, line %l%.%#' },
    },
    height = 12,                 -- output window height
    ansi = true,                 -- render the output's ANSI colors
    scroll = true,               -- follow the output until you scroll away
    env = { CLICOLOR_FORCE = '1', FORCE_COLOR = '1',
            CARGO_TERM_COLOR = 'always' }, -- false = pass nothing
    pty = true,                  -- run under a pty, the way Emacs'
                                 -- compile does: colors from every tool
                                 -- (gcc, cargo, python paint when they
                                 -- see a terminal), full interleave —
                                 -- lines wrap at the pty's width
    width = 0,                   -- the pty's width: 0 = the origin
                                 -- window's, floored at 100
    flash = 1000,                -- ms an error's span stays flashed when
                                 -- n / p (or :cnext, :cprev, quickfix
                                 -- <CR>) step onto it; false = no flash
    runner = {                   -- run the file in front of you, through
                                 -- one settable output function
      programs = {               -- per filetype ('' = no filetype; '*' =
        python = 'pypy3 %',      -- catch-all; false = disabled);
        c = 'gcc -g % && ./a.out',  -- '%' is the buffer's file, full path
        cpp = 'g++ -std=c++17 -g -Wall % 2>/dev/null && ./a.out',
        lua = 'lua %',           -- and shell-escaped
        rust = 'RUST_BACKTRACE=1 cargo run || rustc % -o a.out && ./a.out',
        haskell = 'runhaskell %',
        [''] = 'make',
      },
      visual = {                 -- interpreters for the Visual selection
        lua = 'lua',             -- (x<Leader>lr): a temp file piped in
        python = 'python',
        javascript = 'node',
      },
      shells = {                 -- launchers on <Leader>l<key>: interactive
        f = { cmd = 'fzf', interactive = true },  -- ones get a terminal,
        t = 'tree',              -- plain ones the compilation buffer
      },
      grep_prog = 'rg',          -- the <Leader>lp search binary; false (or
                                 -- a missing one) = :vimgrep instead
      output = nil,              -- function(spec) — yours (e.g. a Snacks
                                 -- terminal float, see gliter.make.md);
                                 -- nil = compilation buffer + quickfix
    },
  },
  repl = {
    keys = {
      send_selection = '<Leader>ls', -- Visual: send the selection to the
                                 -- REPL, keep focus in the source buffer
      send_selection_jump = '<Leader>lS', -- Visual: send it, jump in
      send_line = '<Leader>ll',  -- send the current line (cursor moves
                                 -- down: hold to walk the file in)
      send_buffer = '<Leader>lb', -- send the whole buffer
      eval = '<Leader>le',       -- n+x: evaluate headless, no REPL
                                 -- opened; output in gliter.make's
                                 -- compilation buffer
      toggle = false,            -- e.g. '<Leader>li': show/hide the REPL
                                 -- window (the REPL itself stays)
    },
    programs = {                 -- one REPL per filetype
      python = 'python3 -i',
      lua = 'lua -i',
      javascript = 'node -i',
      sh = 'bash',
      haskell = 'ghci',
    },
    eval_programs = {            -- <Leader>le: run the snippet, no REPL
      python = 'python3',
      lua = 'lua',
      javascript = 'node',
      sh = 'bash',
      haskell = 'runhaskell',
    },
    extra_newline = { python = true }, -- these want a blank line
                                 -- after a block before they run it
    auto_start = true,           -- a send with no live REPL starts one
    height = 12,                 -- the REPL window's height
    position = 'botright',       -- 'botright' | 'vertical'
    dedent = true,               -- strip a selection's common indent
  },
  textobj = {
    quotes = { '"', "'", '`' },  -- which quotes get i/a/I objects
    separators = { ',', '.', ';', ':', '+', '-', '=', '~',
                   '_', '*', '#', '/', '\\', '|', '&', '$' },
                                 -- targets.vim's default set
    seek = true,                 -- work from on/around a pair and look
                                 -- next/last (in"/an"/il"/al" too)
    seek_lines = 200,            -- how many lines each way a quote
                                 -- seek looks
    multiline_sep = 50,          -- a separator object's search range
    reclaim = true,              -- re-assert the keys when something
                                 -- maps over them (the last mapping
                                 -- created wins in Vim)
  },
  sessions = {
    file_name = 'Session.vim',   -- the session file's name inside the
                                 -- project root
    keys = {
      save = '<Leader>ss',       -- mksession! into the project + remember it
      list = '<Leader>sl',       -- every known session, in a float
    },
    root_markers = { '.git' },   -- what makes a directory the project's root
                                 -- (the cwd otherwise)
    max_entries = 100,           -- the registry's size cap
  },
  readme = {
    file_name = 'README.md',     -- the readme's name in any project dir
    keys = {
      open = '<Leader>rr',       -- the project readme, opened or created
      list = '<Leader>rl',       -- every readme you touched, most recent first
    },
    root_markers = { '.git' },   -- what makes a directory the project's root
                                 -- (the cwd otherwise)
    max_entries = 50,            -- the remembered list's size cap
  },
  justify = {                    -- both margins flush
    keys = {
      justify = 'g=',            -- n: the paragraph around the cursor;
                                 -- x: the selection (:GliterJustify for
                                 -- ranges; an argument or a count is the
                                 -- width)
    },
    width = nil,                 -- nil: 'textwidth' when nonzero, else 80
  },
  matchit = {                    -- % for keywords
    keys = {
      match = 'M',               -- n/x/o: the matching keyword / tag —
                                 -- if/end, function/endfunction,
                                 -- <div>/</div>, nesting counted; plain
                                 -- % on everything else. A remap of your
                                 -- own on M (M -> %, say) wins over this
                                 -- one — remove it, or pick another key
      back = 'gM',               -- n/x/o: the same walk, the other way
                                 -- (differs only on the middle words:
                                 -- else/elseif/catch)
    },
    words = {},                  -- your chains, merged over the built-ins
                                 -- (lua, vim, sh/bash/zsh, c/cpp):
                                 -- { ruby = { opens = ..., middles = ...,
                                 -- closes = ... } }
    tags = { 'html', 'xhtml', 'xml' }, -- filetypes with <tag> matching
  },
  tohtml = {                     -- :GliterTohtml [html|md|pdf] + range
    groff = 'groff',             -- the pdf engine; false turns pdf off
    pdf_width = 100,             -- display columns before a hard split
    pdf_font_size = 8,           -- points
  },
  w3 = {                         -- the web in a buffer
    engine = 'auto',             -- 'auto': pandoc when curl and pandoc are
                                 -- on $PATH, else lynx, w3m, webls; or name
                                 -- one
    timeout = 30,                -- seconds a fetch gets
    search = 'https://duckduckgo.com/html/?q=%s', -- keywords go here
    curl = 'curl',               -- the fetcher of the pandoc and w3m
                                 -- pipelines
    browsers = { pandoc = 'pandoc', lynx = 'lynx',
                 w3m = 'w3m', webls = 'wls' },
                                 -- the renderers; a path works, false
                                 -- turns one off
    keys = {
      follow = '<CR>',           -- open the link on this line
      next_link = ']l',          -- the next link, wrapping around
      prev_link = '[l',          -- the previous link
      links = 'gl',              -- every link in the quickfix
      back = 'H',                -- the previous page
      reload = 'R',              -- this page again
    },
  },
  cmd = {                        -- the command line: readline's keys,
                                 -- and the history's continuation
                                 -- ghosted after the line
    ghost = true,                -- false = the keys alone, C-n/C-p
                                 -- left to the built-in history
                                 -- recall they always were
  },
  which = {                      -- the light which-key popup
    prefixes = { '<Leader>', '<LocalLeader>',
                 'g', 'z', '[', ']' }, -- bound (n+x) where the prefix is
                                 -- not already mapped; '<C-w>' is one opt-in
                                 -- away
    modes = { 'n', 'x' },        -- popup triggers in these modes
    border = 'rounded',
    max_height = 18,             -- rows per column before a second column
  },
  screenkey = {                  -- shows the keys you press (screencasts)
    timeout = 2000,              -- ms of quiet before the display clears
    max_keys = 10,               -- how many keys stay on screen
    border = 'none',
    row = nil,                   -- 0-based screen row; nil = above the
                                 -- cmdline
    col = nil,                   -- 0-based screen column; nil = centered
  },
}
```

</details>

The values above are the defaults (the RE is for region-expand). Set a module to `true` for
plain defaults, or to `false` to keep it explicitly off. To configure
without any Lua ordering concerns, stash the same table in a global before
startup — `let g:gliter = {...}` in init.vim or `vim.g.gliter = {...}`
early in init.lua — and `plugin/gliter.lua` hands it to `setup()` for you.

## Install

### With lazy.nvim

```lua
{
  'you/gliter',
  opts = {
    undotree = { panel_height = 6 },
    netrw = true,
  },
}
```

### With lz.n and vim.pack (Neovim 0.12+)

Install with the built-in
[`vim.pack`](https://neovim.io/doc/user/pack.html#vim.pack) and lazy-load
through [lz.n](https://github.com/lumen-oss/lz.n)'s handlers — `data`
carries the lz.n spec (`event`, `keys`, `cmd`, `ft`, …) for the plugin:

```lua
vim.pack.add({ 'https://github.com/lumen-oss/lz.n' })

vim.pack.add({
  {
    src = 'https://github.com/you/gliter',
    data = {
      event = 'BufReadPre',   -- or keys = ..., cmd = ..., ft = ...
      after = function()
        require('gliter').setup {
          netrw = { star_kind = 'copy' },
          treesitterRE = {},
        }
      end,
    },
  },
}, { load = require('lz.n').load })
```

### Without a plugin manager

Clone the repository anywhere on your `runtimepath` (e.g.
`~/.local/share/nvim/site/pack/gliter/start/gliter`) and call
`require('gliter').setup { ... }` from your init.lua, which runs before the
plugin's own files — or set `vim.g.gliter` as above and let
`plugin/gliter.lua` do it.

### One module on its own

Every module can be set up alone, straight from your init.lua:

```lua
require('gliter.netrw').setup { conflict = 'skip' }
```

gliter will not touch it afterwards — opt-in modules mean `setup()` only
ever reaches the modules you name in it, so a module configured directly
just stays as you left it (don't also name it in `require('gliter').setup`
unless you want its options applied there).

## Adding a module

Drop a new `lua/gliter/<name>.lua` that returns a table with `setup(opts)`,
then add one row to the `modules` table in `lua/gliter/init.lua`:

```lua
{ '<name>', 'gliter.<name>' },
```

From then on `require('gliter').setup { ['<name>'] = { ... } }` sets it up
(or `{ <name> = { ... } }` when the name is a valid Lua identifier).

## Stolen from Emacs

gliter's interfaces are stolen from
[Emacs](https://www.google.com/search?q=Emacs). This is less an admission
than an itinerary: every Neovim plugin ends up at Emacs eventually, and
gliter would rather take the direct flight — from take-off (implementation)
to landing (reimplementation), why not skip a few decades and copy from the
source? The table above lists which Emacs package each module took; each
module's documentation lists exactly which keys it took.

The dates are the fun part — every Emacs package below is older than the
Vim or Neovim thing it inspired, usually by a decade or more:

* **dired (1986) → gliter.netrw.** Sebastian Kremer's dired has marked
  files and run bulk commands on the marks since 1986 — five years before
  Vim existed — and wdired has edited directory listings as buffers since
  the early 2000s, twenty years before oil.nvim (2022) made the idea
  fashionable on this side. The numbered bookmarks are Emacs registers
  with the two-key prefix amputated: `C-x r j 3` there, `<C-3>` here.
* **etags / find-tag (mid-1980s) → gliter.ctags.** Emacs has grown `M-.`
  from a TAGS file since the mid-eighties — the tags idea itself is older
  still, the original `ctags` is from 3BSD around 1980. gliter.ctags puts
  the `M-.` flow (type a name, land on it) and the quickfix list on top
  of the built-in ctags support.
* **compile (mid-1980s) → gliter.make.** compile.el has run `make` into a
  `*compilation*` buffer since the mid-eighties: the command echoed at
  the top, the raw output scrolling by, error lines underlined,
  `next-error` cycling through them. Vim's `:make` filled the quickfix
  instead and stripped the colors on the way in. gliter.make gives `:make`'s
  machinery Emacs' window: `<Leader>lm` runs it, the output streams in
  terminal colors, jumps land on the exact character whatever the format
  said, and the same errors fill the quickfix list.
* **undo-tree (2009) → mbbill/undotree (2012) → `:Undotree` (Neovim 0.12)
  → gliter.undotree.** Toby Cubitt drew the branching history tree in
  Emacs; mbbill's [undotree](https://github.com/mbbill/undotree) redrew it
  for Vim three years later; Neovim ships a version of it as a dist plugin,
  and gliter repaints that one in undo-tree's palette and puts the diff
  window back.
* **expand-region (2011) → nvim-expand-region (2025) →
  gliter.treesitterRE.** magnars grew the selection by semantic units in
  Emacs fourteen years before the treesitter ladder showed up here.
* **multiple-cursors (2012) → built-in multicursors (Neovim 0.13) →
  gliter.multicursor.** magnars again; the cursors needed fourteen years to
  make the crossing, and the mappings gliter ships started from jceb's
  [multicursor-mappings.nvim](https://github.com/jceb/multicursor-mappings.nvim)
  (2026). `<M-i>` on a selection is magnars' `mc/edit-lines` — a cursor on
  every line of the region — and `<Leader>cj`/`<Leader>ck` are the regionless
  version of it, one line at a time.
* **guide-key (2012) → which-key.el (2015) → which-key.nvim (2021) →
  gliter.which.** A chain of rewrites, three links deep: guide-key
  (Tsunenobu Kai, 2012) popped up the key bindings that follow an
  incomplete key sequence in Emacs;
  [which-key.el](https://github.com/justbur/emacs-which-key) (Justin
  Burkett, 2015) — "started as a rewrite of guide-key-mode", its README
  says — grew the groups, the paging and the replacement rules until
  Emacs 30 took it into core; and folke's
  [which-key.nvim](https://github.com/folke/which-key.nvim) (2021)
  ported it to Neovim. gliter.which is the light version: the popup and
  nothing more.
* **view-lossage / echo-keystrokes → showkey.el (2015) → screenkey.nvim
  (2024) → gliter.screenkey.** Emacs has shown your keys since the 1980s:
  `echo-keystrokes` echoes an unfinished key sequence in the echo area
  after a pause, and `view-lossage` (`C-h l`) lists the last keystrokes
  you typed — both built-ins. [showkey.el](https://www.emacswiki.org/emacs/ShowKey)
  (Drew Adams, 2015) made the showing live — `showkey-tooltip-mode`,
  `showkey-log-mode`, the keys you use as you use them — and
  [screenkey.nvim](https://github.com/NStefan002/screenkey.nvim) (2024)
  moved it into a Neovim float under the name of the X11 `screenkey`
  tool. gliter.screenkey is the light version: one float, two colors, a
  timer.
* **SLIME (2003) → iron.nvim (2017) → gliter.repl.** SLIME has sent
  s-expressions from the buffer to a live Lisp since 2003; iron.nvim
  brought the sending to Neovim's terminals, and Spacemacs put the keys
  on `SPC l` — gliter.repl takes the keys verbatim
  (`<Leader>ls`/`lS`/`ll`/`lb`), iron's per-filetype REPLs, and adds the
  headless `<Leader>le`, Emacs' `eval-last-sexp` habit.
* **package.el (2007) + MELPA (2012) → ~~gliter.pack~~ (deprecated).**
  Emacs browsed its package archive from inside the editor in 2007
  (`M-x list-packages`), and MELPA made the archive worth browsing
  in 2012; `:GliterPack` ran the same loop over awesome-neovim's
  directory. Deprecated — a cached list is not a feature worth a
  module of its own; use
  [store.nvim](https://github.com/alex-popov-tech/store.nvim) instead.
* **targets.vim (2014) → gliter.textobj.** The one module stolen from
  Vim rather than Emacs: Vim's own quote objects only pair quotes
  around the cursor — past the last quote on the line they find
  nothing at all. targets.vim made `vi"` work from after the string
  too; the port runs Vim's own pairing wherever the cursor is on or
  inside a pair (translated from Neovim's `textobject.c`, so the
  parity on a quote and `a"`'s whitespace rule all match the built-in
  exactly), and everywhere else seeks the way targets.vim prefers it —
  the NEXT pair on the line first (a cursor between two strings takes
  the next string, not the gap Vim's own object picks there), then
  back to the pair before the cursor, then the nearest pair on
  another line by distance, ties to the one before — keeps the
  separators and the `I` trim, and documents what it left out.
* **desktop.el (1990s) → gliter.sessions.** Emacs has remembered whole
  desktops — windows, buffers, point — since before Neovim existed,
  the old-fashioned way: `M-x desktop-save` wrote them down and
  `M-x desktop-read` brought them back. gliter.sessions gives `:mksession` that memory:
  `<Leader>ss` saves the session into its project (plain `:mksession`
  output, usable without gliter), `<Leader>sl` lists every session
  saved anywhere with where it lives, and saving again updates.
* **recentf (2002) → gliter.readme.** Emacs has kept a list of the
  files you visited, most recent first, for twenty years. gliter.readme
  applies it to readmes: `<Leader>rr` opens or creates the project's
  readme (the name is an option), and `<Leader>rl` is the recent-files
  list of every readme you touched — `<CR>` opens, `<C-t>`/`<C-w>`/
  `<C-v>` open it in a tab or a split, `d` forgets.
* **fill.el (1980s) → gliter.justify.** `M-q` has reflowed paragraphs
  in Emacs since before Vim existed, and
  `set-justification-full` is the both-margins-flush mode. Neovim even
  ships the space-distribution half — the `justify` dist plugin (1998) —
  but it pads lines in place and never moves a word, so a ragged
  paragraph stays ragged. gliter.justify is the two halves together:
  `g=` reflows the way `M-q` fills, then justifies every line but the
  last.
* **htmlize.el (1997) → 2html.vim (2001) → gliter.tohtml.** Hrvoje
  Niksic exported buffers with their faces to HTML in 1997; Bram
  Moolenaar's `:TOhtml` (2html.vim, 2001) did it for Vim and shipped for
  a quarter century, until Neovim dropped it. gliter.tohtml brings it
  back in Lua — and adds Markdown, and PDF through groff, troff being
  the oldest tool in the whole suite (1973).
* **W3 (1993) → eww (2013) → viww (2026) → gliter.w3.** William Perry
  wrote the first Emacs web browser in 1993 — one of the first browsers
  anywhere; Lars Ingebrigtsen's eww (2013), the Emacs Web Wowser,
  replaced it in core, rendering with shr; Rugved Pund's
  [viww](https://github.com/pundfoo/viww) (2026) ported eww's keys to
  Neovim on curl and pandoc. gliter.w3 is that interface over the
  viewers you already have: viww's own pandoc pipeline first, lynx and
  w3m rendering the pages, and wls — "web ls" — listing the site's urls
  from its sitemaps, the netrw move applied to the web.
* **readline (1988) + fish (2005) → gliter.cmd.**
  Brian Fox's readline keys have edited every shell prompt since 1988;
  fish suggested the matching history entry as a ghost right after the
  cursor in 2005. gliter.cmd is the two of them laid over the built-in
  command line Neovim already has — every builtin key keeping its job,
  Tab and S-Tab above all — instead of a line of its own: the keys
  readline spells that the built-in line lacks, and the ghost, nothing
  more. gelguy's [wilder.nvim](https://github.com/gelguy/wilder.nvim)
  (2019) is the road not taken — a completion UI replacing the line
  rather than riding on it.

The one Emacs package gliter cannot have yet is Org-mode: gliter only
improves what Neovim already ships, so `gliter.orgmode` will be added as
soon as Org-mode is implemented in Neovim — any decade now.

## Prior art

gliter stands on the shoulders of:

**Emacs**, which had every idea here decades early:

* [dired](https://www.gnu.org/software/emacs/manual/html_node/emacs/Dired.html)
  (1986) and
  [wdired](https://www.gnu.org/software/emacs/manual/html_node/emacs/Wdired.html)
  (early 2000s) — the marks, the one-key commands, the editable listing
* [undo-tree](https://gitlab.com/tarsius/undo-tree) (2009) — the branching
  history and its diff window
* [expand-region](https://github.com/magnars/expand-region.el) (2011) — the
  selection ladder
* [multiple-cursors](https://github.com/magnars/multiple-cursors.el)
  (2012) — cursors at every occurrence
* [SLIME](https://common-lisp.net/project/slime/) (2003) — send code from
  the buffer to a live REPL, keep the focus where it was
* [package.el](https://www.gnu.org/software/emacs/manual/html_node/emacs/Packages.html)
  (2007) and [MELPA](https://melpa.org) (2012) — browse, read about
  and install packages from inside the editor
* [desktop.el](https://www.gnu.org/software/emacs/manual/html_node/emacs/Saving-Emacs-Sessions.html)
  (1990s) — save the whole desktop, list it, bring it back
* [recentf](https://www.gnu.org/software/emacs/manual/html_node/emacs/File-Conveniences.html)
  (2002) — the files you visited, most recent first
* [guide-key](https://github.com/kai2nenobu/guide-key) (Tsunenobu Kai,
  2012) — the popup of the bindings that follow a prefix, which-key.el's
  direct ancestor
* [which-key.el](https://github.com/justbur/emacs-which-key) — the
  rewrite that reached Emacs 30's core: the popup gliter.which is the
  light version of
* [showkey.el](https://www.emacswiki.org/emacs/ShowKey) (Drew Adams,
  2015) — the keys you use as you use them, in a tooltip or a log frame;
  gliter.screenkey's ancestor
* [lynx](https://lynx.invisible-island.net/) (University of Kansas,
  1992) and [w3m](https://w3m.sourceforge.net) (Akinori Ito, 1995) —
  the text browsers whose dumps gliter.w3 renders
* [wls](https://github.com/joelkoen/wls) — "web ls": a site's urls from
  its sitemaps, gliter.w3's third viewer
* [viww](https://github.com/pundfoo/viww) (Rugved Pund, 2026) — the vi
  web wowser: eww's keys on curl and pandoc, gliter.w3's direct
  inspiration
* etags / `M-.` find-tag (mid-1980s, in Emacs since the beginning) — tags
  navigation over a generated index
* compile.el / `M-x compile` (mid-1980s) — the `*compilation*` buffer:
  command echo, streaming output, underlined errors, next-error

**Vim / Neovim**, the ports gliter builds on or borrows from:

* [mbbill/undotree](https://github.com/mbbill/undotree) (2012) — the undo
  history visualizer for Vim that the built-in `:Undotree` descends from
* [tpope/vim-dispatch](https://github.com/tpope/vim-dispatch) (2013) —
  `:Make` asynchronous, the compiler's output as it happens: gliter.make
  borrows the asynchrony and the makeprg-per-buffer habit, and gives the
  output Emacs' buffer back
* [stevearc/oil.nvim](https://github.com/stevearc/oil.nvim) (2022) — edit
  the filesystem like a buffer: wdired, as a whole plugin
* [lth-go/nvim-expand-region](https://github.com/lth-go/nvim-expand-region)
  (2025) — the ladder order `treesitterRE` follows
* [jceb/multicursor-mappings.nvim](https://github.com/jceb/multicursor-mappings.nvim)
  (2026) — the multicursor bindings gliter.multicursor's `keys` table
  started from
* [wellle/targets.vim](https://github.com/wellle/targets.vim) (2014) — the
  quote and separator text objects gliter.textobj ports, seeking included
* [matchit.vim](https://github.com/vim/vim/blob/master/runtime/pack/dist/opt/matchit/plugin/matchit.vim)
  (Raul Segura Acevedo, 1996; Benji Fisher) — the keyword-matching `%`
  gliter.matchit walks; it ships with Neovim as an optional plugin and
  does more than gliter's take
* [justify.vim](https://github.com/vim/vim/blob/master/runtime/pack/dist/opt/justify/plugin/justify.vim)
  (Preben "Peppe" Guldberg, 1998) — the space distribution gliter.justify
  puts on top of the reflow
* [Vigemus/iron.nvim](https://github.com/Vigemus/iron.nvim) (2017) — the
  per-filetype REPL sending gliter.repl follows
* [rockerBOO/awesome-neovim](https://github.com/rockerBOO/awesome-neovim)
  — the plugin directory gliter.pack (deprecated) indexed and cached
* [which-key.nvim](https://github.com/folke/which-key.nvim) (2021) — the
  popup gliter.which is the light version of
* [screenkey.nvim](https://github.com/NStefan002/screenkey.nvim) (2024) —
  pressed keys in a float, like the X11 screenkey tool before it
* [alex-popov-tech/store.nvim](https://github.com/alex-popov-tech/store.nvim)
  — the package browser to use now that gliter.pack is deprecated
