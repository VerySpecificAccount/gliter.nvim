--- Filesystem primitives (libuv only: no shelling out, so names are never interpreted by a shell).
local uv = vim.uv
local bit = require('bit')

local M = {}

---@param a string
---@param b string
function M.join(a, b)
  return vim.fs.joinpath(a, b)
end

---@param p string
function M.dirname(p)
  return vim.fs.dirname(p)
end

---@param p string
function M.basename(p)
  return vim.fs.basename(p)
end

--- Normalise a directory path coming from netrw without expanding `~` or `$VAR`
--- (a file may legitimately be named `$HOME`).
---@param p string
---@return string
function M.normalize(p)
  if vim.fn.has('win32') == 1 then
    p = p:gsub('\\', '/')
  end
  p = p:gsub('//+', '/')
  if #p > 1 and p:sub(-1) == '/' and not p:match('^%a:/$') then
    p = p:sub(1, -2)
  end
  return p
end

---@param p string
function M.lstat(p)
  return uv.fs_lstat(p)
end

---@param p string
---@return boolean
function M.exists(p)
  return uv.fs_lstat(p) ~= nil
end

--- True when `p` is a directory (symlinks are followed).
---@param p string
---@return boolean
function M.is_dir(p)
  local st = uv.fs_stat(p)
  return st ~= nil and st.type == 'directory'
end

--- True when both paths refer to the same file (also on case-insensitive filesystems).
---@param a string
---@param b string
---@return boolean
function M.same_file(a, b)
  if a == b then
    return true
  end
  local sa, sb = uv.fs_lstat(a), uv.fs_lstat(b)
  return sa ~= nil and sb ~= nil and sa.ino ~= 0 and sa.ino == sb.ino and sa.dev == sb.dev
end

--- True when `path` lies strictly inside `dir`.
---@param path string
---@param dir string
---@return boolean
function M.is_inside(path, dir)
  if dir == '/' then
    return path ~= '/'
  end
  return path:sub(1, #dir + 1) == dir .. '/'
end

---@param dir string
---@return { name: string, type: string }[]
function M.list(dir)
  local out = {}
  local handle = uv.fs_scandir(dir)
  if not handle then
    return out
  end
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    out[#out + 1] = { name = name, type = typ }
  end
  table.sort(out, function(x, y)
    return x.name < y.name
  end)
  return out
end

--- `mkdir -p`
---@param path string
---@return boolean ok, string? err
function M.mkdirp(path)
  if M.is_dir(path) then
    return true
  end
  pcall(vim.fn.mkdir, path, 'p')
  if M.is_dir(path) then
    return true
  end
  return false, 'cannot create directory: ' .. path
end

--- Create an empty file; never truncates an existing one.
---@param path string
---@return boolean ok, string? err
function M.touch(path)
  local fd, err = uv.fs_open(path, 'wx', 420) -- 0644
  if not fd then
    return false, err
  end
  uv.fs_close(fd)
  return true
end

--- Recursively delete (symlinks are removed, never followed).
---@param path string
---@return boolean ok, string? err
function M.remove(path)
  local st = uv.fs_lstat(path)
  if not st then
    return true
  end
  if st.type == 'directory' then
    for _, e in ipairs(M.list(path)) do
      local ok, err = M.remove(M.join(path, e.name))
      if not ok then
        return false, err
      end
    end
    local ok, err = uv.fs_rmdir(path)
    return ok and true or false, err
  end
  local ok, err = uv.fs_unlink(path)
  return ok and true or false, err
end

--- Recursive copy preserving symlinks and permission bits.
---@param src string
---@param dst string
---@return boolean ok, string? err
function M.copy(src, dst)
  local st = uv.fs_lstat(src)
  if not st then
    return false, 'source does not exist: ' .. src
  end
  if st.type == 'link' then
    local target = uv.fs_readlink(src)
    if not target then
      return false, 'cannot read link: ' .. src
    end
    local ok, err = uv.fs_symlink(target, dst)
    return ok and true or false, err
  elseif st.type == 'directory' then
    local perm = bit.band(st.mode, 0x1ff)
    -- Create writable first so read-only directories can still be filled.
    local ok, err = uv.fs_mkdir(dst, bit.bor(perm, 0x1c0))
    if not ok then
      return false, err
    end
    for _, e in ipairs(M.list(src)) do
      local ok2, err2 = M.copy(M.join(src, e.name), M.join(dst, e.name))
      if not ok2 then
        return false, err2
      end
    end
    uv.fs_chmod(dst, perm)
    return true
  elseif st.type == 'file' then
    local ok, err = uv.fs_copyfile(src, dst)
    return ok and true or false, err
  end
  return false, ('unsupported file type (%s): %s'):format(st.type, src)
end

--- Rename/move. Falls back to copy+delete across devices.
--- Refuses to clobber an existing, different destination.
---@param from string
---@param to string
---@return boolean ok, string? err
function M.rename(from, to)
  if M.exists(to) and not M.same_file(from, to) then
    return false, 'destination exists: ' .. to
  end
  local ok, err, name = uv.fs_rename(from, to)
  if ok then
    return true
  end
  if name == 'EXDEV' then
    local ok2, err2 = M.copy(from, to)
    if not ok2 then
      M.remove(to)
      return false, err2
    end
    return M.remove(from)
  end
  return false, err
end

--- Move that replaces the destination (used only after the user chose "overwrite").
---@param from string
---@param to string
---@return boolean ok, string? err
function M.move_over(from, to)
  local ok, err, name = uv.fs_rename(from, to)
  if ok then
    return true
  end
  if name == 'EXDEV' then
    local ok2, err2 = M.copy(from, to)
    if not ok2 then
      return false, err2
    end
    return M.remove(from)
  end
  return false, err
end

--- Find a free name next to `name` such as `foo_copy.txt`, `foo_copy_2.txt`.
---@param dir string
---@param name string
---@param suffix? string
---@return string
function M.unique_name(dir, name, suffix)
  suffix = suffix or '_copy'
  local stem, ext = name:match('^(.+)(%.[^.]+)$')
  if not stem then
    stem, ext = name, ''
  end
  local candidate = stem .. suffix .. ext
  local i = 2
  while M.exists(M.join(dir, candidate)) do
    candidate = ('%s%s_%d%s'):format(stem, suffix, i, ext)
    i = i + 1
  end
  return candidate
end

return M
