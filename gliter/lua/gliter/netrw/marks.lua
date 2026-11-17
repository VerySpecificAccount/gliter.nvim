--- Persistent entry marks, shared across every netrw buffer, window and tab page.
---
--- `y`, `m`, `d` and `z` toggle a mark on the entry under the cursor (or on every line
--- of a Visual selection), like fff.nvim: `y` marks for copy, `m` for move, `d` for
--- delete, `z` for archive. Marking the same entry again with the same key unmarks it;
--- marking it with another key switches its mark kind. `Y`/`M`/`gD`/`Z` toggle the mark
--- on every entry at once. `p` applies the marks — copy and move entries are pasted
--- into the current directory, delete entries are removed after confirmation, archive
--- entries are packed into an archive (or extracted, when they are archives) — and the
--- marks that completed are cleared.
---
--- A fifth kind, `shell`, marks entries to run a shell command on; it is set with `%!`
--- and with the `*` family after `*!`, and consumed by `!` (see gliter.netrw.ops).
--- A sixth, `run`, marks entries for the one-at-a-time run: set with `%x` and the
--- `*x` family, consumed by `x`.
local M = {}

---@alias GliterNetrwMarkKind 'copy'|'move'|'delete'|'shell'|'archive'|'run'

---@type table<string, GliterNetrwMarkKind>
local kinds = {}
---@type string[]           insertion order, so pastes and messages stay predictable
local order = {}

local function changed()
  vim.api.nvim_exec_autocmds('User', { pattern = 'GliterNetrwClipboard', modeline = false })
end

local function index_of(path)
  for i, p in ipairs(order) do
    if p == path then
      return i
    end
  end
end

---@param path string
---@return GliterNetrwMarkKind?
function M.kind(path)
  return kinds[path]
end

---@param path string
---@return boolean
function M.has(path)
  return kinds[path] ~= nil
end

--- Toggle `kind` on each path: a path already marked with `kind` is unmarked, anything
--- else is marked with `kind`.
---@param kind GliterNetrwMarkKind
---@param paths string[]
function M.toggle(kind, paths)
  for _, p in ipairs(paths) do
    if kinds[p] == kind then
      kinds[p] = nil
      local i = index_of(p)
      if i then
        table.remove(order, i)
      end
    else
      if not kinds[p] then
        order[#order + 1] = p
      end
      kinds[p] = kind
    end
  end
  changed()
end

--- Select-all toggle (Y/M/gD). If every path already carries `kind`, unmark them all;
--- otherwise mark them all with `kind`.
---@param kind GliterNetrwMarkKind
---@param paths string[]
function M.toggle_all(kind, paths)
  if #paths == 0 then
    return
  end
  local all = true
  for _, p in ipairs(paths) do
    if kinds[p] ~= kind then
      all = false
      break
    end
  end
  if all then
    M.toggle(kind, paths)
  else
    M.set(kind, paths)
  end
end

--- Mark every path with `kind`, without toggling.
---@param kind GliterNetrwMarkKind
---@param paths string[]
function M.set(kind, paths)
  for _, p in ipairs(paths) do
    if not kinds[p] then
      order[#order + 1] = p
    end
    kinds[p] = kind
  end
  changed()
end

--- Paths marked with `kind`, in the order they were marked.
---@param kind GliterNetrwMarkKind
---@return string[]
function M.list(kind)
  local out = {}
  for _, p in ipairs(order) do
    if kinds[p] == kind then
      out[#out + 1] = p
    end
  end
  return out
end

--- Every marked path, all kinds together, in the order they were marked.
---@return string[]
function M.all()
  local out = {}
  for _, p in ipairs(order) do
    out[#out + 1] = p
  end
  return out
end

---@return boolean
function M.is_empty()
  return #order == 0
end

--- Forget marks for paths that no longer exist (after a paste-move, delete, or rename).
---@param paths string[]
function M.remove(paths)
  local changed_any = false
  for _, p in ipairs(paths) do
    if kinds[p] then
      kinds[p] = nil
      local i = index_of(p)
      if i then
        table.remove(order, i)
      end
      changed_any = true
    end
  end
  if changed_any then
    changed()
  end
end

--- Carry a mark over to a renamed path, keeping its kind and position.
---@param from string
---@param to string
function M.rename(from, to)
  local kind = kinds[from]
  if not kind then
    return
  end
  kinds[from] = nil
  kinds[to] = kind
  local i = index_of(from)
  if i then
    order[i] = to
  end
  changed()
end

function M.clear()
  if #order == 0 then
    return
  end
  kinds, order = {}, {}
  changed()
end

--- Short text for statuslines, e.g. "2 copy / 1 move"; empty when nothing is marked.
---@return string
function M.status()
  local parts = {}
  for _, kind in ipairs({ 'copy', 'move', 'delete', 'shell', 'archive', 'run' }) do
    local n = #M.list(kind)
    if n > 0 then
      parts[#parts + 1] = n .. ' ' .. kind
    end
  end
  return table.concat(parts, ' / ')
end

return M
