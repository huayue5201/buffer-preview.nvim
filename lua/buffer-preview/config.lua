---@class buffer-preview.Keymaps
---@field next_page string|string[]|false
---@field prev_page string|string[]|false
---@field first_page string|string[]|false
---@field last_page string|string[]|false
---@field zoom_in string|string[]|false
---@field zoom_out string|string[]|false
---@field zoom_reset string|string[]|false
---@field page_text string|string[]|false  Toggle the page-text side panel
---@field yank_page_text string|string[]|false  Copy the current page text
---@field refresh string|string[]|false
---@field close string|string[]|false

---@class buffer-preview.Config
---@field rasterizer string "pdftoppm" or "pdftocairo"
---@field dpi number Base rasterization DPI (zoom multiplies this)
---@field cache_dir string Cache directory for rendered page images
---@field cache_max_age_days number|false Prune cached pages older than this many days (false disables)
---@field max_cache_size_mb number|false Cap the total cache size in MiB (false disables)
---@field prefetch boolean Pre-render the next page in the background
---@field zoom_step number Zoom factor applied by the zoom keymaps
---@field keymaps buffer-preview.Keymaps|false `false` disables every viewer keymap
---@field sqlite_max_rows number Maximum result rows rendered in the SQL workspace

---@class buffer-preview.UserConfig
---@field rasterizer? string
---@field dpi? number
---@field cache_dir? string
---@field cache_max_age_days? number|false
---@field max_cache_size_mb? number|false
---@field prefetch? boolean
---@field zoom_step? number
---@field keymaps? buffer-preview.Keymaps|false
---@field sqlite_max_rows? number

local M = {}

---@type buffer-preview.Config
local defaults = {
  rasterizer = "pdftoppm",
  dpi = 200,
  cache_dir = vim.fn.stdpath("cache") .. "/buffer-preview.nvim",
  cache_max_age_days = 30,
  max_cache_size_mb = 500,
  prefetch = true,
  zoom_step = 1.25,
  keymaps = {
    next_page = { "j", "<Down>", "]", "}", "<C-d>", "<C-f>", "<Space>", "l" },
    prev_page = { "k", "<Up>", "[", "{", "<C-u>", "<C-b>", "h" },
    first_page = "g",
    last_page = "G",
    zoom_in = "+",
    zoom_out = "-",
    zoom_reset = "=",
    page_text = "t",
    yank_page_text = "y",
    refresh = { "r", "<C-l>" },
    close = "q",
  },
  sqlite_max_rows = 1000,
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

--- Normalise a keymap value to a list of keys (`false`/`nil` disables it).
---@param value string|string[]|false|nil
---@return string[]
function M.keys(value)
  if value == false or value == nil then
    return {}
  end
  if type(value) == "string" then
    return value == "" and {} or { value }
  end
  local keys = {}
  for _, key in ipairs(value) do
    if type(key) == "string" and key ~= "" then
      keys[#keys + 1] = key
    end
  end
  return keys
end

return M
