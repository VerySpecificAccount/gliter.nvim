-- gliter — one runtime path, several modules: extras for Neovim's built-in
-- netrw, :Undotree, multicursors and ctags support, treesitterRE selection
-- expansion, gliter.zoom (text-scale for the terminal: the current
-- window/buffer redrawn in the Unicode Mathematical Alphanumeric
-- alphabet — 𝐁𝐨𝐥𝐝, 𝙼𝚘𝚗𝚘𝚜𝚙𝚊𝚌𝚎, Sᴍᴀʟʟ Cᴀᴘꜱ — per buffer), gliter.make
-- (Emacs' *compilation* buffer for :make), gliter.repl (a REPL
-- per filetype with Spacemacs' send keys), gliter.textobj (targets.vim's
-- quotes and separators), gliter.sessions (:mksession with a memory),
-- gliter.readme (the project's readme, tracked like recent files),
-- gliter.justify (g=, the paragraph reflowed both-margins-flush),
-- gliter.matchit (M, % for keywords), gliter.tohtml (:GliterTohtml,
-- the buffer out in its syntax colors), gliter.w3 (the web in a
-- buffer), gliter.cmd (readline's keys on the built-in command line,
-- and the history's continuation ghosted after it), gliter.which
-- (a light which-key popup over :map) and gliter.screenkey (shows
-- the keys you press, for screencasts).
--
-- Modules are opt-in: require('gliter').setup(opts) only
-- sets up the modules named in opts, and setup() without a table loads
-- nothing. This file exists for people who configure without calling setup()
-- from Lua: stash the options table in `vim.g.gliter` before startup (init
-- files run before plugin/ files, so init.vim's `let g:gliter = {...}` or an
-- early `vim.g.gliter = {...}` in init.lua both land here) and it is handed
-- to setup() when this file is sourced.
--
-- A setup() call from your init.lua sets vim.g.loaded_gliter and this file
-- stays out of the way entirely.
if vim.g.loaded_gliter == nil and vim.g.gliter ~= nil then
  require('gliter').setup(vim.g.gliter)
end
