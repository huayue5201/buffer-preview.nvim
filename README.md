<div align="center">

<h1>
  <img src="assets/logo.svg" alt="buffer-preview.nvim logo" width="45" height="45" align="absmiddle" />
  buffer-preview.nvim
</h1>

Give your Neovim buffers real previews instead of raw file bytes.

![Neovim version](https://img.shields.io/badge/Neovim-0.10.0%2B-57A143?style=for-the-badge&labelColor=1E1E2E)
![License](https://img.shields.io/github/license/huayue5201/buffer-preview.nvim?style=for-the-badge&labelColor=1E1E2E&color=3B8ED0)
![Last Release](https://img.shields.io/github/v/release/huayue5201/buffer-preview.nvim?style=for-the-badge&labelColor=1E1E2E&color=3B8ED0)
![GitHub issues](https://img.shields.io/github/issues/huayue5201/buffer-preview.nvim?style=for-the-badge&labelColor=1E1E2E&color=3B8ED0)
![GitHub last commit](https://img.shields.io/github/last-commit/huayue5201/buffer-preview.nvim?style=for-the-badge&labelColor=1E1E2E&color=3B8ED0)

[Features](#features) • [Install](#installation) • [Usage](#usage)

<img src="assets/example-pdf.png" alt="buffer-preview.nvim rendering a PDF directly inside a Neovim buffer" width="50%" />
<img src="assets/example-presentation.png" alt="buffer-preview.nvim rendering a presentation directly inside a Neovim buffer" width="49%" />

<img src="assets/example-sqlite.png" alt="buffer-preview.nvim opening a SQLite database in a two-buffer SQL workspace" width="100%" />

`buffer-preview.nvim` hijacks the normal buffer read for supported
files and replaces raw bytes with a read-only, navigable in-buffer preview.
Keep the document inside Neovim, move with familiar Vim keys, and avoid
context-switching to a separate viewer.

</div>

> This repository is a maintained fork of
> [propilideno/buffer-preview.nvim](https://github.com/propilideno/buffer-preview.nvim)
> (upstream has been inactive since 2026-05). Changes in this fork:
>
> - the page image rescales with the window (`WinResized`/`VimResized`, resized in place)
> - mouse-wheel page flipping actually works (the window check used a field that was never set)
> - clearing a page no longer leaves the old image in image.nvim's registry, which caused two
>   pages to be drawn on top of each other after scrolling or resizing
> - conversion, page counting and rasterization are asynchronous, so the UI no longer freezes
> - cached pages are keyed by `dpi`/rasterizer and invalidated when the source changes
> - stale cache entries are pruned, `:BufferPreviewCleanCache` wipes them on demand,
>   and `max_cache_size_mb` caps the cache size
> - page text side channel: `t` opens a searchable text panel, `y` yanks the page text
> - zoom in/out (`+`/`-`), which re-rasterizes at a higher DPI instead of stretching
> - the next page is prefetched in the background, office conversions can be cancelled
> - `.docx`, `.doc`, `.odt`, `.rtf`, `.xlsx`, `.xls`, `.ods` are previewed too
> - every keymap is configurable (`keymaps = false` to use your own)
> - `:checkhealth buffer-preview` reports missing dependencies
> - SQLite results are capped by `sqlite_max_rows`; `:BufferPreviewExport` saves the
>   full result as CSV


## Requirements

The requirements depends on which preview you want, install only what you need.

### Image preview

For PDF and office documents (`.pdf`, `.pptx`, `.ppt`, `.odp`, `.docx`, `.doc`,
`.odt`, `.rtf`, `.xlsx`, `.xls`, `.ods`):

- [image.nvim](https://github.com/3rd/image.nvim): handles image rendering
- ImageMagick: required by image.nvim
- pdftoppm: required to convert pdf to png
- pdfinfo: required to show metadata (status line)
- pdftotext: optional, enables the page text panel (`t`) and `y`
- soffice: for office document conversion (.pptx, .docx, .xlsx, ...)

#### Tmux support

For running image preview inside tmux, add to `~/.tmux.conf`:

```tmux
# https://github.com/3rd/image.nvim#tmux
set -gq allow-passthrough on
set -g visual-activity off
set -g focus-events on
```

### Data preview

- sqlite3: for SQLite files (.db, .sqlite, .sqlite3)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "huayue5201/buffer-preview.nvim",
  event = {
    -- Image preview
    "BufReadCmd *.pdf", "BufReadCmd *.pptx", "BufReadCmd *.ppt", "BufReadCmd *.odp",
    "BufReadCmd *.docx", "BufReadCmd *.doc", "BufReadCmd *.odt", "BufReadCmd *.rtf",
    "BufReadCmd *.xlsx", "BufReadCmd *.xls", "BufReadCmd *.ods",
    -- Data preview
    "BufReadCmd *.db", "BufReadCmd *.sqlite", "BufReadCmd *.sqlite3",
  },
  dependencies = {
    "3rd/image.nvim", -- only needed for image preview (PDF / presentation)
  },
  opts = {},
}
```

#### Arch Linux

```sh
# Image preview dependencies
sudo pacman -S poppler imagemagick \
               libreoffice-fresh # Optional: for presentation preview

# Data preview dependencies
sudo pacman -S sqlite
```

#### Ubuntu / Debian

```sh
# Image preview dependencies
sudo apt install poppler-utils imagemagick \
                 libreoffice # Optional: for presentation preview

# Data preview dependencies
sudo apt install sqlite3
```

## Default Configuration

All fields are optional. These configure the rendering backends and keymaps.

```lua
require("buffer-preview").setup({
  -- "pdftoppm" (default) or "pdftocairo"
  rasterizer = "pdftoppm",
  -- Base rasterization DPI (higher = sharper but slower)
  dpi = 200,
  -- Where rendered page PNGs are cached
  cache_dir = vim.fn.stdpath("cache") .. "/buffer-preview.nvim",
  -- Prune cache entries older than this many days (false = keep forever)
  cache_max_age_days = 30,
  -- Delete least recently used entries once the cache grows past this (false = no cap)
  max_cache_size_mb = 500,
  -- Rasterize the next page in the background
  prefetch = true,
  -- Multiplier applied by `+` / `-` (re-rasterizes at dpi * zoom)
  zoom_step = 1.25,
  -- Rows rendered in the SQLite result buffer before truncating
  sqlite_max_rows = 1000,
  -- Buffer-local keymap overrides; `keymaps = false` disables them all
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
})
```

Rendering is asynchronous (conversion, `pdfinfo` and rasterization all run in
the background), so the editor never blocks on large documents. Cached pages
are keyed by path + rasterizer + effective `dpi` and invalidated when the source
changes; `:BufferPreviewCleanCache` wipes the cache directory and
`:checkhealth buffer-preview` reports missing dependencies and the cache size.

## Features

- [x] buffer-hijacking: supported buffers are hijacked and rendered as previews instead of raw bytes
- [x] page-viewer: read-only buffer with Vim-style page movement
- [x] PDF support (.pdf)
- [x] PowerPoint support (.pptx, .ppt)
- [x] OpenDocument Presentation support (.odp)
- [x] Word support (.docx, .doc, .odt, .rtf)
- [x] Spreadsheet support (.xlsx, .xls, .ods)
- [x] page text panel: searchable text of the current page (`t`, `y`)
- [x] zoom (`+` / `-`) and next-page prefetching
- [x] SQLite support (.db, .sqlite, .sqlite3) with CSV export
- [ ] Parquet support

## Usage

### PDF / Office document

| Key                                                          | Action        |
| ------------------------------------------------------------ | ------------- |
| `j` `l` `↓` `]` `}` `Space` `Ctrl-d` `Ctrl-f` `ScrollDown`    | Next page     |
| `k` `h` `↑` `[` `{` `Ctrl-u` `Ctrl-b` `ScrollUp`              | Previous page |
| `g`                                                          | First page    |
| `G`                                                          | Last page     |
| `<number>G`                                                  | Go to page N  |
| `+` / `-`                                                    | Zoom in / out |
| `=`                                                          | Reset zoom    |
| `t`                                                          | Toggle page text panel |
| `y`                                                          | Yank page text |
| `r` `Ctrl-l`                                                 | Refresh       |
| `q`                                                          | Close viewer  |

All of these can be remapped through `keymaps`; `keymaps = false` leaves the
buffer without any buffer-local mapping.

`:BufferPreviewText` opens the text panel of the current page in a side split.
It follows page changes, so `/`-search, `grep` and registers work on the real
text layer instead of pixels. `:BufferPreviewYankText` copies it.

### SQLite

Opening a `.db` / `.sqlite` / `.sqlite3` file spawns a two-buffer workspace:

- **Top** — read-only result preview. Initially shows the database schema
  (tables, views, triggers).
- **Bottom** — editable SQL buffer. Write any SQL that `sqlite3` accepts,
  including writes and DDL.

| Key / Command                | Action                                    |
| ---------------------------- | ----------------------------------------- |
| `:w` (save the buffer)<br>`:BufferPreviewRunQuery` | Run the whole bottom buffer as SQL |
| `:BufferPreviewExport <file>` | Write the full result of the last query to a CSV file |

The bottom buffer's contents are preserved after a run. Successful write
statements render `Query executed successfully` in the top buffer; errors
render `-- Error` followed by the `sqlite3` stderr. Results longer than
`sqlite_max_rows` are truncated with a note; export the full result with
`:BufferPreviewExport`.

## How It Works

1. `BufReadCmd` hijacks supported files before Neovim reads their raw bytes.
2. The plugin replaces the file buffer with a read-only scratch buffer.
3. A format-specific backend generates preview data for that buffer.
4. The preview is rendered in-place while normal Neovim navigation remains in
   control.

For PDFs, the backend:

1. Detects page count with `pdfinfo`
2. Rasterizes pages to PNG with `pdftoppm` or `pdftocairo`
3. Displays the page with `image.nvim`
4. Uses page-navigation mappings instead of normal text editing

For office documents (`.pptx`, `.docx`, `.xlsx`, ...), the backend:

1. Converts the document to PDF with `soffice --headless` (cancellable, cached)
2. Reuses the same PDF page-count, rasterization, and display pipeline
3. Keeps the same in-buffer navigation and `Page` layout

For SQLite files (`.db`, `.sqlite`, `.sqlite3`), the backend:

1. Opens a two-buffer workspace: a read-only result buffer on top and an
   editable SQL buffer on the bottom
2. Runs an initial schema query against `sqlite_master` to orient the user
3. Pipes the bottom buffer's contents into the `sqlite3` CLI via stdin and
   renders the result (table / success message / error) into the top buffer

## Architecture

- `plugin/buffer-preview.lua`: dispatches buffer hijacking per backend
- `lua/buffer-preview/image/viewer.lua`: PDF / office document preview buffer lifecycle
- `lua/buffer-preview/image/converter.lua`: converts office documents to cached PDF with `soffice`
- `lua/buffer-preview/image/rasterizer.lua`: PDF page rasterization, text extraction and cache
- `lua/buffer-preview/image/textview.lua`: page text side panel
- `lua/buffer-preview/image/display.lua`: image rendering via `image.nvim`
- `lua/buffer-preview/data/runner.lua`: `sqlite3` CLI wrapper (data backends)
- `lua/buffer-preview/data/viewer.lua`: two-buffer data workspace
- `lua/buffer-preview/health.lua`: `:checkhealth buffer-preview`
- `lua/buffer-preview/config.lua`: backend configuration

## Star History

<p align="center">
  <a href="https://www.star-history.com/?repos=huayue5201%2Fbuffer-preview.nvim&type=date&legend=top-left">
   <picture>
     <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=huayue5201/buffer-preview.nvim&type=Date&theme=dark&legend=top-left" />
     <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=huayue5201/buffer-preview.nvim&type=Date&legend=top-left" />
     <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=huayue5201/buffer-preview.nvim&type=date&legend=top-left" width="600"/>
   </picture>
  </a>
</p>
