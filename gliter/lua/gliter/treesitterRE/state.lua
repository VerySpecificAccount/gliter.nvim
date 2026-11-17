-- Selection history (undo), direction memory and the <BS> candidate ladder.
--
-- History entries are { before, after, kind }:
--   before -- the region the selection came from (nil: came from Normal mode)
--   after  -- the region the selection became
--   kind   -- 'op' (a normal operation, undoable) | 'descent' (an inward
--             step taken by shrink itself; a following shrink continues
--             inward instead of popping it, so it can never ping-pong)

local M = {}

local state = {
  buf = nil,
  tick = -1,
  history = {},
  last_dir = nil, -- 'left' | 'right': direction of the last lateral expand
  ladder = nil,   -- the <BS> walk: { seed, candidates, index }
}

function M.regions_equal(a, b)
  if a == nil or b == nil then
    return a == b
  end
  return a.s[1] == b.s[1] and a.s[2] == b.s[2]
    and a.e[1] == b.e[1] and a.e[2] == b.e[2]
end

local function fresh(buf)
  state.buf = buf
  state.tick = vim.api.nvim_buf_get_changedtick(buf)
  state.history = {}
  state.last_dir = nil
  state.ladder = nil
end

-- The live state, invalidated whenever the buffer or its text changes.
function M.get()
  local buf = vim.api.nvim_get_current_buf()
  if state.buf ~= buf or state.tick ~= vim.api.nvim_buf_get_changedtick(buf) then
    fresh(buf)
  end
  return state
end

function M.reset()
  fresh(vim.api.nvim_get_current_buf())
end

-- push a transition; `before` nil means "came from normal mode"
function M.push(before, after)
  local st = M.get()
  st.history[#st.history + 1] = { before = before, after = after, kind = 'op' }
  if #st.history > 100 then
    table.remove(st.history, 1)
  end
end

-- push an inward step taken by shrink; replaces the descent entry it
-- continues from so the history never stacks up ping-pong pairs.
function M.push_descent(before, after)
  local st = M.get()
  local top = st.history[#st.history]
  if top and top.kind == 'descent' and M.regions_equal(top.after, before) then
    table.remove(st.history)
  end
  st.history[#st.history + 1] = { before = before, after = after, kind = 'descent' }
  if #st.history > 100 then
    table.remove(st.history, 1)
  end
end

--- Undo one step for the region `current`.
--- Returns ('select', region) -- restore that region (a normal undo)
---         ('exit', nil)      -- the step came from Normal mode: leave Visual
---         ('descend', nil)   -- `current` came from a shrink: keep going in
---         ('none', nil)      -- nothing recorded for this region
function M.pop(current)
  local st = M.get()
  for i = #st.history, 1, -1 do
    local entry = st.history[i]
    if M.regions_equal(entry.after, current) then
      if entry.kind == 'descent' then
        return 'descend'
      end
      for j = #st.history, i, -1 do
        table.remove(st.history, j)
      end
      if entry.before == nil then
        return 'exit'
      end
      return 'select', entry.before
    end
  end
  return 'none'
end

-- --------------------------------------------------------------- the ladder

-- The <BS> walk state, or nil when there is none.
function M.ladder_get()
  return M.get().ladder
end

-- Start (or restart) a ladder around `seed`. `candidates` may be nil,
-- meaning "not computed yet" (the next expand computes them from the seed).
function M.ladder_set(seed, candidates)
  local st = M.get()
  st.ladder = { seed = seed, candidates = candidates, index = 0 }
  return st.ladder
end

return M
