--- gliter.multicursor — keys for the built-in multicursors (Neovim 0.13+).
---
--- setup() maps the keys table below: every name to its key, any name
--- set to false stays unmapped, and extra_keys appends raw
--- { mode, key, rhs, opts } rows on top (flash.nvim jumps, a <Tab>
--- that clears search highlighting or the cursors, ...; examples in
--- doc/gliter.multicursor.md).
---
--- The mappings started from
--- https://github.com/jceb/multicursor-mappings.nvim: the helpers below are
--- jceb's (lightly adapted) — they drive the built-in commands ("Q", "q=",
--- "]C", "zqn", …) through nvim_feedkeys(). Note that "q=" only toggles the
--- buffer-local 'follow' option (:h 'follow') — "1q=" sets it, "2q=" clears
--- it — so the option could equally be set via vim.bo.follow. The
--- multicursor idea itself is older — it comes from Emacs (magnars'
--- multiple-cursors.el, 2012), like the rest of gliter.
---
--- "<M-i>" feeds the built-in's "Q" — a cursor at the cursor
--- position, counts and all — and in Visual mode the built-in's
--- {Visual}Q, a cursor on every line of the selection. The two
--- place-and-step keys live under <Leader>c, next to the reset keys
--- (Alt-key escapes travel badly through terminals: <M-i>J kept
--- arriving as <M-i> and a stray J). <M-BS> belongs to
--- gliter.treesitterRE here (walk the selection ladder back down), so
--- it is not among the defaults; <Esc> clears all cursors instead.
--- Buffer-local maps (netrw's own keys inside netrw buffers, for
--- instance) win over these global ones.

local M = {}

M.did_setup = false

local clear_cursors = function()
  -- use what ever you could efford here<
  vim.api.nvim_buf_clear_namespace(0,vim.api.nvim_create_namespace("nvim.multicursor"), 0, -1)
end

-- 1Q (forced add, never the toggle: a walk that wraps around onto a
-- match it already cursored must not take the cursor back off), a
-- step, 'follow' off around both (the step must only move the cursor
-- you are placing with, not replay at every cursor) and back on at
-- the end. No count: place one cursor and step — the walking press,
-- held across a stretch of lines. A count places that many cursors
-- and leaves the primary ON the last one — 3<Leader>cj cursors three
-- lines, and the edit that follows lands three times, not four (the
-- primary cursor edits too, wherever it stands).
local add_cursor_and_move = function(opts)
    local lopts = opts or {}
    local count = lopts.count or tonumber(vim.v.count1) or 1
    vim.api.nvim_feedkeys("2q=", "n", false)
    vim.api.nvim_feedkeys("1Q", "n", false)
    if count > 1 then
        for _ = 1, count - 1 do
            vim.api.nvim_feedkeys(lopts.movement, "n", false)
            vim.api.nvim_feedkeys("1Q", "n", false)
        end
    else
        vim.api.nvim_feedkeys(lopts.movement, "n", false)
    end
    vim.api.nvim_feedkeys("q=", "n", false) -- should i set the option for it instead?
end

-- The skip pair of the walk: no Q at all — the match under the cursor
-- goes un-taken — and the step wrapped in 'follow' off/on, exactly
-- like add_cursor_and_move's (the step must only move the primary
-- cursor, not replay at every cursor). <C-n> takes, <C-s> declines and
-- steps on, <C-m> steps back to the one you declined.
local skip_to = function(step)
    vim.api.nvim_feedkeys("2q=", "n", false)
    vim.api.nvim_feedkeys(step, "n", false)
    vim.api.nvim_feedkeys("q=", "n", false)
end

local function literal_pattern_from_lines(lines_tbl)
  local esc = {}
  for i, l in ipairs(lines_tbl) do
    esc[i] = l:gsub("\\", "\\\\")
  end
  return "\\V" .. table.concat(esc, "\\n")
end

local select_all = function(opts)
  local lopts = opts or {}
  if lopts.visual_mode then
    local selection = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."))
    vim.fn.setreg("/", literal_pattern_from_lines(selection))
    vim.api.nvim_feedkeys("v`<mx", "n", false)
  else
    vim.api.nvim_feedkeys("wbmx", "n", false)
    vim.fn.setreg("/", "\\V\\<" .. vim.fn.expand("<cword>") .. "\\>")
  end
  vim.schedule(function()
    vim.api.nvim_feedkeys("1Qzqn`xq=", "n", false)
  end)
end

local search = function(opts)
  local lopts = opts or {}
  local count = tonumber(vim.v.count1) or 1 -- v:count does not survive the schedule below
  local ns = vim.api.nvim_create_namespace("nvim.multicursor")
  local marks = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {})
  local search_next = lopts.forward_search and "n" or "N"
  if #marks ~= 0 and not lopts.force then
    add_cursor_and_move({ movement = search_next, count = count })
    return
  end
  if lopts.visual_mode then
    local selection = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."))
    vim.fn.setreg("/", literal_pattern_from_lines(selection))
    vim.api.nvim_feedkeys("v`<", "n", false)
  else
    vim.api.nvim_feedkeys("wb", "n", false)
    vim.fn.setreg("/", "\\V\\<" .. vim.fn.expand("<cword>") .. "\\>")
  end
  vim.schedule(function()
    add_cursor_and_move({ movement = search_next, count = count })
  end)
end

--- The named keys — shown in the README's default setup too. Every name
--- maps to exactly the keys its comment describes; set one to false to
--- keep it unmapped.
local defaults = {
  keys = {
    clear = "<Esc>", -- clear all multicursors
    follow = "<C-=>", -- toggle 'follow' (q=): do motions replay at
    -- every cursor or not
    insert = "<M-i>", -- n: a cursor at the cursor position (Q; a
    -- count forces it — 1<M-i> adds, 2<M-i> removes). x: the built-in's
    -- {Visual}Q — a cursor on EVERY line of the selection, at the
    -- cursor column
    below = "<Leader>cj", -- n: place a cursor and move down; a count
    -- places that many cursors and leaves you on the last
    -- (3<Leader>cj: three lines, you on the third)
    above = "<Leader>ck", -- n: place a cursor and move up; the count
    -- works the same way
    skip_next = "<C-s>", -- skip: no cursor at the match under the
    -- cursor, move to the next match
    skip_prev = "<C-m>", -- skip backwards: back to the previous match,
    -- no cursor placed. <C-m> IS <CR> (both are 0x0D): in quickfix and
    -- location-list windows Enter keeps its builtin jump instead
    remove_prev = "<C-b>", -- remove the previous cursor [up] ([CQ)
    remove_next = "<C-f>", -- remove the next cursor [down] (]CQ)
    all = "<M-a>", -- a cursor at every occurrence of the word under
    -- the cursor / of the selection
    next = "<C-n>", -- a cursor at the next occurrence, after setting
    -- the search pattern to the word / the selection
    prev = "<C-p>", -- the same, backwards
    next_reset = "<Leader>cn", -- reset the search pattern, then the
    -- next occurrence
    prev_reset = "<Leader>cp", -- reset the search pattern, then the
    -- previous occurrence
  },
  extra_keys = {}, -- raw rows on top: { mode, key, rhs, opts }
}

--- The named keys become { mode, key, rhs, opts } rows, one
--- vim.keymap.set() per row — in the order the defaults table lists
--- them. M.keys holds the result (the defaults at load, the merged
--- configuration after setup).
local function build_rows(keys)
  local rows = {}
  local function add(mode, key, rhs, opts)
    if key then
      rows[#rows + 1] = { mode, key, rhs, opts }
    end
  end
  add("n", keys.clear, clear_cursors, { noremap = true, desc = "Clear all multicursors" })
  add("n", keys.follow, "q=")
  -- Q is the built-in's key; the pass-through mapping keeps the count
  -- (1Q adds, 2Q removes) and gives the key a home in the keys table
  add("n", keys.insert, function()
    local count = vim.v.count == 0 and "" or tostring(vim.v.count)
    vim.api.nvim_feedkeys(count .. "Q", "n", false)
  end, { noremap = true, desc = "Insert a cursor at the cursor position and disable 'follow'" })
  add("x", keys.insert, "Q", { noremap = true, desc = "A cursor on every line of the selection" })
  add("n", keys.below, function()
    add_cursor_and_move({ movement = "j" })
  end, { noremap = true, desc = "Place a cursor and move down (a count: that many cursors, the last one under you)" })
  add("n", keys.above, function()
    add_cursor_and_move({ movement = "k" })
  end, { noremap = true, desc = "Place a cursor and move up (a count: that many cursors, the last one under you)" })
  -- <C-m> IS <CR> (both are 0x0D), so this mapping replaces Enter in every
  -- window that has no <CR> mapping of its own — quickfix and location-list
  -- windows jump through a *builtin* Enter, and a global <C-m> is exactly
  -- how "Enter does nothing in the quickfix window" happens. In those
  -- windows the builtin jump runs instead (normal! keeps mappings out).
  add("n", keys.skip_next, function()
    skip_to("n")
  end, { noremap = true, desc = "Skip: no cursor here, move to the next match" })
  add("n", keys.skip_prev, function()
    if vim.bo.buftype == "quickfix" then
      -- `:exe "normal! \r"` — the one way to press Enter through :normal
      -- (the builtin quickfix/location-list jump)
      vim.cmd([[execute "normal! \r"]])
      return
    end
    skip_to("N")
  end, { noremap = true, desc = "Skip backwards: previous match, no cursor placed (quickfix: jump to entry)" })
  add("n", keys.remove_prev, "[CQq=", { noremap = true, desc = "Remove previous cursor [up]" })
  add("n", keys.remove_next, "]CQq=", { noremap = true, desc = "Remove next cursor [down]" })
  add("n", keys.all, function()
    select_all()
  end, { noremap = true, desc = "Place cursor at all occurrences of the word under the cursor" })
  add("x", keys.all, function()
    select_all({ visual_mode = true })
  end, { noremap = true, desc = "Place cursor at all occurrences of selection" })
  add("n", keys.next, function()
    search({ forward_search = true, visual_mode = false })
  end, { noremap = true, desc = "Set the initial search pattern, place cursor and move to the next occurrence of the word under the cursor" })
  add("x", keys.next, function()
    search({ forward_search = true, visual_mode = true })
  end, { noremap = true, desc = "Set the initial search pattern, place cursor and move to the next occurrence of selection" })
  add("n", keys.prev, function()
    search({ forward_search = false, visual_mode = false })
  end, { noremap = true, desc = "Set the initial search pattern, place cursor and move to the previous occurrence of the word under the cursor" })
  add("x", keys.prev, function()
    search({ forward_search = false, visual_mode = true })
  end, { noremap = true, desc = "Set the initial search pattern, place cursor and move to the previous occurrence of selection" })
  add("n", keys.next_reset, function()
    search({ forward_search = true, visual_mode = false, force = true })
  end, { noremap = true, desc = "Reset the search pattern, place cursor and advance to the next occurrence of the word under the cursor" })
  add("x", keys.next_reset, function()
    search({ forward_search = true, visual_mode = true, force = true })
  end, { noremap = true, desc = "Reset the search pattern, place cursor and advance to the next occurrence of selection" })
  add("n", keys.prev_reset, function()
    search({ forward_search = false, visual_mode = false, force = true })
  end, { noremap = true, desc = "Reset the search pattern, place cursor and advance to the previous occurrence of the word under the cursor" })
  add("x", keys.prev_reset, function()
    search({ forward_search = false, visual_mode = true, force = true })
  end, { noremap = true, desc = "Reset the search pattern, place cursor and advance to the previous occurrence of selection" })
  return rows
end

M.defaults = defaults
M.keys = build_rows(defaults.keys) -- the rows setup() applies until told otherwise

---@param opts table? { keys?: table named keys (any you leave out keep
---their defaults; a false unmaps), extra_keys?: table raw
---{ mode, key, rhs, opts } rows on top }
function M.setup(opts)
  local has_013 = vim.fn.has("nvim-0.13") == 1
  if not has_013 then
    vim.notify("[gliter] multicursor needs Neovim >= 0.13", vim.log.levels.ERROR)
  end
  if opts and opts.keys ~= nil and opts.keys[1] ~= nil then
    -- raw rows in `keys` are the old shape: named keys there silently
    -- unmap everything, so say so instead
    vim.notify(
      "[gliter] multicursor: keys is the NAMED table (keys = { insert = '<M-i>' }); raw { mode, key, rhs } rows go to extra_keys",
      vim.log.levels.WARN
    )
  end
  M.did_setup = true
  local cfg = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  local rows = build_rows(cfg.keys)
  for _, r in ipairs(cfg.extra_keys or {}) do
    rows[#rows + 1] = r
  end
  M.keys = rows
  if has_013 then -- the built-in commands do not exist before 0.13
    for _, b in ipairs(rows) do
      vim.keymap.set(b[1], b[2], b[3], b[4])
    end
  end
  return M
end

return M
