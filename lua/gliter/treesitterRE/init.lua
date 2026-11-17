-- gliter.treesitterRE — expand-region for the treesitter age.
--
-- One key grows the visual selection through a ladder of regions; another
-- walks it back down. The RE stands for region-expand (Emacs had it first —
-- expand-region; the ladder order follows nvim-expand-region, its Neovim
-- descendant). Works with treesitter where there is a parser and with words,
-- bracket pairs and paragraphs where there is not.
--
-- Usage (a module of gliter — see gliter's README; gliter.setup() only sets
-- up the modules you name):
--   require('gliter').setup { treesitterRE = {} }                -- defaults
--   require('gliter').setup { treesitterRE = { keys = {
--     expand       = '<M-n>',  -- cycle same-LEVEL nodes (siblings AND
--                              -- the neighbors' tokens), wrapping around
--     contract     = '<M-p>',  -- the same cycle, backwards
--     expand_right = '<M-f>',  -- grow the selection one word right (like w/e)
--     expand_left  = '<M-b>',  -- grow the selection one word left (like b)
--     expand_up    = '<BS>',   -- expand-region ladder: pair inner (trimmed)
--                              -- -> pair inner (raw) -> pair with delimiters
--                              -- -> ... -> statement / paragraph
--     expand_down  = '<M-BS>', -- undo the last change; on a manual
--                              -- selection, shrink one level inward
--     left_out     = '<M-u>',  -- push the LEFT edge out by ONE CHAR (v_h)
--     left_in      = '<M-o>',  -- pull the LEFT edge in by ONE CHAR (v_l)
--     hop_word     = '<M-w>',  -- viw at the edge of the last lateral
--                              -- motion (right edge after <M-f>, left
--                              -- edge after <M-b>); hops when the edge
--                              -- word is already selected
--     next_sibling = 'gl',     -- next sibling; climbs a level when the
--     prev_sibling = 'gh',     -- chain runs out (unlike <M-n>/<M-p>)
--     next_scope   = 'gj',     -- next function/if/loop/... (paragraph
--     prev_scope   = 'gk',     -- without a treesitter parser)
--   } } }
--   require('gliter').setup { treesitterRE = { keys = false } } -- <Plug> only
--   require('gliter.treesitterRE').setup { keys = { ... } }     -- module directly
--
-- Set any single key to `false` to skip creating that mapping.
--
-- Terminal note: <M-BS> needs the terminal to deliver Alt+Backspace as
-- ESC+DEL (0x1b 0x7f) — kitty / WezTerm / alacritty / iTerm2 do; inside
-- tmux also `set -sg escape-time 10`.

local ops = require('gliter.treesitterRE.ops')

local M = {}

M.did_setup = false

M.defaults = {
  keys = {
    expand = '<M-n>',
    contract = '<M-p>',
    expand_right = '<M-f>',
    expand_left = '<M-b>',
    expand_up = '<BS>',
    expand_down = '<M-BS>',
    left_out = '<M-u>',
    left_in = '<M-o>',
    hop_word = '<M-w>',
    next_sibling = 'gl',
    prev_sibling = 'gh',
    next_scope = 'gj',
    prev_scope = 'gk',
  },
}

-- <Plug> mappings for manual configuration, created when the module loads
-- (the same set the standalone plugin registered from plugin/).
local plugs = {
  ['<Plug>(TreesitterREExpand)'] = function()
    ops.cycle_sibling(1)
  end,
  ['<Plug>(TreesitterREContract)'] = function()
    ops.cycle_sibling(-1)
  end,
  ['<Plug>(TreesitterREShrink)'] = ops.shrink,
  ['<Plug>(TreesitterREUp)'] = ops.expand_up,
  ['<Plug>(TreesitterRERight)'] = ops.expand_right,
  ['<Plug>(TreesitterRELeft)'] = ops.expand_left,
  ['<Plug>(TreesitterRELeftOut)'] = ops.left_out,
  ['<Plug>(TreesitterRELeftIn)'] = ops.left_in,
  ['<Plug>(TreesitterREHopWord)'] = ops.hop_word,
  ['<Plug>(TreesitterRENextSibling)'] = function()
    ops.sibling(1)
  end,
  ['<Plug>(TreesitterREPrevSibling)'] = function()
    ops.sibling(-1)
  end,
  ['<Plug>(TreesitterRENextScope)'] = function()
    ops.scope(1)
  end,
  ['<Plug>(TreesitterREPrevScope)'] = function()
    ops.scope(-1)
  end,
}

for lhs, rhs in pairs(plugs) do
  vim.keymap.set({ 'n', 'x' }, lhs, rhs, { silent = true, desc = 'gliter.treesitterRE' })
end

---@param opts table? { keys?: table|false } — false creates no default keys
function M.setup(opts)
  opts = opts or {}
  local keys
  if opts.keys == false then
    keys = {}
  else
    keys = vim.tbl_deep_extend('force', M.defaults.keys, opts.keys or {})
  end

  local actions = {
    expand = function()
      ops.cycle_sibling(1)
    end,
    contract = function()
      ops.cycle_sibling(-1)
    end,
    shrink = function()
      ops.shrink()
    end,
    expand_right = function()
      ops.expand_right()
    end,
    expand_left = function()
      ops.expand_left()
    end,
    expand_up = function()
      ops.expand_up()
    end,
    expand_down = function()
      ops.shrink()
    end,
    left_out = function()
      ops.left_out()
    end,
    left_in = function()
      ops.left_in()
    end,
    hop_word = function()
      ops.hop_word()
    end,
    next_sibling = function()
      ops.sibling(1)
    end,
    prev_sibling = function()
      ops.sibling(-1)
    end,
    next_scope = function()
      ops.scope(1)
    end,
    prev_scope = function()
      ops.scope(-1)
    end,
  }

  for name, lhs in pairs(keys) do
    local action = actions[name]
    if action and lhs and lhs ~= false and lhs ~= '' then
      vim.keymap.set({ 'n', 'x' }, lhs, action, {
        silent = true,
        desc = 'treesitterRE ' .. name,
      })
    end
  end

  M.did_setup = true
end

return M
