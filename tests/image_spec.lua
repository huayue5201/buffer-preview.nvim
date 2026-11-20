--- Tests for the image (PDF/Office) preview pipeline.
---
--- image.nvim needs a terminal graphics backend, so its module is stubbed
--- here: the tests exercise the plugin's own logic (cache keys, page state,
--- zoom, prefetch, text panel, lifecycle), not the drawing itself.
local has_poppler = vim.fn.executable("pdftoppm") == 1 and vim.fn.executable("pdfinfo") == 1
local has_pdftotext = vim.fn.executable("pdftotext") == 1
local has_sqlite3 = vim.fn.executable("sqlite3") == 1

local fixture = vim.fn.fnamemodify("tests/fixtures/two-pages.pdf", ":p")

local renders = {}

local function reset_renders()
  for i = #renders, 1, -1 do
    renders[i] = nil
  end
end

local function stub_image()
  local id = 0
  return {
    from_file = function(path)
      id = id + 1
      local img = { id = id, path = path, global_state = { images = {} } }
      img.global_state.images[id] = img
      img.render = function(self)
        renders[#renders + 1] = self.path
      end
      img.clear = function() end
      return img
    end,
  }
end

local function reload_modules()
  for _, name in ipairs({
    "buffer-preview.config",
    "buffer-preview.image.converter",
    "buffer-preview.image.rasterizer",
    "buffer-preview.image.display",
    "buffer-preview.image.textview",
    "buffer-preview.image.viewer",
  }) do
    package.loaded[name] = nil
  end
end

local function cleanup(state)
  if not state then
    return
  end
  require("buffer-preview.image.textview").close(state)
  if vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
end

describe("buffer-preview.config", function()
  it("exposes the documented defaults", function()
    reload_modules()
    local config = require("buffer-preview.config")
    local cfg = config.setup({})
    assert.are.equal("pdftoppm", cfg.rasterizer)
    assert.are.equal(200, cfg.dpi)
    assert.are.equal(500, cfg.max_cache_size_mb)
    assert.is_true(cfg.prefetch)
    assert.are.equal(1000, cfg.sqlite_max_rows)
    assert.is_table(cfg.keymaps)
  end)

  it("merges partial keymap overrides and keeps the rest", function()
    reload_modules()
    local config = require("buffer-preview.config")
    local cfg = config.setup({ keymaps = { close = "Q" } })
    assert.are.equal("Q", cfg.keymaps.close)
    assert.are.equal("g", cfg.keymaps.first_page)
  end)

  it("supports disabling every keymap", function()
    reload_modules()
    local config = require("buffer-preview.config")
    assert.is_false(config.setup({ keymaps = false }).keymaps)
  end)

  it("normalises keymap values", function()
    reload_modules()
    local config = require("buffer-preview.config")
    config.setup({})
    assert.are.same({ "j" }, config.keys("j"))
    assert.are.same({ "j", "<Down>" }, config.keys({ "j", "<Down>" }))
    assert.are.same({}, config.keys(false))
    assert.are.same({}, config.keys(""))
  end)
end)

describe("buffer-preview.image.rasterizer", function()
  it("keys the page cache on dpi (zoom aware)", function()
    reload_modules()
    local config = require("buffer-preview.config")
    config.setup({ cache_dir = vim.fn.tempname() })
    local rasterizer = require("buffer-preview.image.rasterizer")
    assert.are_not.equal(rasterizer.get_cache_dir(fixture, 100), rasterizer.get_cache_dir(fixture, 150))
  end)

  it("counts the pages of a PDF and rasterizes one into the cache", function()
    if not has_poppler then
      return pending("poppler is not installed")
    end
    reload_modules()
    local cfg = require("buffer-preview.config").setup({ cache_dir = vim.fn.tempname(), dpi = 48 })
    local rasterizer = require("buffer-preview.image.rasterizer")

    local count
    rasterizer.get_page_count(fixture, function(n)
      count = n
    end)
    assert.is_true(vim.wait(10000, function()
      return count ~= nil
    end, 20))
    assert.are.equal(2, count)

    local dir = rasterizer.get_cache_dir(fixture)
    local png
    rasterizer.rasterize_page(fixture, 2, function(path)
      png = path
    end)
    assert.is_true(vim.wait(20000, function()
      return png ~= nil
    end, 20))
    assert.are.equal(dir .. "/page-2.png", png)

    -- A second request is served from the cache, without touching the file.
    local mtime = vim.uv.fs_stat(png).mtime.sec
    local again
    rasterizer.rasterize_page(fixture, 2, function(path)
      again = path
    end)
    assert.are.equal(png, again)
    assert.are.equal(mtime, vim.uv.fs_stat(png).mtime.sec)
    assert.are.equal(dir, cfg.cache_dir .. "/" .. vim.fn.sha256(fixture .. "|pdftoppm|48"):sub(1, 16))
  end)
end)

describe("buffer-preview.image.converter", function()
  it("knows which office documents soffice can convert", function()
    reload_modules()
    local converter = require("buffer-preview.image.converter")
    local seen = {}
    for _, ext in ipairs(converter.office_exts) do
      seen[ext] = true
    end
    assert.is_true(seen.docx)
    assert.is_true(seen.xlsx)
    assert.is_true(seen.pptx)
  end)

  it("rejects unsupported extensions synchronously", function()
    reload_modules()
    local converter = require("buffer-preview.image.converter")
    local err
    converter.to_pdf("/tmp/whatever.abc", function(_, e)
      err = e
    end)
    assert.is_truthy(err and err:match("unsupported"))
  end)
end)

describe("buffer-preview.image.viewer", function()
  local state

  before_each(function()
    package.loaded["image"] = stub_image()
    reload_modules()
    reset_renders()
    require("buffer-preview.config").setup({
      cache_dir = vim.fn.tempname(),
      dpi = 48,
      prefetch = true,
      zoom_step = 1.25,
    })
  end)

  after_each(function()
    cleanup(state)
    state = nil
    package.loaded["image"] = nil
  end)

  local function open_and_wait()
    local viewer = require("buffer-preview.image.viewer")
    local buf = vim.api.nvim_get_current_buf()
    viewer.open(fixture)
    state = viewer._states[buf]
    vim.wait(30000, function()
      return state.ready or (state.message ~= nil and state.message ~= "Loading…")
    end, 20)
    return viewer, state
  end

  it("loads a PDF and draws page 1", function()
    if not has_poppler then
      return pending("poppler is not installed")
    end
    open_and_wait()
    assert.are.equal(2, state.page_count)
    assert.are.equal(1, state.current_page)
    vim.wait(20000, function()
      return #renders > 0
    end, 20)
    assert.is_truthy(renders[#renders]:match("page%-1%.png$"))
  end)

  it("turns a page flip into a new rasterized page", function()
    if not has_poppler then
      return pending("poppler is not installed")
    end
    open_and_wait()
    vim.wait(20000, function()
      return #renders > 0
    end, 20)
    local before = #renders
    vim.api.nvim_feedkeys("j", "x", false)
    vim.wait(20000, function()
      return #renders > before
    end, 20)
    assert.are.equal(2, state.current_page)
    assert.is_truthy(renders[#renders]:match("page%-2%.png$"))
  end)

  it("prefetches the next page in the background", function()
    if not has_poppler then
      return pending("poppler is not installed")
    end
    open_and_wait()
    local rasterizer = require("buffer-preview.image.rasterizer")
    local dir = rasterizer.get_cache_dir(fixture, 48)
    local ok = vim.wait(30000, function()
      return vim.fn.filereadable(dir .. "/page-2.png") == 1
    end, 20)
    assert.is_true(ok)
  end)

  it("zooms by re-rasterizing at a higher dpi", function()
    if not has_poppler then
      return pending("poppler is not installed")
    end
    open_and_wait()
    vim.wait(20000, function()
      return #renders > 0
    end, 20)
    local before = #renders
    vim.api.nvim_feedkeys("+", "x", false)
    vim.wait(30000, function()
      return #renders > before
    end, 20)
    assert.is_true(math.abs(state.zoom - 1.25) < 1e-6)
    local rasterizer = require("buffer-preview.image.rasterizer")
    local zoom_dir = rasterizer.get_cache_dir(fixture, 60)
    assert.is_truthy(renders[#renders]:find(zoom_dir, 1, true))

    vim.api.nvim_feedkeys("=", "x", false)
    vim.wait(5000, function()
      return math.abs(state.zoom - 1) < 1e-6
    end, 20)
    assert.is_true(math.abs(state.zoom - 1) < 1e-6)
  end)

  it("shows and follows the page text panel", function()
    if not has_poppler or not has_pdftotext then
      return pending("poppler (with pdftotext) is not installed")
    end
    open_and_wait()
    vim.wait(20000, function()
      return #renders > 0
    end, 20)

    vim.api.nvim_feedkeys("t", "x", false)
    local textview = require("buffer-preview.image.textview")
    local ok = vim.wait(20000, function()
      return textview.is_open(state) and state.text_page == 1
    end, 20)
    assert.is_true(ok)
    local lines = vim.api.nvim_buf_get_lines(state.text_buf, 0, -1, false)
    assert.is_truthy(table.concat(lines, "\n"):find("Page one", 1, true))

    vim.api.nvim_set_current_win(state.win)
    vim.api.nvim_feedkeys("j", "x", false)
    vim.wait(20000, function()
      return state.text_page == 2
    end, 20)
    assert.are.equal(2, state.text_page)
    lines = vim.api.nvim_buf_get_lines(state.text_buf, 0, -1, false)
    assert.is_truthy(table.concat(lines, "\n"):find("Page two", 1, true))
  end)

  it("copies page text into the unnamed register", function()
    if not has_poppler or not has_pdftotext then
      return pending("poppler (with pdftotext) is not installed")
    end
    open_and_wait()
    vim.wait(20000, function()
      return #renders > 0
    end, 20)
    vim.fn.setreg('"', "")
    vim.api.nvim_feedkeys("y", "x", false)
    local ok = vim.wait(20000, function()
      return vim.fn.getreg('"'):find("Page one", 1, true) ~= nil
    end, 20)
    assert.is_true(ok)
  end)

  it("drops state and image registry entries when the buffer is wiped", function()
    if not has_poppler then
      return pending("poppler is not installed")
    end
    local viewer, st = open_and_wait()
    vim.wait(20000, function()
      return #renders > 0
    end, 20)
    local display = require("buffer-preview.image.display")
    assert.is_not_nil(display._images[st.buf])
    vim.api.nvim_buf_delete(st.buf, { force = true })
    assert.is_nil(viewer._states[st.buf])
    assert.is_nil(display._images[st.buf])
    state = nil
  end)

  it("honours keymaps = false", function()
    if not has_poppler then
      return pending("poppler is not installed")
    end
    cleanup(state)
    state = nil
    reload_modules()
    require("buffer-preview.config").setup({ cache_dir = vim.fn.tempname(), dpi = 48, keymaps = false })
    local viewer = require("buffer-preview.image.viewer")
    local buf = vim.api.nvim_get_current_buf()
    viewer.open(fixture)
    state = viewer._states[buf]
    vim.wait(30000, function()
      return state.ready
    end, 20)
    vim.api.nvim_feedkeys("j", "x", false)
    vim.wait(1000, function()
      return false
    end, 50)
    assert.are.equal(1, state.current_page)
  end)
end)

describe("buffer-preview.data.viewer", function()
  it("truncates large results and points at the export command", function()
    if not has_sqlite3 then
      return pending("sqlite3 is not installed")
    end
    reload_modules()
    require("buffer-preview.config").setup({ cache_dir = vim.fn.tempname(), sqlite_max_rows = 5 })

    local db = vim.fn.tempname() .. ".db"
    vim.fn.system({
      "sqlite3",
      db,
      "CREATE TABLE t(a); WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<20) INSERT INTO t SELECT i FROM c;",
    })

    local data_viewer = require("buffer-preview.data.viewer")
    local state = data_viewer.open(db)
    assert.is_not_nil(state)

    -- The initial schema query is asynchronous; wait for it to settle.
    vim.wait(10000, function()
      local lines = vim.api.nvim_buf_get_lines(state.top_buf, 0, -1, false)
      return lines[1] ~= nil and lines[1]:match("^type") ~= nil
    end, 20)

    vim.api.nvim_buf_set_lines(state.bottom_buf, 0, -1, false, { "SELECT * FROM t;" })
    vim.api.nvim_set_current_win(state.bottom_win)
    vim.cmd("BufferPreviewRunQuery")
    vim.wait(10000, function()
      local lines = vim.api.nvim_buf_get_lines(state.top_buf, 0, -1, false)
      return #lines == 7 and lines[1] == "a"
    end, 20)

    local lines = vim.api.nvim_buf_get_lines(state.top_buf, 0, -1, false)
    assert.are.equal(7, #lines) -- header + 5 rows + note
    assert.is_truthy(lines[7]:find("more rows not shown", 1, true))
    assert.is_truthy(lines[7]:find("BufferPreviewExport", 1, true))

    for _, buf in ipairs({ state.top_buf, state.bottom_buf }) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    vim.fn.delete(db)
  end)
end)
