-- wellm/fileops.lua — parse, confirm, and apply LLM-proposed file changes.
-- Only write/create operations are supported. Deletion is never allowed.
local M = {}

local function resolve_path(path)
  if path:sub(1, 1) == "/" or path:match("^[A-Za-z]:[/\\]") then
    return path
  end
  return vim.fn.getcwd() .. "/" .. path
end

-- Parse <wellm_file path="...">content</wellm_file> blocks from LLM output.
-- Lua's "." does not match newlines, so we walk line by line.
function M.parse(text)
  local changes = {}
  local lines   = vim.split(text, "\n")
  local i       = 1

  while i <= #lines do
    local path = lines[i]:match('<wellm_file%s+path="([^"]+)">')
    if path then
      local content_lines = {}
      i = i + 1
      while i <= #lines and not lines[i]:match("</wellm_file>") do
        content_lines[#content_lines + 1] = lines[i]
        i = i + 1
      end
      -- i now sits on the closing tag; outer i+1 steps past it
      changes[#changes + 1] = { path = path, content = table.concat(content_lines, "\n") }
    end
    i = i + 1
  end

  return changes
end

-- Write a single file (create or overwrite). Never deletes.
-- Returns: ok (bool), err (string|nil), is_new (bool)
function M.apply_change(change)
  local path = resolve_path(change.path)

  if path:find("%.%.") then
    return false, "path traversal not allowed: " .. change.path, false
  end

  local is_new = vim.fn.filereadable(path) ~= 1

  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" and dir ~= "." then
    vim.fn.mkdir(dir, "p")
  end

  local f, open_err = io.open(path, "w")
  if not f then
    return false, open_err or "could not open: " .. path, is_new
  end
  f:write(change.content)
  f:close()

  return true, nil, is_new
end

-- Apply all changes; reload any open Neovim buffers afterwards.
function M.apply_changes(changes)
  local results = {}
  for _, change in ipairs(changes) do
    local ok, err, is_new = M.apply_change(change)
    results[#results + 1] = { path = change.path, ok = ok, err = err, is_new = is_new }
  end
  vim.cmd.checktime()
  return results
end

-- Show a blocking confirm dialog (must be called from a vim.schedule context).
-- callback receives true (apply) or false (cancel).
function M.confirm(changes, callback)
  local msg = "Wellm: LLM proposes file changes:\n\n"
  for i, change in ipairs(changes) do
    local abs   = resolve_path(change.path)
    local act   = vim.fn.filereadable(abs) == 1 and "MODIFY" or "CREATE"
    local nline = #vim.split(change.content, "\n")
    msg = msg .. string.format("  %d. [%s] %s (%d lines)\n", i, act, change.path, nline)
  end
  msg = msg .. "\nApply these changes?"

  vim.schedule(function()
    local choice = vim.fn.confirm(msg, "&Yes\n&No", 2, "Question")
    callback(choice == 1)
  end)
end

-- Format a human-readable summary of apply results.
function M.summarize(results)
  local lines = { "", "File changes:" }
  for _, r in ipairs(results) do
    if r.ok then
      local act = r.is_new and "Created" or "Modified"
      lines[#lines + 1] = string.format("  [ok] %s: %s", act, r.path)
    else
      lines[#lines + 1] = string.format("  [!!] Failed: %s (%s)", r.path, tostring(r.err))
    end
  end
  return table.concat(lines, "\n")
end

return M