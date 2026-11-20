--- sqlite3 CLI wrapper for buffer-preview.nvim.
--- Feeds SQL via stdin and returns structured output/error.
local M = {}

local SQLITE3_BIN = "sqlite3"

---@return boolean
function M.is_available()
  return vim.fn.executable(SQLITE3_BIN) == 1
end

---@param s string|nil
---@return string[]
local function to_lines(s)
  if not s or s == "" then
    return {}
  end
  local lines = vim.split(s, "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

---@param result? vim.SystemCompleted
---@return { ok: boolean, output: string[], err: string|nil }
local function parse(result)
  if not result then
    return { ok = false, output = {}, err = "sqlite3 produced no result" }
  end

  if result.code == 0 then
    return { ok = true, output = to_lines(result.stdout), err = nil }
  end

  local err = result.stderr
  if not err or err == "" then
    err = result.stdout or "unknown error"
  end
  return { ok = false, output = {}, err = err }
end

--- Run arbitrary SQL against a SQLite database.
---
--- With a callback the query runs asynchronously (the editor keeps
--- responding while a slow query executes); without one it blocks and
--- returns the result, which is what tests and programmatic callers expect.
---
---@param db_path string Absolute path to the SQLite file
---@param sql string SQL source (may contain multiple statements)
---@param callback? fun(result: { ok: boolean, output: string[], err: string|nil })
---@return { ok: boolean, output: string[], err: string|nil }|nil result only when no callback is given
function M.run(db_path, sql, callback)
  local cmd = { SQLITE3_BIN, "-header", "-column", "-bail", db_path }

  if callback then
    vim.system(cmd, { stdin = sql, text = true }, function(result)
      vim.schedule(function()
        callback(parse(result))
      end)
    end)
    return nil
  end

  return parse(vim.system(cmd, { stdin = sql, text = true }):wait())
end

--- Run SQL and write the result to `out_path` as CSV (asynchronous).
---@param db_path string
---@param sql string
---@param out_path string
---@param callback fun(ok: boolean, err: string|nil)
function M.export(db_path, sql, out_path, callback)
  local cmd = { SQLITE3_BIN, "-header", "-csv", "-bail", db_path }
  vim.system(cmd, { stdin = sql, text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(false, (result.stderr ~= "" and result.stderr) or "sqlite3 exited with an error")
        return
      end
      local lines = vim.split(result.stdout or "", "\n", { plain = true })
      if lines[#lines] == "" then
        lines[#lines] = nil
      end
      local ok, err = pcall(vim.fn.writefile, lines, out_path)
      if not ok then
        callback(false, tostring(err))
        return
      end
      callback(true, nil)
    end)
  end)
end

return M
