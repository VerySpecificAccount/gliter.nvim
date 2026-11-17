-- Treesitter helpers. Every function is defensive: it returns nil instead of
-- throwing when there is no parser or the parse fails.

local text = require('gliter.treesitterRE.text')

local M = {}

local OPENS = { ['('] = true, ['{'] = true, ['['] = true }
local CLOSES = { [')'] = true, ['}'] = true, [']'] = true }
local QUOTES = { ['"'] = true, ["'"] = true, ['`'] = true }

M.OPENS = OPENS
M.CLOSES = CLOSES
M.QUOTES = QUOTES

function M.get_parser(buf)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not ok or not parser then
    return nil
  end
  return parser
end

-- region -> treesitter range (0-based, end-exclusive)
local function region_to_range(buf, region)
  local entry = text.fetch_line(buf, region.e[1])
  local ci = text.col_to_ci(entry, region.e[2])
  local ec = entry.prefix[ci + 1] or entry.len
  return region.s[1] - 1, region.s[2] - 1, region.e[1] - 1, ec
end

function M.root_for(parser, buf, region)
  local sr, sc, er, ec = region_to_range(buf, region)
  local root = nil
  local ok, lang = pcall(function()
    return parser:language_for_range({ sr, sc, er, ec })
  end)
  if ok and lang then
    local ok2, trees = pcall(function()
      return lang:parse()
    end)
    if ok2 and trees and trees[1] then
      root = trees[1]:root()
    end
  end
  if not root then
    local ok2, trees = pcall(function()
      return parser:parse()
    end)
    if ok2 and trees and trees[1] then
      root = trees[1]:root()
    end
  end
  return root
end

-- treesitter range (0-based, end-exclusive) -> region; nil when no visible text
function M.range_to_region(buf, r0, c0, r1, c1)
  -- a start position at/after the end of its line ("just after a
  -- line-final `{`") denotes the first column of the next line — normalize
  -- it so the region is always settable and comparable
  if c0 > 0 then
    local s_len = text.line_len(buf, r0 + 1)
    if c0 >= s_len and r0 + 1 < vim.api.nvim_buf_line_count(buf) then
      r0 = r0 + 1
      c0 = 0
    end
  end
  local s = { r0 + 1, c0 + 1 }
  local e
  if c1 > 0 then
    -- c1 is the last byte (1-based) of the last char; convert to its first byte
    local entry = text.fetch_line(buf, r1 + 1)
    if #entry.chars == 0 then
      return nil
    end
    local ci = text.col_to_ci(entry, c1)
    e = { r1 + 1, text.ci_to_col(entry, ci) }
  else
    if r1 <= r0 then
      return nil
    end
    local lnum = r1 -- 1-based lnum of the line above the end line
    e = { lnum, text.line_end_col(buf, lnum) }
  end
  if s[1] > e[1] or (s[1] == e[1] and s[2] > e[2]) then
    return nil
  end
  return { s = s, e = e }
end

function M.node_region(buf, node)
  if not node then
    return nil
  end
  local ok, r0, c0, r1, c1 = pcall(function()
    return node:range()
  end)
  if not ok then
    return nil
  end
  return M.range_to_region(buf, r0, c0, r1, c1)
end

-- smallest named node whose range contains the region
function M.covering_node(parser, buf, region)
  local root = M.root_for(parser, buf, region)
  if not root then
    return nil
  end
  local sr, sc, er, ec = region_to_range(buf, region)
  local ok, node = pcall(function()
    return root:named_descendant_for_range(sr, sc, er, ec)
  end)
  if not ok or not node then
    return nil
  end
  return node
end

-- when a node is an explicitly delimited construct ({...}, (...), [...], "...")
-- return the region strictly between its delimiters
function M.delimited_region(buf, node)
  local n = node:child_count()
  if n < 2 then
    return nil
  end
  local fc = node:child(0)
  local lc = node:child(n - 1)
  if not fc or not lc or fc == lc or fc:named() or lc:named() then
    return nil
  end
  local ft = fc:type()
  local lt = lc:type()
  local pair = (OPENS[ft] and CLOSES[lt]) or (QUOTES[ft] and QUOTES[lt] and ft == lt)
  if not pair then
    return nil
  end
  local ok, fer, fec, lsr, lsc = pcall(function()
    local a, b = fc:end_()
    local c, d = lc:start()
    return a, b, c, d
  end)
  if not ok then
    return nil
  end
  if fer > lsr or (fer == lsr and fec >= lsc) then
    return nil
  end
  return M.range_to_region(buf, fer, fec, lsr, lsc)
end

function M.named_sibling(node, dir)
  local sib = node
  while true do
    if dir > 0 then
      sib = sib:next_sibling()
    else
      sib = sib:prev_sibling()
    end
    if not sib then
      return nil
    end
    if sib:named() then
      return sib
    end
  end
end

--- Depth of `node` (root = 0), counting every ancestor like node:parent().
function M.node_depth(node)
  local depth = 0
  local n = node
  while n:parent() do
    depth = depth + 1
    n = n:parent()
  end
  return depth, n
end

--- All named, non-zero-width nodes at exactly `depth` of `root`, in document
--- order. Used by the <M-n>/<M-p> cycle: the flat same-level sequence across
--- the whole tree — siblings AND the nodes continuing in neighboring
--- subtrees. Traversal is capped for very large trees.
function M.depth_nodes(root, depth, max_items)
  max_items = max_items or 4000
  local items = {}
  local visited = 0
  local stack = { { node = root, d = 0 } }
  while #stack > 0 do
    local it = table.remove(stack)
    local n, d = it.node, it.d
    visited = visited + 1
    if visited > 60000 then
      break
    end
    if d == depth then
      -- children are deeper than the target depth: no need to descend
      if n:named() then
        local ok, sr, sc, er, ec = pcall(function()
          return n:range()
        end)
        if ok and not (sr == er and sc == ec) then
          items[#items + 1] = n
          if #items >= max_items then
            break
          end
        end
      end
    else
      local cnt = n:child_count()
      for i = cnt - 1, 0, -1 do -- reverse: popping gives document order
        local c = n:child(i)
        if c then
          stack[#stack + 1] = { node = c, d = d + 1 }
        end
      end
    end
  end
  return items
end

local SCOPE_PATTERNS = {
  'function', 'method', 'class', 'interface', 'struct', 'enum', 'module',
  'program', 'chunk', 'source_file', 'if', 'for', 'while', 'repeat', 'with',
  'try', 'catch', 'switch', 'definition', 'declaration',
}

local function starts_or_ends_with(seg, p)
  return seg:sub(1, #p) == p or seg:sub(-#p) == p
end

function M.is_scope_type(t)
  for seg in t:gmatch('[^_]+') do
    for _, p in ipairs(SCOPE_PATTERNS) do
      if seg == p or starts_or_ends_with(seg, p) then
        return true
      end
    end
  end
  return false
end

-- nearest ancestor (including the node itself) that behaves like a scope
function M.enclosing_scope(node)
  local n = node
  while n do
    if M.is_scope_type(n:type()) then
      return n
    end
    n = n:parent()
  end
  return nil
end

return M
