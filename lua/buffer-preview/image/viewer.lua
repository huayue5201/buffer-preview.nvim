--- PDF viewer buffer management for buffer-preview.nvim.
--- Handles buffer hijacking, keymaps, page state, and display lifecycle.
---
--- The pipeline is asynchronous end to end: converting a presentation,
--- reading the page count and rasterizing a page all run through
--- `vim.system`, so the UI keeps responding on large documents.
local converter = require("buffer-preview.image.converter")
local rasterizer = require("buffer-preview.image.rasterizer")
local display = require("buffer-preview.image.display")

local M = {}

--- Per-buffer viewer state.
---@class buffer-preview.ViewerState
---@field source_path string
---@field pdf_path string|nil
---@field page_count number
---@field current_page number
---@field buf number
---@field win number|nil Window currently showing this buffer
---@field augroup number
---@field ready boolean
---@field req number Monotonic rasterization request id
---@field load_token number Monotonic load (convert + page count) id

---@type table<number, buffer-preview.ViewerState>
M._states = {}

---------------------------------------------------------------------------
-- Internal helpers
---------------------------------------------------------------------------

---@param state buffer-preview.ViewerState
---@return boolean
local function is_alive(state)
  return M._states[state.buf] == state and vim.api.nvim_buf_is_valid(state.buf)
end

---@param buf number
---@return number|nil
local function buf_window(buf)
  local win = vim.fn.bufwinid(buf)
  if win == -1 then
    return nil
  end
  return win
end

--- Write the status bar and blank canvas into the buffer.
---@param state buffer-preview.ViewerState
---@param win number|nil
local function update_status(state, win)
  local buf = state.buf
  if not is_alive(state) then
    return
  end

  win = win or buf_window(buf)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  local height = vim.api.nvim_win_get_height(win)
  local filename = vim.fn.fnamemodify(state.source_path, ":t")
  local status
  if state.ready then
    status = string.format(
      "  %s  |  Page %d / %d  |  q:close  j/k:page  g/G:first/last  <num>G:goto",
      filename,
      state.current_page,
      state.page_count
    )
  else
    status = string.format("  %s  |  %s", filename, state.message or "Loading…")
  end

  local lines = {}
  for _ = 1, math.max(height - 1, 0) do
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = status

  local view = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  pcall(vim.api.nvim_win_call, win, function()
    vim.fn.winrestview(view)
  end)
end

--- Render the current page image and overlay it on the buffer.
---
--- The rasterized page is delivered asynchronously; a page flip invalidates
--- any older in-flight request so out-of-order results cannot overwrite the
--- page the user is actually looking at.
---@param state buffer-preview.ViewerState
local function render_page(state)
  if not is_alive(state) then
    return
  end

  local win = buf_window(state.buf)
  if not win then
    return
  end
  state.win = win

  update_status(state, win)

  if not state.ready or not state.pdf_path then
    return
  end

  state.req = (state.req or 0) + 1
  local req = state.req
  local page = state.current_page

  rasterizer.rasterize_page(state.pdf_path, page, function(png_path, err)
    if not is_alive(state) or state.req ~= req then
      return
    end

    if not png_path then
      vim.notify(err or ("buffer-preview.nvim: failed to render page " .. page), vim.log.levels.ERROR)
      return
    end

    local current_win = buf_window(state.buf)
    if not current_win then
      return
    end
    state.win = current_win
    display.show(png_path, current_win, state.buf)
  end)
end

--- Navigate to a specific page number (clamped to valid range).
---@param state buffer-preview.ViewerState
---@param page number
local function goto_page(state, page)
  if not is_alive(state) or not state.ready then
    return
  end

  page = math.max(1, math.min(page, state.page_count))
  if page == state.current_page then
    return
  end

  state.current_page = page
  render_page(state)
end

---------------------------------------------------------------------------
-- Keymaps
---------------------------------------------------------------------------

---@param state buffer-preview.ViewerState
local function setup_keymaps(state)
  local buf = state.buf
  local opts = { buffer = buf, noremap = true, silent = true, nowait = true }

  -- Next page
  for _, key in ipairs({ "j", "<Down>", "]", "}", "<C-d>", "<C-f>", "<Space>", "l" }) do
    vim.keymap.set("n", key, function()
      goto_page(state, state.current_page + 1)
    end, opts)
  end

  -- Previous page
  for _, key in ipairs({ "k", "<Up>", "[", "{", "<C-u>", "<C-b>", "h" }) do
    vim.keymap.set("n", key, function()
      goto_page(state, state.current_page - 1)
    end, opts)
  end

  -- Mouse-wheel only flips the page when the pointer is over the PDF
  -- window. When the pointer is elsewhere, return the original keystroke so
  -- Vim re-processes it unmapped — that way the user's own `'mousescroll'`
  -- (and any global wheel mapping) decides what happens. The page flip
  -- itself is deferred with `vim.schedule` because `<expr>` mappings run
  -- under textlock, which forbids buffer/window mutations.
  local function scroll(direction, fallback)
    if state.win and vim.fn.getmousepos().winid == state.win then
      vim.schedule(function()
        if M._states[state.buf] == state then
          goto_page(state, state.current_page + direction)
        end
      end)
      return ""
    end
    return fallback
  end
  local scroll_opts = vim.tbl_extend("force", opts, { expr = true, replace_keycodes = true })
  vim.keymap.set("n", "<ScrollWheelDown>", function() return scroll(1, "<ScrollWheelDown>") end, scroll_opts)
  vim.keymap.set("n", "<ScrollWheelUp>", function() return scroll(-1, "<ScrollWheelUp>") end, scroll_opts)

  -- First page (bare `g` with nowait)
  vim.keymap.set("n", "g", function()
    local count = vim.v.count
    if count > 0 then
      goto_page(state, count)
    else
      goto_page(state, 1)
    end
  end, opts)

  -- Last page / go-to-page with count (e.g. `5G` -> page 5)
  vim.keymap.set("n", "G", function()
    local count = vim.v.count
    if count > 0 then
      goto_page(state, count)
    else
      goto_page(state, state.page_count)
    end
  end, opts)

  -- Refresh display
  vim.keymap.set("n", "r", function()
    render_page(state)
  end, opts)
  vim.keymap.set("n", "<C-l>", function()
    render_page(state)
  end, opts)

  -- Close viewer
  vim.keymap.set("n", "q", function()
    display.clear(state.buf)
    vim.cmd("bdelete")
  end, opts)
end

---------------------------------------------------------------------------
-- Autocmds
---------------------------------------------------------------------------

-- Window resizes fire many events in a row; coalesce them so a drag does not
-- spawn one image resize per pixel.
local resize_pending = false

local function schedule_resize()
  if resize_pending then
    return
  end
  resize_pending = true
  vim.defer_fn(function()
    resize_pending = false
    for buf, state in pairs(M._states) do
      if vim.api.nvim_buf_is_valid(buf) then
        render_page(state)
      end
    end
  end, 80)
end

---@param state buffer-preview.ViewerState
local function setup_autocmds(state)
  local group = vim.api.nvim_create_augroup("BufferPreviewViewer_" .. state.buf, { clear = true })
  state.augroup = group

  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    buffer = state.buf,
    callback = function()
      if M._states[state.buf] ~= state then
        return
      end
      state.win = vim.api.nvim_get_current_win()
      render_page(state)
    end,
  })

  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    buffer = state.buf,
    callback = function()
      -- Image placements use absolute screen coordinates, so they must not
      -- survive the buffer losing focus.
      display.clear(state.buf)
    end,
  })

  -- `WinResized` covers `:vsplit`, `<C-w><`, `<C-w>=` and dragging a split;
  -- it does NOT fire `VimResized`, which only fires for a terminal resize.
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = schedule_resize,
  })

  vim.api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    buffer = state.buf,
    callback = function()
      if M._states[state.buf] ~= state then
        return
      end
      -- Invalidate pending async work (soffice, pdfinfo, rasterizer).
      state.load_token = (state.load_token or 0) + 1
      state.req = (state.req or 0) + 1
      M._states[state.buf] = nil
      display.clear(state.buf)
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

---------------------------------------------------------------------------
-- Loading pipeline
---------------------------------------------------------------------------

---@param state buffer-preview.ViewerState
local function fail(state, message)
  state.message = message
  vim.notify(message, vim.log.levels.ERROR)
  local win = buf_window(state.buf)
  if win then
    update_status(state, win)
  end
end

--- Convert (if needed), read the page count, then render page 1.
---@param state buffer-preview.ViewerState
local function load(state)
  state.load_token = (state.load_token or 0) + 1
  local token = state.load_token

  local function current()
    return is_alive(state) and state.load_token == token
  end

  converter.to_pdf(state.source_path, function(pdf_path, convert_err)
    if not current() then
      return
    end

    if not pdf_path then
      fail(state, convert_err or "buffer-preview.nvim: failed to prepare the preview")
      return
    end

    state.pdf_path = pdf_path

    rasterizer.get_page_count(pdf_path, function(page_count, count_err)
      if not current() then
        return
      end

      if not page_count or page_count < 1 then
        fail(state, count_err or ("buffer-preview.nvim: could not determine page count for " .. state.source_path))
        return
      end

      state.page_count = page_count
      state.ready = true
      state.message = nil

      -- Wait until the hijacked buffer has been drawn once before the initial
      -- image render so image.nvim gets stable window geometry.
      vim.defer_fn(function()
        if current() then
          render_page(state)
        end
      end, 10)
    end)
  end)
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

--- Open a supported file in the current buffer as a read-only image viewer.
---@param source_path string Path to the source file (may be relative)
function M.open(source_path)
  source_path = vim.fn.fnamemodify(source_path, ":p")

  if vim.fn.filereadable(source_path) ~= 1 then
    vim.notify("buffer-preview.nvim: file not found: " .. source_path, vim.log.levels.ERROR)
    return
  end

  if not display.is_supported() then
    vim.notify(
      "buffer-preview.nvim: image.nvim is required but not installed. See :help buffer-preview-requirements",
      vim.log.levels.ERROR
    )
    return
  end

  local buf = vim.api.nvim_get_current_buf()

  -- Buffer options — read-only scratch buffer
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "pdf"
  -- Tells the BufEnter fallback in plugin/buffer-preview.lua that this buffer
  -- is already managed.
  vim.b[buf].buffer_preview_handled = true

  -- Window options — clean canvas
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].cursorline = false
  vim.wo[win].cursorcolumn = false
  vim.wo[win].colorcolumn = ""
  vim.wo[win].wrap = false
  vim.wo[win].statuscolumn = ""

  ---@type buffer-preview.ViewerState
  local state = {
    source_path = source_path,
    pdf_path = nil,
    page_count = 0,
    current_page = 1,
    buf = buf,
    win = win,
    augroup = 0,
    ready = false,
    req = 0,
    load_token = 0,
    message = "Loading…",
  }

  M._states[buf] = state

  setup_keymaps(state)
  setup_autocmds(state)
  update_status(state, win)

  rasterizer.prune_once()
  load(state)
end

return M
