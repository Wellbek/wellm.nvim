-- wellm/context.lua
-- Manages M.state.data.context_files: add, remove, clear.
local M = {}

local state = require("wellm.state")

local SKIP_PATTERNS = {
  "%.lock$", "%.min%.js$", "%.map$", "%.png$", "%.jpg$", "%.jpeg$",
  "%.gif$", "%.svg$", "%.ico$", "%.woff", "%.ttf$", "%.eot$",
  "%.zip$", "%.tar", "%.gz$",
}

local function should_skip(name)
  if name:match("^%.") then return true end
  for _, pat in ipairs(SKIP_PATTERNS) do
    if name:match(pat) then return true end
  end
  return false
end

--- Add a single file to context. Returns true on success.
function M.add_file(path)
  path = path or vim.fn.expand("%:p")
  if not path or path == "" or vim.fn.filereadable(path) == 0 then
    vim.notify("[Wellm] Cannot read: " .. tostring(path), vim.log.levels.WARN)
    return false
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    vim.notify("[Wellm] Failed to read: " .. path, vim.log.levels.WARN)
    return false
  end
  state.data.context_files[path] = table.concat(lines, "\n")
  vim.notify("[Wellm] Added to context: " .. vim.fn.fnamemodify(path, ":~:."))
  return true
end

--- Remove a file from context.
function M.remove_file(path)
  state.data.context_files[path] = nil
  vim.notify("[Wellm] Removed: " .. vim.fn.fnamemodify(path, ":~:."))
end

--- Add all non-skipped files from a directory (non-recursive by default).
function M.add_folder(path, recursive)
  path = path or vim.fn.input("Folder: ", vim.fn.expand("%:p:h"), "dir")
  if not path or path == "" then return end

  local count = 0
  local handle = vim.loop.fs_scandir(path)
  if not handle then
    vim.notify("[Wellm] Cannot scan: " .. path, vim.log.levels.WARN)
    return
  end

  while true do
    local name, ftype = vim.loop.fs_scandir_next(handle)
    if not name then break end
    local full = path .. "/" .. name
    if ftype == "file" and not should_skip(name) then
      if M.add_file(full) then count = count + 1 end
    elseif ftype == "directory" and recursive and not should_skip(name) then
      M.add_folder(full, true)
    end
  end
  vim.notify(string.format("[Wellm] Added %d file(s) from %s", count, vim.fn.fnamemodify(path, ":~:.")))
end

--- Clear all context files.
function M.clear()
  state.data.context_files = {}
  vim.notify("[Wellm] Context cleared.")
end

--- Build a context block string for injection into prompts.
function M.build_block()
  local parts = {}
  for path, content in pairs(state.data.context_files) do
    local rel = vim.fn.fnamemodify(path, ":~:.")
    table.insert(parts, string.format("### File: %s\n```\n%s\n```", rel, content))
  end
  if #parts == 0 then return nil end
  return "## Selected Context Files\n\n" .. table.concat(parts, "\n\n")
end

--- Return a list of currently loaded paths.
function M.list()
  return vim.tbl_keys(state.data.context_files)
end

--- Inject a file content string directly (used by auto-read loop).
function M.inject_raw(path, content)
  state.data.context_files[path] = content
end

return M
