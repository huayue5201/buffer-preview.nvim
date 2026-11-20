---@class buffer-preview.Config
---@field rasterizer string "pdftoppm" or "pdftocairo"
---@field dpi number Rasterization DPI
---@field cache_dir string Cache directory for rendered page images
---@field cache_max_age_days number|false Prune cached pages older than this many days (false disables)

---@class buffer-preview.UserConfig
---@field rasterizer? string
---@field dpi? number
---@field cache_dir? string
---@field cache_max_age_days? number|false

local M = {}

---@type buffer-preview.Config
local defaults = {
  rasterizer = "pdftoppm",
  dpi = 200,
  cache_dir = vim.fn.stdpath("cache") .. "/buffer-preview.nvim",
  cache_max_age_days = 30,
}

---@type buffer-preview.Config
local state = vim.deepcopy(defaults)

---@return buffer-preview.Config
function M.get()
  return state
end

---@param opts buffer-preview.UserConfig|nil
---@return buffer-preview.Config
function M.setup(opts)
  state = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  return state
end

return M
