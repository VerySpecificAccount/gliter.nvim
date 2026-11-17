# gliter.w3

The web in a buffer. `:GliterW3 example.com` fetches the page and shows
it as text, links followable from the keyboard while a spinner covers
the load; an argument that is not an address is a search.

```lua
require('gliter').setup { w3 = {} }
-- or on its own:
require('gliter.w3').setup {}
```

## The viewers

gliter.w3 renders nothing itself — it drives whichever viewer is on your
`$PATH`, one page at a time:

| Viewer | Runs | What you see |
|--------|------|--------------|
| `pandoc` | curl fetches, pandoc turns the html into markdown, gliter post-processes it | the page as text — links underlined with their urls kept, headings in Title colors, code in Comment colors |
| `lynx` | `lynx -dump <url>` | the same, from the oldest browser still maintained — [lynx](https://lynx.invisible-island.net/) (University of Kansas, 1992); its numbered reference list becomes the page's link table |
| `w3m` | curl fetches, `w3m -T text/html -dump` renders the file | the page as text, tables and all — [w3m](https://w3m.sourceforge.net) (Akinori Ito, 1995); a w3m dump carries no urls, so the links come out of the html gliter fetched and land underlined on their labels |
| `webls` | `wls <site>` | not the page but the site's whole url list, crawled from its sitemaps (robots.txt included) — [wls](https://github.com/joelkoen/wls), "web ls", the netrw move applied to the web |

`engine = 'auto'` (the default) takes the first of them it finds —
pandoc first (curl and pandoc both on `$PATH`), lynx when there is no
pandoc, then w3m, then webls. Name one in the setup to pin it, or put it
in front of the url on the command line — `:GliterW3 lynx example.com`
— and it stays the viewer of that buffer: `<CR>`, `H` and `R` all
re-use it, so a webls buffer's `<CR>` lists the site of the link under
the cursor. A viewer's binary is an option, and `false` turns the
viewer off.

Images are not shown — no alt text, no placeholder, nothing: an
`![alt](url)` and a `data:image/...;base64,...` blob alike leave not a
character on the line. Links whose href is not a page (`data:`,
`mailto:`, `javascript:`, `tel:`) render as their text and carry
nothing followable.

## The keys

| Key | Action |
|-----|--------|
| `<CR>` | open the link on this line — the entry under the cursor, a `[n]` marker resolved through the reference table, a line that is nothing but a url, the first bare url on the line |
| `]l` / `[l` | the next / previous link, wrapping around |
| `gl` | every link of the page in the quickfix — search and jump between them the vim way |
| `H` | the previous page (each buffer keeps its own history) |
| `R` | this page again |

`:GliterW3` with no argument prompts for an address — the command line
`input()` gives, with [gliter.cmd](gliter.cmd.md)'s readline keys and the
ghost of the addresses opened before on it when it is set up (`Up`/`Down`
walk them in the `@` history).

## Addresses and searches

An argument with a scheme (`http://…`) is used as-is; a word with dots
and no spaces (`example.com`, `example.com/page`) becomes `https://…`;
anything else is a search — DuckDuckGo's html endpoint, which renders
nicely as text. `search` is an option.

## While the page loads

The fetch is asynchronous: the buffer shows a spinner and the seconds
while the page comes in, the editor never freezes, and a navigation that
starts before the page arrives (`H`, `R`, a new `<CR>`) abandons the
fetch. `timeout` (30 s by default) is the ceiling a fetch gets.

## Options

```lua
require('gliter.w3').setup {
  engine = 'auto',    -- 'auto' | 'pandoc' | 'lynx' | 'w3m' | 'webls'
  timeout = 30,       -- seconds a fetch gets before it is killed
  search = 'https://duckduckgo.com/html/?q=%s', -- keywords go here
  curl = 'curl',      -- the fetcher of the pandoc and w3m pipelines
  browsers = { pandoc = 'pandoc', lynx = 'lynx', w3m = 'w3m', webls = 'wls' },
                      -- the renderers; a path works, false turns one off
  keys = {
    follow = '<CR>',  -- open the link on this line
    next_link = ']l', -- the next link, wrapping around
    prev_link = '[l', -- the previous link
    links = 'gl',     -- every link in the quickfix
    back = 'H',       -- the previous page
    reload = 'R',     -- this page again
  },
}
```

## Stolen from

A chain of Emacs browsers: [W3](https://www.w3.org/History/1995/WWW/EmacsWWW)
(William Perry, 1993) was the first web browser inside Emacs; eww — the
Emacs Web Wowser (Lars Ingebrigtsen, 2013) — replaced it in core with a
lighter one rendered by shr, its Simple HTML Renderer;
[viww](https://github.com/pundfoo/viww) (Rugved Pund, 2026) ported eww's
keys to Neovim on curl and pandoc. gliter.w3 is viww's interface over
the viewers you already have — lynx and w3m render, wls lists, and the
pandoc pipeline is viww's own — with a spinner over the load.

Requires Neovim 0.10+ (`vim.system`), plus one of pandoc with curl,
lynx, w3m or wls on your `$PATH`.
