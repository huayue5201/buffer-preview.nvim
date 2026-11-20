--- PDF page rasterization for buffer-preview.nvim.
--- Converts individual PDF pages to PNG images using pdftoppm or pdftocairo,
--- and extracts their text layer with pdftotext.
---
--- Everything here is asynchronous: the previous implementation blocked the
--- UI with `vim.fn.system`, which turned page flips on large PDFs and
--- presentation conversion into visible freezes.
local config = require("buffer-preview.config")

local M = {}

---@class buffer-preview.RasterJob
---@field entries { cb: fun(png_path: string|nil, err: string|nil) }[]
---@field handle vim.SystemObj|nil
---@field output string

--- In-flight rasterizations keyed by "<dir>/page-<n>".
---@type table<string, buffer-preview.RasterJob>
M._inflight = {}

---@class buffer-preview.AsyncJobCancel
---@field cancel fun()

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
    callback(nil, "buffer-preview.nvim: pdfinfo is required to read the page count (install poppler)")
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
--- `dpi`, zooming, or switching `rasterizer` never serves page images
--- rendered with the previous settings.
---@param pdf_path string
---@param dpi? number
---@return string
function M.get_cache_dir(pdf_path, dpi)
  local cfg = config.get()
  local key = table.concat({ pdf_path, cfg.rasterizer, tostring(dpi or cfg.dpi) }, "|")
  local hash = vim.fn.sha256(key)
  local dir = cfg.cache_dir .. "/" .. hash:sub(1, 16)
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Cache directory for extracted page text (independent of dpi/zoom).
---@param pdf_path string
---@return string
function M.get_text_dir(pdf_path)
  local cfg = config.get()
  local hash = vim.fn.sha256(pdf_path)
  local dir = cfg.cache_dir .. "/text/" .. hash:sub(1, 16)
  vim.fn.mkdir(dir, "p")
  return dir
end

---@param rendered_path string
---@param pdf_path string
---@return boolean
local function is_cache_fresh(rendered_path, pdf_path)
  if vim.fn.filereadable(rendered_path) ~= 1 then
    return false
  end

  -- Re-render when the PDF itself changed (e.g. a presentation that was
  -- re-converted), instead of showing pages from the old document.
  local rendered_mtime = vim.fn.getftime(rendered_path)
  local pdf_mtime = vim.fn.getftime(pdf_path)
  return rendered_mtime > 0 and pdf_mtime > 0 and rendered_mtime >= pdf_mtime
end

--- Rasterize a single PDF page to PNG (asynchronous).
---
--- Returns the cached image through the callback when it exists and is newer
--- than the PDF. Concurrent requests for the same page share one process.
---
---@param pdf_path string Absolute path to the PDF
---@param page_num number 1-indexed page number
---@param callback fun(png_path: string|nil, err: string|nil)
---@param dpi? number Override the configured dpi (used for zoom)
---@return buffer-preview.AsyncJobCancel|nil token that cancels the rasterization
function M.rasterize_page(pdf_path, page_num, callback, dpi)
  local cfg = config.get()
  dpi = dpi or cfg.dpi
  local cache_dir = M.get_cache_dir(pdf_path, dpi)
  local output_prefix = cache_dir .. "/page-" .. page_num
  local output_path = output_prefix .. ".png"

  if is_cache_fresh(output_path, pdf_path) then
    callback(output_path, nil)
    return nil
  end

  local job = M._inflight[output_prefix]
  if job then
    local entry = { cb = callback }
    job.entries[#job.entries + 1] = entry
    return {
      cancel = function()
        for i, e in ipairs(job.entries) do
          if e == entry then
            table.remove(job.entries, i)
            break
          end
        end
        if #job.entries == 0 then
          if job.handle then
            pcall(function()
              job.handle:kill("sigterm")
            end)
          end
          M._inflight[output_prefix] = nil
          vim.fn.delete(output_path)
        end
      end,
    }
  end

  local function settle(png_path, err)
    if M._inflight[output_prefix] ~= job then
      return
    end
    M._inflight[output_prefix] = nil
    local entries = job.entries
    job.entries = {}
    for _, entry in ipairs(entries) do
      entry.cb(png_path, err)
    end
  end

  local binary = rasterizer_binary()
  if not binary then
    callback(
      nil,
      "buffer-preview.nvim: " .. tostring(cfg.rasterizer) .. " is required to render PDF pages (install poppler)"
    )
    return nil
  end

  job = { entries = { { cb = callback } }, handle = nil, output = output_path }
  M._inflight[output_prefix] = job

  local cmd = {
    binary,
    "-png",
    "-f",
    tostring(page_num),
    "-l",
    tostring(page_num),
    "-r",
    tostring(dpi),
    "-singlefile",
    pdf_path,
    output_prefix,
  }

  job.handle = vim.system(cmd, { text = true }, function(result)
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

  return {
    cancel = function()
      if M._inflight[output_prefix] ~= job then
        return
      end
      M._inflight[output_prefix] = nil
      if job.handle then
        pcall(function()
          job.handle:kill("sigterm")
        end)
      end
      vim.fn.delete(output_path)
    end,
  }
end

--- Warm the cache for a page without caring about the result.
---@param pdf_path string
---@param page_num number
---@param dpi? number
function M.prefetch(pdf_path, page_num, dpi)
  if page_num < 1 then
    return
  end
  if M._inflight[M.get_cache_dir(pdf_path, dpi) .. "/page-" .. page_num] then
    return
  end
  M.rasterize_page(pdf_path, page_num, function() end, dpi)
end

--- Extract the text layer of one page (asynchronous).
---@param pdf_path string
---@param page_num number
---@param callback fun(text: string|nil, err: string|nil)
function M.page_text(pdf_path, page_num, callback)
  if vim.fn.executable("pdftotext") ~= 1 then
    callback(nil, "buffer-preview.nvim: pdftotext is required to view page text (install poppler)")
    return
  end

  local dir = M.get_text_dir(pdf_path)
  local output_path = dir .. "/page-" .. page_num .. ".txt"

  if is_cache_fresh(output_path, pdf_path) then
    local ok, lines = pcall(vim.fn.readfile, output_path)
    if ok then
      callback(table.concat(lines, "\n"), nil)
      return
    end
  end

  local cmd =
    { "pdftotext", "-f", tostring(page_num), "-l", tostring(page_num), "-layout", "-enc", "UTF-8", pdf_path, "-" }
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, "buffer-preview.nvim: failed to extract text from page " .. page_num)
        return
      end
      local text = result.stdout or ""
      pcall(vim.fn.writefile, vim.split(text, "\n", { plain = true }), output_path)
      callback(text, nil)
    end)
  end)
end

--- Remove all cached page images for a PDF file.
---@param pdf_path string
function M.cleanup(pdf_path)
  local cache_dir = M.get_cache_dir(pdf_path)
  vim.fn.delete(cache_dir, "rf")
end

--- Size of a path in bytes (blocking; only used off the hot path).
---@param path string
---@return number
function M.path_size(path)
  local out = vim.fn.system({ "du", "-sk", path })
  local kb = tonumber((out or ""):match("^(%d+)"))
  return (kb or 0) * 1024
end

--- Delete the oldest cache units until the cache fits in `max_cache_size_mb`.
---
--- Cache units are the per-document hash directories, both for rasterized
--- pages and converted PDFs. Age comes from mtime, so recently previewed
--- documents survive.
---@param callback? fun(removed: number)
function M.enforce_cache_limit(callback)
  local cfg = config.get()
  local limit_mb = cfg.max_cache_size_mb
  local done = function(removed)
    if callback then
      callback(removed)
    end
  end

  if type(limit_mb) ~= "number" or limit_mb <= 0 then
    done(0)
    return
  end

  local limit = limit_mb * 1024 * 1024

  vim.schedule(function()
    local root = cfg.cache_dir
    if vim.fn.isdirectory(root) ~= 1 then
      done(0)
      return
    end

    ---@type { path: string, size: number, mtime: number }[]
    local units = {}
    for _, base in ipairs({ root, root .. "/converted" }) do
      local ok, iter = pcall(vim.fs.dir, base)
      if ok then
        for name, kind in iter do
          local path = base .. "/" .. name
          local stat = vim.uv.fs_stat(path)
          if kind == "directory" and stat then
            units[#units + 1] = {
              path = path,
              size = M.path_size(path),
              mtime = stat.mtime and stat.mtime.sec or 0,
            }
          end
        end
      end
    end

    local total = 0
    for _, unit in ipairs(units) do
      total = total + unit.size
    end

    table.sort(units, function(a, b)
      return a.mtime < b.mtime
    end)

    local removed = 0
    for _, unit in ipairs(units) do
      if total <= limit then
        break
      end
      if vim.fn.delete(unit.path, "rf") == 0 then
        total = total - unit.size
        removed = removed + 1
      end
    end

    done(removed)
  end)
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
--- Age-based pruning runs first, then the size cap.
function M.prune_once()
  if M._pruned then
    return
  end
  M._pruned = true
  vim.defer_fn(function()
    M.prune(function()
      M.enforce_cache_limit()
    end)
  end, 5000)
end

return M
