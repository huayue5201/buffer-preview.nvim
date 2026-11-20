--- PDF page rasterization for buffer-preview.nvim.
--- Converts individual PDF pages to PNG images using pdftoppm or pdftocairo.
---
--- Everything here is asynchronous: the previous implementation blocked the
--- UI with `vim.fn.system`, which turned page flips on large PDFs and
--- presentation conversion into visible freezes.
local config = require("buffer-preview.config")

local M = {}

--- In-flight rasterizations keyed by "<dir>/page-<n>".
---@type table<string, fun(png_path: string|nil, err: string|nil)[]>
M._inflight = {}

local function rasterizer_binary()
  local cfg = config.get()
  local name = cfg.rasterizer == "pdftocairo" and "pdftocairo" or "pdftoppm"
  if vim.fn.executable(name) == 1 then
    return name
  end
  return nil
end

--- Get the number of pages in a PDF file.
---@param pdf_path string
---@param callback fun(page_count: number|nil, err: string|nil)
function M.get_page_count(pdf_path, callback)
  if vim.fn.executable("pdfinfo") ~= 1 then
    callback(nil, "buffer-preview.nvim: pdfinfo is required to read the page count")
    return
  end

  -- `vim.system` callbacks may run in a fast event context where buffer APIs
  -- are forbidden, so re-enter the main loop before touching editor state.
  vim.system({ "pdfinfo", pdf_path }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, "buffer-preview.nvim: could not determine page count for " .. pdf_path)
        return
      end

      for _, line in ipairs(vim.split(result.stdout or "", "\n")) do
        local pages = line:match("^Pages:%s*(%d+)")
        if pages then
          callback(tonumber(pages), nil)
          return
        end
      end

      callback(nil, "buffer-preview.nvim: could not determine page count for " .. pdf_path)
    end)
  end)
end

--- Build a deterministic cache directory for a given PDF file.
---
--- The hash covers the rendering parameters as well as the path, so changing
--- `dpi` or `rasterizer` no longer silently serves page images rendered with
--- the previous settings.
---@param pdf_path string
---@return string
function M.get_cache_dir(pdf_path)
  local cfg = config.get()
  local key = table.concat({ pdf_path, cfg.rasterizer, tostring(cfg.dpi) }, "|")
  local hash = vim.fn.sha256(key)
  local dir = cfg.cache_dir .. "/" .. hash:sub(1, 16)
  vim.fn.mkdir(dir, "p")
  return dir
end

---@param png_path string
---@param pdf_path string
---@return boolean
local function is_cache_fresh(png_path, pdf_path)
  if vim.fn.filereadable(png_path) ~= 1 then
    return false
  end

  -- Re-render when the PDF itself changed (e.g. a presentation that was
  -- re-converted), instead of showing pages from the old document.
  local png_mtime = vim.fn.getftime(png_path)
  local pdf_mtime = vim.fn.getftime(pdf_path)
  return png_mtime > 0 and pdf_mtime > 0 and png_mtime >= pdf_mtime
end

--- Rasterize a single PDF page to PNG (asynchronous).
---
--- Returns the cached image through the callback when it exists and is newer
--- than the PDF. Concurrent requests for the same page share one process.
---
---@param pdf_path string Absolute path to the PDF
---@param page_num number 1-indexed page number
---@param callback fun(png_path: string|nil, err: string|nil)
function M.rasterize_page(pdf_path, page_num, callback)
  local cfg = config.get()
  local cache_dir = M.get_cache_dir(pdf_path)
  local output_prefix = cache_dir .. "/page-" .. page_num
  local output_path = output_prefix .. ".png"

  if is_cache_fresh(output_path, pdf_path) then
    callback(output_path, nil)
    return
  end

  local pending = M._inflight[output_prefix]
  if pending then
    pending[#pending + 1] = callback
    return
  end
  M._inflight[output_prefix] = { callback }

  local function settle(png_path, err)
    local callbacks = M._inflight[output_prefix] or {}
    M._inflight[output_prefix] = nil
    for _, cb in ipairs(callbacks) do
      cb(png_path, err)
    end
  end

  local binary = rasterizer_binary()
  if not binary then
    settle(nil, "buffer-preview.nvim: " .. tostring(cfg.rasterizer) .. " is required to render PDF pages")
    return
  end

  local cmd = {
    binary,
    "-png",
    "-f",
    tostring(page_num),
    "-l",
    tostring(page_num),
    "-r",
    tostring(cfg.dpi),
    "-singlefile",
    pdf_path,
    output_prefix,
  }

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        settle(nil, "buffer-preview.nvim: failed to render page " .. page_num)
        return
      end

      if vim.fn.filereadable(output_path) ~= 1 then
        settle(nil, "buffer-preview.nvim: failed to render page " .. page_num)
        return
      end

      settle(output_path, nil)
    end)
  end)
end

--- Remove all cached page images for a PDF file.
---@param pdf_path string
function M.cleanup(pdf_path)
  local cache_dir = M.get_cache_dir(pdf_path)
  vim.fn.delete(cache_dir, "rf")
end

--- Delete cache directories that have not been touched for a while.
---
--- Runs at most once per session, off the main path, so a long-lived cache
--- directory does not grow without bound.
---@param callback? fun(removed: number)
function M.prune(callback)
  local cfg = config.get()
  local max_age_days = cfg.cache_max_age_days
  if type(max_age_days) ~= "number" or max_age_days <= 0 then
    if callback then
      callback(0)
    end
    return
  end

  local root = cfg.cache_dir
  if vim.fn.isdirectory(root) ~= 1 then
    if callback then
      callback(0)
    end
    return
  end

  local cutoff = os.time() - math.floor(max_age_days * 86400)
  local removed = 0

  local function prune_leaf(root_dir)
    local ok, entries = pcall(vim.fs.dir, root_dir)
    if not ok then
      return
    end
    for name, kind in entries do
      local path = root_dir .. "/" .. name
      if kind == "directory" then
        local stat = vim.uv.fs_stat(path)
        -- Both the rasterized pages and the converted PDFs live one level
        -- below a hash directory, so a stale hash directory is the unit of
        -- deletion here.
        if stat and stat.mtime and stat.mtime.sec < cutoff then
          if vim.fn.delete(path, "rf") == 0 then
            removed = removed + 1
          end
        end
      end
    end
  end

  vim.schedule(function()
    prune_leaf(root)
    local converted = root .. "/converted"
    if vim.fn.isdirectory(converted) == 1 then
      prune_leaf(converted)
    end
    if callback then
      callback(removed)
    end
  end)
end

--- Run `prune()` once, after startup, so it never delays the first preview.
function M.prune_once()
  if M._pruned then
    return
  end
  M._pruned = true
  vim.defer_fn(function()
    M.prune()
  end, 5000)
end

return M
