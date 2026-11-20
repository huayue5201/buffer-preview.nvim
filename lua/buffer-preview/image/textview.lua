--- Page-text side panel for buffer-preview.nvim.
---
--- The preview itself is a picture: it cannot be searched, copied or yanked.
--- `pdftotext` gives us the real text of the page, which this panel shows in
--- a normal (read-only) buffer so `/` search, `y`, `gf` and friends work.
local config = require("buffer-preview.config")
local rasterizer = require("buffer-preview.image.rasterizer")

local M = {}

---@param state buffer-preview.ViewerState
---@param page number
---@return string
local function buffer_name(state, page)
  return string.format("buffer-preview://%s/page-%d.txt", vim.fn.fnamemodify(state.source_path, ":t"), page)
end

---@param buf number
---@param lines string[]
local function set_lines(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

---@param state buffer-preview.ViewerState
---@return boolean
function M.is_open(state)
  return state.text_buf ~= nil and vim.api.nvim_buf_is_valid(state.text_buf)
end

---@param state buffer-preview.ViewerState
function M.close(state)
  local win = state.text_win
  state.text_buf = nil
  state.text_win = nil
  state.text_page = nil
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
end

---@param state buffer-preview.ViewerState
---@return number
local function open_win(state)
  if M.is_open(state) then
    return state.text_buf
  end

  -- `:new` (not `:sbnew`, which Neovim lacks) opens a split with an empty buffer.
  vim.cmd("vertical belowright new")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].buffer_preview_handled = true
  pcall(vim.api.nvim_buf_set_name, buf, buffer_name(state, state.current_page))

  state.text_win = win
  state.text_buf = buf

  local cfg = config.get()
  local keys = {}
  if cfg.keymaps ~= false then
    keys = config.keys(cfg.keymaps.close)
  end
  if #keys == 0 then
    keys = { "q" }
  end
  for _, key in ipairs(keys) do
    vim.keymap.set("n", key, function()
      M.close(state)
    end, { buffer = buf, nowait = true, silent = true, desc = "Close page text" })
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if state.text_buf == buf then
        state.text_buf = nil
        state.text_win = nil
        state.text_page = nil
      end
    end,
  })

  return buf
end

--- Reload the panel for the current page (no-op when the panel is closed).
---@param state buffer-preview.ViewerState
function M.refresh(state)
  if not M.is_open(state) or not state.pdf_path then
    return
  end

  local buf = state.text_buf
  local page = state.current_page
  state.text_token = (state.text_token or 0) + 1
  local token = state.text_token

  pcall(vim.api.nvim_buf_set_name, buf, buffer_name(state, page))
  set_lines(buf, { "Loading text…" })

  rasterizer.page_text(state.pdf_path, page, function(text, err)
    if state.text_token ~= token or state.text_buf ~= buf then
      return
    end
    if not text then
      set_lines(buf, { "-- " .. (err or "could not extract page text") })
      return
    end

    local lines = vim.split(text:gsub("%s+$", ""), "\n", { plain = true })
    if #lines == 1 and vim.trim(lines[1]) == "" then
      lines = { "-- This page has no text layer (scanned image?)." }
    end
    state.text_page = page
    set_lines(buf, lines)
  end)
end

--- Toggle the page-text panel.
---@param state buffer-preview.ViewerState
function M.toggle(state)
  if not state.ready or not state.pdf_path then
    vim.notify("buffer-preview.nvim: page text is available once the preview has loaded", vim.log.levels.WARN)
    return
  end

  if M.is_open(state) then
    M.close(state)
    return
  end

  open_win(state)
  M.refresh(state)
end

--- Copy the current page's text to the unnamed register.
---@param state buffer-preview.ViewerState
function M.yank(state)
  if not state.ready or not state.pdf_path then
    return
  end

  local page = state.current_page
  local buf = state.text_buf
  if buf and vim.api.nvim_buf_is_valid(buf) and state.text_page == page then
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    vim.fn.setreg('"', text, "v")
    vim.notify(string.format("buffer-preview.nvim: copied text of page %d", page), vim.log.levels.INFO)
    return
  end

  local token = page
  rasterizer.page_text(state.pdf_path, page, function(text, err)
    if token ~= state.current_page then
      return
    end
    if not text then
      vim.notify(err or "buffer-preview.nvim: could not extract page text", vim.log.levels.WARN)
      return
    end
    vim.fn.setreg('"', text, "v")
    vim.notify(string.format("buffer-preview.nvim: copied text of page %d", page), vim.log.levels.INFO)
  end)
end

return M
