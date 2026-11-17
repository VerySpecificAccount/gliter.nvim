--- Copy / move engine with interactive conflict resolution.
local fs = require('gliter.netrw.fs')
local ui = require('gliter.netrw.ui')
local config = require('gliter.netrw.config')

local M = {}

---@class GliterNetrwPasteResult
---@field done { src: string, dst: string }[]
---@field skipped { src: string, reason: string }[]
---@field failed { src: string, err: string }[]
---@field cancelled boolean

---@class GliterNetrwRun
---@field mode 'copy'|'move'
---@field policy string
---@field sticky? string  decision remembered by "all" answers
---@field cancelled boolean
---@field res GliterNetrwPasteResult

local function record_done(run, src, dst)
  run.res.done[#run.res.done + 1] = { src = src, dst = dst }
end

local function record_skip(run, src, reason)
  run.res.skipped[#run.res.skipped + 1] = { src = src, reason = reason }
end

local function record_fail(run, src, err)
  run.res.failed[#run.res.failed + 1] = { src = src, err = tostring(err) }
end

--- Ask what to do when `dst` already exists.
---@return 'overwrite'|'skip'|'rename'|'cancel' action, string? reason
local function decide(run, src, dst, sst, dst_st)
  local policy = run.policy
  local name = fs.basename(dst)

  if (sst.type == 'directory') ~= (dst_st.type == 'directory') then
    if policy == 'rename' then
      return 'rename'
    elseif policy ~= 'ask' then
      return 'skip', 'file/directory type mismatch'
    end
    local msg = ('"%s" already exists and is a different kind of item,\nso it cannot be overwritten.'):format(name)
    local c = ui.confirm(msg, '&Skip\n&Rename\n&Cancel', 1)
    return ({ 'skip', 'rename', 'cancel' })[c] or 'cancel'
  end

  if run.sticky then
    return run.sticky --[[@as any]]
  end
  if policy == 'overwrite' or policy == 'skip' or policy == 'rename' then
    return policy --[[@as any]]
  end

  local verb = sst.type == 'directory' and 'Merge' or 'Overwrite'
  local msg = ('"%s" already exists in\n%s'):format(name, fs.dirname(dst))
  local choices = ('&%s\n&Skip\n&Rename\n%s &all\nS&kip all\n&Cancel'):format(verb, verb)
  local c = ui.confirm(msg, choices, 2)
  if c == 1 then
    return 'overwrite'
  elseif c == 2 then
    return 'skip', 'already exists'
  elseif c == 3 then
    return 'rename'
  elseif c == 4 then
    run.sticky = 'overwrite'
    return 'overwrite'
  elseif c == 5 then
    run.sticky = 'skip'
    return 'skip', 'already exists'
  end
  return 'cancel'
end

--- Choose a free destination name. Non-interactive policies pick one automatically.
---@return string? path
local function pick_free(run, dst)
  local dir, base = fs.dirname(dst), fs.basename(dst)
  local suggestion = fs.unique_name(dir, base)
  if run.policy ~= 'ask' then
    return fs.join(dir, suggestion)
  end
  while true do
    local name = ui.input('Rename to: ', suggestion)
    if not name then
      return nil
    end
    if name:find('/', 1, true) or name == '.' or name == '..' then
      ui.notify('Invalid name: ' .. name, vim.log.levels.WARN)
      suggestion = name
    elseif fs.exists(fs.join(dir, name)) then
      ui.notify('Already exists: ' .. name, vim.log.levels.WARN)
      suggestion = name
    else
      return fs.join(dir, name)
    end
  end
end

---@param run GliterNetrwRun
---@param src string
---@param dst string
local function transfer(run, src, dst)
  if run.cancelled then
    return
  end
  local sst = fs.lstat(src)
  if not sst then
    return record_fail(run, src, 'no longer exists')
  end
  if sst.type == 'directory' and fs.is_inside(dst, src) then
    return record_fail(run, src, 'cannot place a directory inside itself')
  end

  local dst_st = fs.lstat(dst)
  if dst_st then
    if fs.same_file(src, dst) then
      if run.mode == 'move' then
        return record_skip(run, src, 'already in this directory')
      end
      -- Copying next to the original: pick a free "<name>_copy" automatically.
      dst = fs.join(fs.dirname(dst), fs.unique_name(fs.dirname(dst), fs.basename(dst)))
      dst_st = nil
    else
      local action, why = decide(run, src, dst, sst, dst_st)
      if action == 'cancel' then
        run.cancelled = true
        return
      elseif action == 'skip' then
        return record_skip(run, src, why or 'already exists')
      elseif action == 'rename' then
        local free = pick_free(run, dst)
        if not free then
          return record_skip(run, src, 'not renamed')
        end
        dst, dst_st = free, nil
      end
    end
  end

  local ok, err
  if dst_st then
    -- The user chose overwrite / merge.
    if sst.type == 'directory' and dst_st.type == 'directory' then
      for _, child in ipairs(fs.list(src)) do
        transfer(run, fs.join(src, child.name), fs.join(dst, child.name))
        if run.cancelled then
          return
        end
      end
      if run.mode == 'move' then
        vim.uv.fs_rmdir(src) -- succeeds only if everything inside was moved out
      end
      return record_done(run, src, dst)
    end
    if run.mode == 'copy' then
      ok, err = fs.remove(dst)
      if ok then
        ok, err = fs.copy(src, dst)
      end
    else
      ok, err = fs.move_over(src, dst)
    end
  elseif run.mode == 'copy' then
    ok, err = fs.copy(src, dst)
  else
    ok, err = fs.rename(src, dst)
  end

  if ok then
    record_done(run, src, dst)
  else
    record_fail(run, src, err)
  end
end

---@param mode 'copy'|'move'
---@param sources string[]
---@param dest_dir string
---@return GliterNetrwPasteResult
function M.run(mode, sources, dest_dir)
  ---@type GliterNetrwRun
  local run = {
    mode = mode,
    policy = config.options.conflict,
    cancelled = false,
    res = { done = {}, skipped = {}, failed = {}, cancelled = false },
  }
  for _, src in ipairs(sources) do
    if run.cancelled then
      break
    end
    transfer(run, src, fs.join(dest_dir, fs.basename(src)))
  end
  run.res.cancelled = run.cancelled
  return run.res
end

return M
