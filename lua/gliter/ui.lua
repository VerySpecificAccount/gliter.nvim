--- gliter.ui — the little pieces every gliter module borrows: a
--- centered floating list, JSON registries that survive restarts, and
--- a confirm that says no unless somebody actually answers yes.
---
--- Internal: no setup(), no keys, no commands of its own. gliter.sessions
--- and gliter.readme are built on it.

local M = {}

--- A centered floating window over the editor with a throwaway buffer.
--- q, Q and <Esc> close it (set `close` to false to map them yourself).
---@param opts? { title?: string, width?: number, height?: number, close?: boolean }
---@return integer win
---@return integer buf
function M.float(opts)
  opts = opts or {}
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false

  local columns, rows = vim.o.columns, (vim.o.lines - vim.o.cmdheight - 2)
  local w = math.floor(columns * math.min(1, tonumber(opts.width) or 0.8) + 0.5)
  local h = math.floor(rows * math.min(1, tonumber(opts.height) or 0.6) + 0.5)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = math.min(w, columns),
    height = math.min(h, rows),
    col = math.floor((columns - w) / 2),
    row = math.floor((rows - h) / 2),
    border = 'rounded',
    title = opts.title,
    title_pos = 'center',
  })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false

  if opts.close ~= false then
    for _, k in ipairs({ 'q', 'Q', '<Esc>' }) do
      vim.keymap.set('n', k, function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end, { buffer = buf, nowait = true, silent = true, desc = 'gliter: close the list' })
    end
  end
  return win, buf
end

--- Replace a float buffer's contents (line 1 is the header; the cursor
--- is kept on its row, in range). `highlights` is a list of
--- { line, col_start, col_end, group } (0-based line, byte columns,
--- col_end -1 or past-the-end for "to the end").
---@param buf integer
---@param lines string[]
---@param highlights? table[]
function M.render(buf, lines, highlights)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local win = vim.fn.bufwinid(buf)
  local row = (win >= 0) and vim.api.nvim_win_get_cursor(win)[1] or 2
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
  for _, h in ipairs(highlights or {}) do
    pcall(vim.api.nvim_buf_add_highlight, buf, -1, h[4], h[1], h[2], h[3])
  end
  if win >= 0 and vim.api.nvim_win_is_valid(win) then
    row = math.max(2, math.min(row, math.max(2, #lines)))
    vim.api.nvim_win_set_cursor(win, { row, 0 })
  end
end

--- Read a small JSON registry; `default` when it is missing or broken.
---@param path string
---@param default table
---@return table
function M.json_read(path, default)
  local f = io.open(path, 'r')
  if not f then
    return default
  end
  local text = f:read('*a')
  f:close()
  local ok, value = pcall(vim.json.decode, text, { luanil = { list = true, object = true } })
  if ok and type(value) == 'table' then
    return value
  end
  return default
end

--- Write a JSON registry (write-then-rename, so a crash mid-write
--- never eats the old one).
---@param path string
---@param value table
function M.json_write(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local tmp = path .. '.tmp'
  local f = io.open(tmp, 'w')
  if not f then
    return false
  end
  f:write(vim.json.encode(value))
  f:close()
  os.rename(tmp, path)
  return true
end

--- A confirm that never lies in headless: no UI answering means no.
---@param prompt string
---@return boolean
function M.confirm(prompt)
  if #vim.api.nvim_list_uis() == 0 then
    return false
  end
  return vim.fn.confirm(prompt, '&Yes\n&No', 2) == 1
end

return M
