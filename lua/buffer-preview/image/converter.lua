local config = require("buffer-preview.config")

local M = {}

--- In-flight conversions: abs source path -> pending callbacks.
--- Keeps a second `:e` of the same presentation from starting a duplicate
--- `soffice` run (which also locks the profile and stalls).
---@type table<string, fun(pdf_path: string|nil, err: string|nil)[]>
M._inflight = {}

---@param source_path string
---@return string
local function cache_dir_for(source_path)
  local cfg = config.get()
  local hash = vim.fn.sha256(source_path)
  local dir = cfg.cache_dir .. "/converted/" .. hash:sub(1, 16)
  vim.fn.mkdir(dir, "p")
  return dir
end

---@param source_path string
---@param output_path string
---@return boolean
local function is_cache_fresh(source_path, output_path)
  if vim.fn.filereadable(output_path) ~= 1 then
    return false
  end

  local source_mtime = vim.fn.getftime(source_path)
  local output_mtime = vim.fn.getftime(output_path)
  return source_mtime > 0 and output_mtime >= source_mtime
end

---@return string|nil
local function soffice_binary()
  if vim.fn.executable("soffice") == 1 then
    return "soffice"
  end

  return nil
end

---@param source_path string
---@param callback fun(pdf_path: string|nil, err: string|nil)
local function presentation_to_pdf(source_path, callback)
  local soffice = soffice_binary()
  if not soffice then
    callback(nil, "buffer-preview.nvim: soffice is required to preview presentation files")
    return
  end

  local absolute_path = vim.fn.fnamemodify(source_path, ":p")
  local output_dir = cache_dir_for(absolute_path)
  local base_name = vim.fn.fnamemodify(absolute_path, ":t:r")
  local output_path = output_dir .. "/" .. base_name .. ".pdf"

  if is_cache_fresh(absolute_path, output_path) then
    callback(output_path, nil)
    return
  end

  -- Join an already running conversion for the same source instead of
  -- spawning a second soffice process.
  local pending = M._inflight[absolute_path]
  if pending then
    pending[#pending + 1] = callback
    return
  end
  M._inflight[absolute_path] = { callback }

  local function settle(pdf_path, err)
    local callbacks = M._inflight[absolute_path] or {}
    M._inflight[absolute_path] = nil
    for _, cb in ipairs(callbacks) do
      cb(pdf_path, err)
    end
  end

  local cmd = {
    soffice,
    "--headless",
    "--convert-to",
    "pdf",
    "--outdir",
    output_dir,
    absolute_path,
  }

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        settle(nil, "buffer-preview.nvim: failed to convert the presentation to PDF with soffice")
        return
      end

      if vim.fn.filereadable(output_path) ~= 1 then
        settle(nil, "buffer-preview.nvim: soffice did not produce a PDF output")
        return
      end

      settle(output_path, nil)
    end)
  end)
end

--- Resolve a previewable source file to a PDF path, asynchronously.
---
--- PDFs resolve synchronously (the callback runs before this function
--- returns); presentations go through a `soffice` conversion.
---
---@param source_path string
---@param callback fun(pdf_path: string|nil, err: string|nil)
function M.to_pdf(source_path, callback)
  local absolute_path = vim.fn.fnamemodify(source_path, ":p")
  local extension = vim.fn.fnamemodify(absolute_path, ":e"):lower()

  if extension == "pdf" then
    callback(absolute_path, nil)
    return
  end

  if extension == "pptx" or extension == "ppt" or extension == "odp" then
    presentation_to_pdf(absolute_path, callback)
    return
  end

  callback(nil, "buffer-preview.nvim: unsupported file type: ." .. extension)
end

return M
