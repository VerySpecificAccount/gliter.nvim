--- The archive mark (`z`), applied by `p`.
---
--- A z-marked entry that is itself an archive netrw can browse (.tar, .tar.gz, .tgz,
--- .zip, ...) is extracted into a directory you type; Enter keeps the directory netrw
--- is listing, and a missing directory is created. Every other z-marked entry is packed
--- into a new archive whose name you type; the extension of that name picks the format
--- (.tar, .tar.gz/.tgz, .tar.bz2/.tbz2, .tar.xz/.txz, .tar.zst/.tzst, .zip). A mix of
--- both is applied with one prompt each, extraction first. Marks of the entries that
--- were extracted or archived successfully are cleared; failed ones keep theirs.
---
--- The recognized types are exactly those netrw opens through its archive plugins:
--- plugin/tarPlugin.vim (*.tar, *.tar.gz, *.tgz, ...) and plugin/zipPlugin.vim
--- (g:zipPlugin_ext: *.zip, *.jar, *.xlsx, ...), so anything you can open in netrw can
--- be extracted by the mark.
local fs = require('gliter.netrw.fs')
local marks = require('gliter.netrw.marks')
local netrw = require('gliter.netrw.listing')
local ui = require('gliter.netrw.ui')

local M = {}

local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

--- tarPlugin.vim's archive extensions, with the `tar` flags that decompress them.
local TAR = {
  ['tar'] = {},
  ['tar.bz2'] = { '-j' },
  ['tar.bz3'] = { '-I', 'bzip3' },
  ['tar.gz'] = { '-z' },
  ['tar.lz4'] = { '-I', 'lz4' },
  ['tar.lzma'] = { '--lzma' },
  ['tar.xz'] = { '-J' },
  ['tar.z'] = { '-Z' },
  ['tar.zst'] = { '--zstd' },
  ['tgz'] = { '-z' },
}

--- zipPlugin.vim's g:zipPlugin_ext (every one of them is a zip container).
local ZIP = {
  'aar', 'apk', 'celzip', 'crtx', 'docm', 'docx', 'dotm', 'dotx', 'ear', 'epub',
  'gcsx', 'glox', 'gqsx', 'ja', 'jar', 'kmz', 'odb', 'odc', 'odf', 'odg', 'odi',
  'odm', 'odp', 'ods', 'odt', 'otc', 'otf', 'otg', 'oth', 'oti', 'otp', 'ots',
  'ott', 'oxt', 'pkpass', 'potm', 'potx', 'ppam', 'ppsm', 'ppsx', 'pptm', 'pptx',
  'sldx', 'thmx', 'vdw', 'war', 'whl', 'wsz', 'xap', 'xlam', 'xlsb', 'xlsm',
  'xlsx', 'xltm', 'xltx', 'xpi', 'zip',
}

--- Formats an archive can be written in, keyed by the lower-case suffix of its name.
local CREATE = {
  ['tar'] = { 'tar', '-cf' },
  ['tar.gz'] = { 'tar', '-czf' },
  ['tgz'] = { 'tar', '-czf' },
  ['tar.bz2'] = { 'tar', '-cjf' },
  ['tbz'] = { 'tar', '-cjf' },
  ['tbz2'] = { 'tar', '-cjf' },
  ['tar.xz'] = { 'tar', '-cJf' },
  ['txz'] = { 'tar', '-cJf' },
  ['tar.zst'] = { 'tar', '--zstd', '-cf' },
  ['tzst'] = { 'tar', '--zstd', '-cf' },
  ['tar.lz4'] = { 'tar', '-I', 'lz4', '-cf' },
  ['tar.lzma'] = { 'tar', '--lzma', '-cf' },
  ['zip'] = { 'zip', '-r', '-q' },
}

--- Absolute path for a typed answer: `~` and `$VAR` expanded, relative to `root`.
---@param ctx GliterNetrwCtx
---@param input string
---@return string
local function resolve(ctx, input)
  input = vim.fs.normalize(input)
  if input:sub(1, 1) == '/' or input:match('^%a:[/\\]') then
    return fs.normalize(input)
  end
  return fs.normalize(fs.join(ctx.root, input))
end

--- `tar` extraction flags for a name, or nil when it is not a tar archive.
local function tar_flags(name)
  local lower = name:lower()
  for ext, flags in pairs(TAR) do
    if lower:sub(-#ext - 1) == '.' .. ext then
      return flags
    end
  end
end

local function is_zip_name(name)
  local lower = name:lower()
  for _, ext in ipairs(ZIP) do
    if lower:sub(-#ext - 1) == '.' .. ext then
      return true
    end
  end
end

--- True when `path` is a regular file netrw can browse as an archive, i.e. one the
--- extract half of the mark can unpack.
---@param path string
---@return boolean
function M.is_archive(path)
  local st = fs.lstat(path)
  if st == nil or st.type ~= 'file' then
    return false
  end
  local name = fs.basename(path)
  return tar_flags(name) ~= nil or is_zip_name(name)
end

--- Extract half of the archive mark: unpack `paths` (all of them netrw-browsable
--- archives) into a directory you type; Enter keeps the directory netrw is listing.
--- Archives are unpacked one after another; successfully extracted ones lose their mark.
---@param ctx GliterNetrwCtx
---@param paths string[]
function M.extract(ctx, paths)
  local input = ui.input(('Extract %d to: '):format(#paths), ctx.root, 'dir')
  if not input then
    return
  end
  local out = resolve(ctx, input)
  local ok, err = fs.mkdirp(out)
  if not ok then
    return ui.notify(('%s: %s'):format(out, tostring(err)), ERROR)
  end

  local done, failed = {}, {}
  local function run(i)
    if i > #paths then
      marks.remove(done)
      netrw.refresh_dirs({ out, ctx.root }, nil)
      if #done > 0 then
        ui.notify(('Extracted %d/%d into %s.'):format(#done, #paths, out))
      end
      for j, f in ipairs(failed) do
        if j > 3 then
          ui.notify(('…and %d more errors.'):format(#failed - 3), ERROR)
          break
        end
        ui.notify(('%s: %s'):format(fs.basename(f.src), f.err), ERROR)
      end
      return
    end
    local arc = paths[i]
    local name = fs.basename(arc)
    local argv = { 'tar' }
    local flags = tar_flags(name)
    if flags ~= nil then
      vim.list_extend(argv, flags)
      vim.list_extend(argv, { '-xf', arc, '-C', out })
    else
      argv = { 'unzip', '-o', arc, '-d', out } -- -o: overwrite, like tar's default
    end
    vim.system(argv, { cwd = ctx.root, text = true }, function(r)
      vim.schedule(function()
        if r.code == 0 then
          done[#done + 1] = arc
        else
          local msg = vim.trim((r.stdout or '') .. ' ' .. (r.stderr or ''))
          failed[#failed + 1] = { src = arc, err = msg ~= '' and msg or ('%s exited with %d'):format(argv[1], r.code) }
        end
        run(i + 1)
      end)
    end)
  end
  run(1)
end

--- Pack half of the archive mark: pack `paths` into an archive whose name you type;
--- the extension picks the format. Entries inside the listed directory are archived
--- by their plain names, like `tar -C dir` / `zip -r` run from the listing. On success
--- the packed entries lose their mark; on failure they keep it.
---@param ctx GliterNetrwCtx
---@param paths string[]
function M.create(ctx, paths)
  local stem = (#paths == 1 and fs.basename(paths[1]) or 'archive'):gsub('%.[^.]+$', '')
  local input = ui.input(('Archive %d into: '):format(#paths), stem .. '.tar.gz', 'file')
  if not input then
    return
  end
  local out = resolve(ctx, input)
  local lower = fs.basename(out):lower()
  local tool = nil
  for ext, argv in pairs(CREATE) do
    if lower:sub(-#ext - 1) == '.' .. ext then
      tool = argv
      break
    end
  end
  if tool == nil then
    return ui.notify('Unsupported archive type; use .tar, .tar.gz, .tar.bz2, .tar.xz, .tar.zst or .zip.', ERROR)
  end
  if fs.exists(out) then
    return ui.notify(out .. ' already exists.', WARN)
  end
  local argv = {}
  vim.list_extend(argv, tool)
  argv[#argv + 1] = out
  for _, p in ipairs(paths) do
    argv[#argv + 1] = fs.dirname(p) == ctx.root and fs.basename(p) or p
  end
  vim.system(argv, { cwd = ctx.root, text = true }, function(r)
    vim.schedule(function()
      netrw.refresh_dirs({ ctx.root, fs.dirname(out) }, nil)
      if r.code == 0 then
        marks.remove(paths)
        ui.notify(('Archived %d into %s.'):format(#paths, out))
      else
        local msg = vim.trim((r.stdout or '') .. ' ' .. (r.stderr or ''))
        ui.notify(msg ~= '' and msg or ('%s exited with %d'):format(argv[1], r.code), ERROR)
      end
    end)
  end)
end

return M
