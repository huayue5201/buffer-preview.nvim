--- `:checkhealth buffer-preview` — verify the external tools the previews need.
local config = require("buffer-preview.config")

local M = {}

---@param name string
---@return boolean
local function binary(name)
  return vim.fn.executable(name) == 1
end

---@param h table
---@param name string
---@param hint string
---@param required boolean
local function report_binary(h, name, hint, required)
  if binary(name) then
    h.ok(name .. " found")
  elseif required then
    h.error(name .. " not found", { hint })
  else
    h.warn(name .. " not found", { hint })
  end
end

function M.check()
  local h = vim.health
  h.start("buffer-preview.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim >= 0.10")
  else
    h.error("Neovim >= 0.10 is required", { "The plugin relies on vim.system() and vim.uv" })
  end

  ---------------------------------------------------------------------------
  h.start("Rendering")
  ---------------------------------------------------------------------------

  if pcall(require, "image") then
    h.ok("image.nvim is installed")
    h.info("Run `:checkhealth image` to verify the terminal graphics protocol")
  else
    h.error("image.nvim is not installed", {
      "Page images are handed to image.nvim for display",
      "Install https://github.com/3rd/image.nvim",
    })
  end

  report_binary(
    h,
    "pdftoppm",
    "brew install poppler (or set rasterizer = 'pdftocairo' with pdftocairo installed)",
    true
  )
  report_binary(h, "pdftocairo", "Optional alternative rasterizer: brew install poppler", false)
  report_binary(h, "pdfinfo", "brew install poppler", true)
  report_binary(h, "pdftotext", "brew install poppler — needed by `t` (page text) and `y` (copy page text)", false)
  report_binary(h, "soffice", "brew install --cask libreoffice — needed for pptx/docx/xlsx previews", false)

  local cfg = config.get()
  h.info(string.format("rasterizer: %s, dpi: %d, prefetch: %s", cfg.rasterizer, cfg.dpi, tostring(cfg.prefetch)))

  ---------------------------------------------------------------------------
  h.start("SQLite workspace")
  ---------------------------------------------------------------------------

  report_binary(h, "sqlite3", "brew install sqlite — needed for .db/.sqlite previews", false)

  ---------------------------------------------------------------------------
  h.start("Cache")
  ---------------------------------------------------------------------------

  local dir = cfg.cache_dir
  vim.fn.mkdir(dir, "p")
  if vim.fn.filewritable(dir) == 1 then
    local rasterizer = require("buffer-preview.image.rasterizer")
    local size = rasterizer.path_size(dir)
    h.ok(string.format("%s (%.1f MiB)", dir, size / 1024 / 1024))
    if type(cfg.max_cache_size_mb) == "number" and cfg.max_cache_size_mb > 0 then
      h.info(
        string.format("size cap: %d MiB, age cap: %s days", cfg.max_cache_size_mb, tostring(cfg.cache_max_age_days))
      )
    end
  else
    h.error("cache directory is not writable: " .. dir)
  end
end

return M
