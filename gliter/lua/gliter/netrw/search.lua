--- Live-regexp search over a netrw listing — the machinery under `%<mark>`
--- (mark by regexp, with a live highlight).
---
--- The regexp is compiled exactly the way a `/` search in the listing would
--- compile it (a Vim regexp), and it is matched against the text the listing
--- actually shows — `dir/` with its trailing slash, `link@`, `file*` — so a
--- pattern that finds something in the buffer finds it here too: `.\+\/`
--- marks exactly the directories, and nothing else.
local netrw = require('gliter.netrw.listing')
local ui = require('gliter.netrw.ui')

local M = {}

local ns = vim.api.nvim_create_namespace('gliter_netrw_search')

--- Compile `pat` the way `/` does. nil when it is not (yet) a valid Vim
--- regexp — a trailing `\` while typing, an unbalanced `\(`, ...
---@param pat string
---@return vim.regex?
function M.compile(pat)
  if pat == '' then
    return nil
  end
  local ok, re = pcall(vim.regex, pat)
  return ok and re or nil
end

--- The entries whose shown name matches `re`, in listing order.
---@param entries GliterNetrwEntry[]
---@param re vim.regex
---@return GliterNetrwEntry[]
function M.matching(entries, re)
  local out = {}
  for _, e in ipairs(entries) do
    if re:match_str(e.display) then
      out[#out + 1] = e
    end
  end
  return out
end

--- Highlight `entries` — the live preview, in Search colors.
---@param buf integer
---@param entries GliterNetrwEntry[]
function M.highlight(buf, entries)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, e in ipairs(entries) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, e.lnum - 1, e.col, {
      end_col = e.end_col,
      hl_group = 'GliterNetrwSearch',
    })
  end
end

--- Drop the live highlighting.
---@param buf integer
function M.clear(buf)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

---------------------------------------------------------------------------
-- the `%<mark>` prompt: highlight as you type, hand back the matches
---------------------------------------------------------------------------

--- The live prompt behind `%<mark>`: type a Vim regexp, the matching entries
--- light up while you type and the hint counts them — on the command line
--- vim.fn.input() gives (readline keys and a ghost of the answers before
--- with gliter.cmd set up; <Up>/<Down> walk the `@` history).
--- Enter returns the matched entries and the pattern; Esc returns nil.
--- Enter on an invalid regexp returns nil too — with the pattern as the
--- second value, so the caller can say why. The highlighting is dropped
--- either way.
---@param ctx GliterNetrwCtx
---@param label string
---@return GliterNetrwEntry[]? entries, string? pattern
function M.prompt(ctx, label)
  local entries = netrw.all(ctx) -- parsed once, from the full listing
  local matched, valid = {}, false
  local pattern = ui.live_input(label, {
    on_change = function(text)
      local re = M.compile(text)
      if not re then
        valid = false
        return text ~= '' and 'invalid regexp' or nil
      end
      valid = true
      matched = M.matching(entries, re)
      M.highlight(ctx.buf, matched)
      return ('%d match%s'):format(#matched, #matched == 1 and '' or 'es')
    end,
  })
  M.clear(ctx.buf)
  if not pattern or not valid then
    return nil, pattern
  end
  return matched, pattern
end

return M
