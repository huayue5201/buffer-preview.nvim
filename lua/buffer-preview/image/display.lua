--- Image display for buffer-preview.nvim.
--- Delegates all rendering to image.nvim (3rd/image.nvim), which handles
--- Kitty, ueberzug, and sixel backends transparently.
---
--- Two invariants keep the display correct:
---   * one image object per buffer, reused across resizes and refreshes;
---   * cleared objects are removed from image.nvim's registry, because that
---     registry is what `WinScrolled` / `WinResized` re-render from.
local M = {}

--- Active image objects keyed by buffer number.
---@type table<number, table>
M._images = {}

--- Drop an image from image.nvim's global registry.
---
--- `Image:clear()` only clears the terminal placement; the object stays in
--- `state.images`, and the next `WinScrolled` / `WinResized` / `WinNew`
--- handler re-renders it with its stale geometry — which is exactly how two
--- pages end up stacked on top of each other.
---@param img table
local function unregister(img)
  local state = img.global_state
  if type(state) == "table" and type(state.images) == "table" and img.id then
    state.images[img.id] = nil
  end
end

--- Cell geometry for an image that fills a window, minus the status line.
---@param win_id number
---@return number width, number height
local function geometry(win_id)
  local width = math.max(vim.api.nvim_win_get_width(win_id), 1)
  local height = math.max(vim.api.nvim_win_get_height(win_id) - 1, 1)
  return width, height
end

--- Remove the currently displayed image for a buffer.
---@param buf number
function M.clear(buf)
  local img = M._images[buf]
  if not img then
    return
  end

  M._images[buf] = nil
  pcall(function()
    img:clear()
  end)
  unregister(img)
end

--- Render a PNG image inside a Neovim window via image.nvim.
---
--- When the same image is already shown in the same window, its geometry is
--- updated in place instead of creating a second object. This is what makes
--- window resizing work: image.nvim caches `width`/`height` on the object, so
--- a fresh object with new sizes would leave the old one behind.
---
---@param image_path string Absolute path to the PNG file
---@param win_id number Neovim window handle
---@param buf number Buffer number
---@return boolean shown
function M.show(image_path, win_id, buf)
  local ok, api = pcall(require, "image")
  if not ok then
    vim.notify("buffer-preview.nvim: image.nvim is required but not found", vim.log.levels.ERROR)
    return false
  end

  if not vim.api.nvim_win_is_valid(win_id) then
    return false
  end

  local width, height = geometry(win_id)
  local current = M._images[buf]

  if current and current._bp_path == image_path and current._bp_win == win_id then
    local rendered = pcall(function()
      current:render({ x = 0, y = 0, width = width, height = height })
    end)
    if rendered then
      return true
    end
  end

  local new_img = api.from_file(image_path, {
    window = win_id,
    buffer = buf,
    with_virtual_padding = false,
    inline = false,
    x = 0,
    y = 0,
    width = width,
    height = height,
    -- Override image.nvim's global caps (default max_height_window_percentage = 50)
    -- so the PDF page fills the entire window.
    max_width_window_percentage = 100,
    max_height_window_percentage = 100,
  })

  if not new_img then
    return false
  end

  new_img._bp_path = image_path
  new_img._bp_win = win_id

  -- Render the replacement image before clearing the previous one so page
  -- navigation swaps in-place instead of flashing an older cached frame.
  new_img:render()

  if current then
    pcall(function()
      current:clear()
    end)
    unregister(current)
  end

  M._images[buf] = new_img
  return true
end

--- Check whether image.nvim is available.
---@return boolean
function M.is_supported()
  local ok = pcall(require, "image")
  return ok
end

return M
