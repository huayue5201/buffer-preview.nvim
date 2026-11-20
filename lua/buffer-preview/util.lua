--- Small shared helpers.
local M = {}

--- Replace the contents of a read-only scratch buffer.
---
--- Used by every buffer this plugin renders into (the page canvas, the page
--- text panel and the SQLite result buffer), which would otherwise each keep
--- their own copy of the same four lines.
---@param buf number
---@param lines string[]
---@param win? number window whose viewport must survive the replacement
function M.set_lines(buf, lines, win)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local view = win and vim.api.nvim_win_call(win, vim.fn.winsaveview)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  if view then
    pcall(vim.api.nvim_win_call, win, function()
      vim.fn.winrestview(view)
    end)
  end
end

return M
