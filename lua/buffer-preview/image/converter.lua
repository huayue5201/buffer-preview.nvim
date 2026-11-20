local config = require("buffer-preview.config")

local M = {}

--- Source extensions that `soffice` can turn into a PDF.
M.office_exts = {
  "pptx",
  "ppt",
  "odp",
  "docx",
  "doc",
  "odt",
  "rtf",
  "xlsx",
  "xls",
  "ods",
}

---@type table<string, boolean>
local office = {}
for _, ext in ipairs(M.office_exts) do
  office[ext] = true
end

--- In-flight conversions: abs source path -> job.
--- Keeps a second `:e` of the same presentation from starting a duplicate
--- `soffice` run (which also locks the profile and stalls).
---@class buffer-preview.ConvertJob
---@field entries { cb: fun(pdf_path: string|nil, err: string|nil) }[]
---@field handle vim.SystemObj|nil
---@field output string
---@type table<string, buffer-preview.ConvertJob>
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

---@class buffer-preview.AsyncJobCancel
---@field cancel fun()

--- Spawn (or join) the conversion job for one source file.
---@param absolute_path string
---@param callback fun(pdf_path: string|nil, err: string|nil)
---@return buffer-preview.AsyncJobCancel|nil
local function presentation_to_pdf(absolute_path, callback)
  local soffice = soffice_binary()
  if not soffice then
    callback(nil, "buffer-preview.nvim: soffice is required to preview office documents (install LibreOffice)")
    return nil
  end

  local output_dir = cache_dir_for(absolute_path)
  local base_name = vim.fn.fnamemodify(absolute_path, ":t:r")
  local output_path = output_dir .. "/" .. base_name .. ".pdf"

  if is_cache_fresh(absolute_path, output_path) then
    callback(output_path, nil)
    return nil
  end

  local job = M._inflight[absolute_path]
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
          M._inflight[absolute_path] = nil
          vim.fn.delete(output_path)
        end
      end,
    }
  end

  job = { entries = { { cb = callback } }, handle = nil, output = output_path }
  M._inflight[absolute_path] = job

  local function settle(pdf_path, err)
    if M._inflight[absolute_path] ~= job then
      return
    end
    M._inflight[absolute_path] = nil
    local entries = job.entries
    job.entries = {}
    for _, entry in ipairs(entries) do
      entry.cb(pdf_path, err)
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

  job.handle = vim.system(cmd, { text = true }, function(result)
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

  return {
    cancel = function()
      if M._inflight[absolute_path] ~= job then
        return
      end
      M._inflight[absolute_path] = nil
      if job.handle then
        pcall(function()
          job.handle:kill("sigterm")
        end)
      end
      vim.fn.delete(output_path)
    end,
  }
end

--- Resolve a previewable source file to a PDF path, asynchronously.
---
--- PDFs resolve synchronously (the callback runs before this function
--- returns); office documents go through a `soffice` conversion.
---
---@param source_path string
---@param callback fun(pdf_path: string|nil, err: string|nil)
---@return buffer-preview.AsyncJobCancel|nil token that cancels the conversion
function M.to_pdf(source_path, callback)
  local absolute_path = vim.fn.fnamemodify(source_path, ":p")
  local extension = vim.fn.fnamemodify(absolute_path, ":e"):lower()

  if extension == "pdf" then
    callback(absolute_path, nil)
    return nil
  end

  if office[extension] then
    return presentation_to_pdf(absolute_path, callback)
  end

  callback(nil, "buffer-preview.nvim: unsupported file type: ." .. extension)
  return nil
end

return M
