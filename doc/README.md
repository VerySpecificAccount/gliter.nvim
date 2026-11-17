# gliter documentation

One page per module. Every module is **opt-in** — `setup()` touches
only the modules you name in its options; a module you leave out is
never loaded.

Back to the [main README](../README.md).

---

## Modules

### [`gliter.netrw`](gliter.netrw.md)
Marks, bookmarks, one-key commands, regexp marking with a live
highlight, and in-place editing for the built-in netrw.
*(Stolen from dired 1986 + wdired. Needs Neovim 0.12+.)*

### [`gliter.undotree`](gliter.undotree.md)
A `<Leader>u` toggle, colors, and a bottom diff window for the
built-in `:Undotree`.
*(Stolen from undo-tree 2009. Needs Neovim 0.12+.)*

### [`gliter.multicursor`](gliter.multicursor.md)
Keys for the built-in multicursors: `<M-i>`, `<Leader>cj`/`<Leader>ck`,
`<M-a>`, `<C-n>`/`<C-p>`, `<C-s>`/`<C-m>`, `<C-b>`/`<C-f>`.
*(Stolen from multiple-cursors 2012. Needs Neovim 0.13+.)*

### [`gliter.treesitterRE`](gliter.treesitterRE.md)
Expand-region: one key grows the selection up a semantic ladder
(parser optional).
*(Stolen from expand-region 2011. Needs Neovim 0.9+.)*

### [`gliter.ctags`](gliter.ctags.md)
The built-in ctags support with better defaults, a one-command
interface, and quickfix.
*(Stolen from etags, mid-1980s. Needs Neovim 0.10+.)*

### [`gliter.make`](gliter.make.md)
Per-filetype `'makeprg'` and the `*compilation*` buffer: streaming,
terminal-colored output whose errors fill the quickfix — plus a
runner (file, selection, grep, shells) through one settable output
function.
*(Stolen from compile, mid-1980s. Needs Neovim 0.9+.)*

### [`gliter.repl`](gliter.repl.md)
A REPL per filetype with Spacemacs' send keys
(`<Leader>ls`/`lS`/`ll`/`lb`) and headless evaluation
(`<Leader>le`).
*(Stolen from SLIME 2003. Needs Neovim 0.9+.)*

### [`gliter.textobj`](gliter.textobj.md)
targets.vim's quote and separator objects: `vi"` exactly where Vim's
own works, seeking where it gives up; `in"`/`il"`, `i,` between the
commas.
*(Stolen from targets.vim 2014. Needs Neovim 0.9+.)*

### [`gliter.sessions`](gliter.sessions.md)
`:mksession` with a memory: `<Leader>ss` saves the session into its
project and remembers it, `<Leader>sl` lists every known session in a
float.
*(Stolen from desktop.el, 1990s. Needs Neovim 0.9+.)*

### [`gliter.readme`](gliter.readme.md)
`<Leader>rr` opens (or creates) the project's readme, `<Leader>rl`
lists every readme you touched, most recent first.
*(Stolen from recentf 2002. Needs Neovim 0.9+.)*

### [`gliter.justify`](gliter.justify.md)
`g=` and `:GliterJustify`: reflow the paragraph (or the selection, or
a range) to the width and justify it — both margins flush, the last
line ragged.
*(Stolen from fill.el 1980s + justify.vim 1998. Needs Neovim 0.9+.)*

### [`gliter.matchit`](gliter.matchit.md)
`M` (the key you gave `%`) jumps between the words that bracket a
block — `if`/`end`, `function`/`endfunction`, `<div>`/`</div>` —
nesting counted; `gM` the other way; plain `%` on everything else.
*(Stolen from matchit.vim 1996. Needs Neovim 0.9+.)*

### [`gliter.tohtml`](gliter.tohtml.md)
`:GliterTohtml`: the buffer (or the selection) out as HTML with its
syntax colors, as Markdown, or as PDF typeset by groff.
*(Stolen from 2html.vim 2001 + htmlize.el 1997 + troff 1973. Needs Neovim 0.10+.)*

### [`gliter.w3`](gliter.w3.md)
The web in a buffer: `:GliterW3 <url>` — curl fetches and pandoc
renders the page (lynx without pandoc, w3m with the links taken out,
wls lists the site); links followable from the keyboard, `]l`/`[l`
walk them, `gl` quickfixes them, `H` goes back, `R` reloads, keywords
search DuckDuckGo.
*(Stolen from W3 1993 → eww 2013 → viww 2026. Needs Neovim 0.10+.)*

### [`gliter.cmd`](gliter.cmd.md)
Readline's keys on the built-in command line
(C-a/C-b/C-f/C-d/C-k/C-t, M-b/M-f, M-BS/M-d), and fish's ghost: the
history's continuation dimmed after the line. Tab/S-Tab untouched,
the wildmenu keeps its own keys.
*(Stolen from readline 1988 + fish 2005. Needs Neovim 0.10+.)*

### [`gliter.which`](gliter.which.md)
A light which-key: pause after a prefix (`<Leader>`, `g`, `z`, ...)
and a popup lists the mappings that continue it, straight out of
`:map`.
*(Stolen from guide-key 2012 → which-key.el 2015 → which-key.nvim 2021. Needs Neovim 0.10+.)*

### [`gliter.screenkey`](gliter.screenkey.md)
Shows the keys you press as you press them — a float for screencasts
and demos.
*(Stolen from echo-keystrokes/view-lossage 1980s → showkey.el 2015 → screenkey.nvim 2024. Needs Neovim 0.9+.)*

### [`gliter.zoom`](gliter.zoom.md)
Glyph zoom and style ladders: `<Leader>=`/`<Leader>-` walk a
style ladder (bold → italic → script → fraktur → …), `<Leader>z`
toggles a thin sub-pixel glyph font drawn in braille, `<Leader>0`
resets.
*(Not in the main README's Modules table; documented here. Needs Neovim 0.9+.)*

---

## Deprecated

### [`gliter.pack`](gliter.pack.md) — **deprecated**
Emacs' `package.el` + MELPA loop over awesome-neovim's directory.
**Deprecated — use [store.nvim](https://github.com/alex-popov-tech/store.nvim)
instead.** A cached list is not a feature worth a module of its own.
*(Stolen from package.el 2007 + MELPA 2012. Needs Neovim 0.10+.)*

---

## See also

- [Main README](../README.md) — setup, the full options table, the
  "Stolen from Emacs" section, prior art
- [Adding a module](../README.md#adding-a-module) — how a new module
  joins the suite
