--- editor.lua - Partial file editing via <wellm_edit> blocks
---
--- Instead of rewriting entire files, the AI specifies line ranges
--- to replace, and this module splices the new content into place.
---
--- Edits are applied sequentially (bottom-to-top) so each edit sees
--- the file state after all previous (higher-line) edits have been applied.
---
--- Special rules:
---   - For a new file: use start="1" end="0" (full content).
---   - To prepend to an existing file: also use start="1" end="0" – this inserts
---     the new content before the first line (does NOT replace the whole file).
---   - To insert after line N: use start="N+1" end="N".
---   - To replace a range: use start="A" end="B" (1‑based inclusive).
---   - To append after the last line: use start="L+1" end="L" where L is current line count.
---
--- Multiple <wellm_edit> blocks can appear in a single response.
--- They are grouped by file and then applied in descending start_line order
--- (bottom-to-top) to keep line numbers valid.

local M = {}
local state = require("wellm.state")

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

--- Parse all <wellm_edit> blocks from AI response text.
---@param text string Full AI response text
---@return table edits List of { path, start_line, end_line, content }
function M.parse_edits(text)
  local edits = {}
  local pos = 1

  while true do
    local tag_start = text:find("<wellm_edit ", pos, true)
    if not tag_start then break end

    local tag_end = text:find(">", tag_start, true)
    if not tag_end then break end

    local tag = text:sub(tag_start, tag_end)

    local path       = tag:match('path="([^"]*)"')
    local start_line = tonumber(tag:match('start="(%d+)"'))
    local end_line   = tonumber(tag:match('end="(%d+)"'))

    if not path or not start_line or not end_line then
      pos = tag_end + 1
      goto continue
    end

    local content_start = tag_end + 1
    local close_pos = text:find("</wellm_edit>", content_start, true)
    if not close_pos then break end

    local content = text:sub(content_start, close_pos - 1)

    -- Strip exactly one leading newline
    if content:sub(1, 1) == "\n" then
      content = content:sub(2)
    end
    -- Strip exactly one trailing newline
    if content:len() > 0 and content:sub(-1) == "\n" then
      content = content:sub(1, -2)
    end

    table.insert(edits, {
      path       = path,
      start_line = start_line,
      end_line   = end_line,
      content    = content,
    })

    pos = close_pos + #"</wellm_edit>"

    ::continue::
  end

  return edits
end

--------------------------------------------------------------------------------
-- Grouping
--------------------------------------------------------------------------------

--- Group edits by file path, preserving order within each group.
---@param edits table List of edits from parse_edits
---@return table grouped Mapping: path -> list of edits
---@return table order Ordered list of unique paths
function M.group_edits_by_path(edits)
  local grouped = {}
  local order   = {}

  for _, edit in ipairs(edits) do
    if not grouped[edit.path] then
      grouped[edit.path] = {}
      table.insert(order, edit.path)
    end
    table.insert(grouped[edit.path], edit)
  end

  return grouped, order
end

--------------------------------------------------------------------------------
-- Sequential edit application
--------------------------------------------------------------------------------

--- Split edit content string into a lines table.
---@param content string
---@return table lines
local function content_to_lines(content)
  if content == "" then return {} end
  return vim.split(content, "\n", { plain = true })
end

--- Apply a single edit to a given set of lines (the current file state).
--- Returns new_lines (table) or nil + error message.
---
--- Edit semantics (all line numbers are 1‑based inclusive):
---   - New file creation:          start=1, end=0   (only valid if #existing_lines == 0)
---   - Replace entire file:        start=1, end=-1  (always replaces, even if file exists)
---   - Prepend (insert at top):    start=0, end=0   (inserts content before first line)
---   - Insert after line N:        start=N+1, end=N
---   - Replace range A-B:          start=A, end=B   (A ≤ B, both within existing lines)
---   - Delete range A-B:           same as replace with empty content
---   - Append:                      start=L+1, end=L where L = #existing_lines (insert after last)
---
---@param existing_lines table Current lines of the file (1‑based list)
---@param edit table { start_line, end_line, content }
---@return table|nil new_lines
---@return string|nil error
local function apply_single_edit(existing_lines, edit)
  local new_lines = content_to_lines(edit.content)
  local start = edit.start_line
  local finish = edit.end_line

  -- 1) New file creation (only allowed when file is empty)
  if start == 1 and finish == 0 then
    if #existing_lines == 0 then
      return new_lines
    else
      return nil, "Cannot create new file: file already exists (use start=1 end=-1 to replace)"
    end
  end

  -- 2) Replace entire file (regardless of existing content)
  if start == 1 and finish == -1 then
    return new_lines
  end

  -- 3) Prepend (insert at top, keep existing lines)
  if start == 0 and finish == 0 then
    local result = {}
    for _, l in ipairs(new_lines) do table.insert(result, l) end
    for _, l in ipairs(existing_lines) do table.insert(result, l) end
    return result
  end

  -- 4) Insertion: start = finish + 1
  if start == finish + 1 then
    if finish < 0 or finish > #existing_lines then
      return nil, string.format("Insertion point %d out of range (0-%d)", finish, #existing_lines)
    end
    local before = vim.list_slice(existing_lines, 1, finish)
    local after  = vim.list_slice(existing_lines, finish + 1)
    local result = {}
    for _, l in ipairs(before) do table.insert(result, l) end
    for _, l in ipairs(new_lines) do table.insert(result, l) end
    for _, l in ipairs(after) do table.insert(result, l) end
    return result
  end

  -- 5) Replacement (or deletion) of a range
  if start < 1 then
    return nil, string.format("Invalid start_line %d (must be ≥1 for replacement)", start)
  end
  if start > #existing_lines then
    return nil, string.format("start_line %d exceeds file length %d", start, #existing_lines)
  end
  if finish < start then
    return nil, string.format("end_line %d < start_line %d", finish, start)
  end
  if finish > #existing_lines then
    return nil, string.format("end_line %d exceeds file length %d", finish, #existing_lines)
  end

  local before = vim.list_slice(existing_lines, 1, start - 1)
  local after  = vim.list_slice(existing_lines, finish + 1)
  local result = {}
  for _, l in ipairs(before) do table.insert(result, l) end
  for _, l in ipairs(new_lines) do table.insert(result, l) end
  for _, l in ipairs(after) do table.insert(result, l) end
  return result
end

--- Apply a list of edits to a single file, applying them sequentially.
--- Edits must be sorted descending by start_line (bottom‑to‑top) so that
--- earlier (lower) edits see the file state after higher‑line edits.
--- The function reads the current file, applies each edit in order,
--- and writes the final result.
---@param path string Relative file path
---@param sorted_edits table List of edits sorted descending by start_line
---@param project_root string Project root directory
---@return boolean ok
---@return string|nil error_message
function M.apply_edits_to_file(path, sorted_edits, project_root)
  local full_path = project_root .. "/" .. path
  local file_exists = vim.fn.filereadable(full_path) == 1

  -- Read current lines (empty table for new file)
  local lines = file_exists and vim.fn.readfile(full_path) or {}

  -- Apply edits sequentially
  for _, edit in ipairs(sorted_edits) do
    local new_lines, err = apply_single_edit(lines, edit)
    if not new_lines then
      return false, string.format("Edit [%d,%d] failed: %s", edit.start_line, edit.end_line, err)
    end
    lines = new_lines
  end

  -- Ensure parent directory exists
  local dir = vim.fs.dirname(full_path)
  if dir and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end

  -- Write final lines to disk
  if vim.fn.writefile(lines, full_path) ~= 0 then
    return false, "Failed to write " .. path
  end

  -- Mark cache as dirty so next context assembly re‑reads the file
  if state.current_session then
    state.current_session:mark_file_dirty(full_path)
  end

  return true, nil
end

--- Sort edits for a single file: descending by start_line (bottom‑to‑top).
---@param file_edits table List of edits for one file
---@return table sorted_edits
function M.sort_edits_descending(file_edits)
  local sorted = {}
  for _, e in ipairs(file_edits) do
    table.insert(sorted, {
      path       = e.path,
      start_line = e.start_line,
      end_line   = e.end_line,
      content    = e.content,
    })
  end
  table.sort(sorted, function(a, b)
    return a.start_line > b.start_line
  end)
  return sorted
end

--- Main entry point: parse edits from AI response, group by file,
--- sort each group bottom‑to‑top, and apply them sequentially.
---@param text string AI response text containing <wellm_edit> blocks
---@param project_root string Project root directory
---@return table results List of { path, ok, error }
function M.process_response(text, project_root)
  local edits = M.parse_edits(text)
  if #edits == 0 then
    return {}
  end

  local grouped, order = M.group_edits_by_path(edits)
  local results = {}

  for _, path in ipairs(order) do
    local sorted = M.sort_edits_descending(grouped[path])
    local ok, err = M.apply_edits_to_file(path, sorted, project_root)

    if not ok then
      vim.notify(string.format("[Wellm] Edit failed for %s: %s", path, err), vim.log.levels.ERROR)
    else
      -- Reload buffer if the file is open in Neovim
      local full_path = project_root .. "/" .. path
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == full_path then
          vim.api.nvim_buf_call(buf, function() vim.cmd("checktime") end)
          break
        end
      end
    end

    table.insert(results, { path = path, ok = ok, error = err })
  end

  return results
end

--- Format results into a human-readable summary.
---@param results table From process_response
---@return string summary
function M.format_results(results)
  if #results == 0 then
    return "No file edits found in response."
  end

  local lines = {}
  for _, r in ipairs(results) do
    if r.ok then
      table.insert(lines, string.format("  + %s", r.path))
    else
      table.insert(lines, string.format("  x %s: %s", r.path, r.error or "unknown error"))
    end
  end
  return table.concat(lines, "\n")
end

-- Compatibility stub for old validation API (now handled during sequential application)
---@param path string File path (unused, kept for signature)
---@param file_edits table List of edits for this file
---@param project_root string (unused)
---@return boolean ok
---@return nil
---@return table sorted_edits
function M.validate_edits(path, file_edits, project_root)
  local sorted = M.sort_edits_descending(file_edits)
  return true, nil, sorted
end

return M