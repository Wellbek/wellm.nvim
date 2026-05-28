--- editor.lua - Partial file editing via <wellm_edit> blocks
---
--- Instead of rewriting entire files, the AI specifies line ranges
--- to replace, and this module splices the new content into place.
---
--- Format in AI response:
---   <wellm_edit path="rel/path" start="10" end="15">
---   replacement content for lines 10-15
---   </wellm_edit>
---
--- Multiple <wellm_edit> blocks can appear in a single response.
--- Edits for the same file are applied bottom-to-top so line
--- numbers remain valid. Overlapping edits for the same file
--- are rejected.
---
--- Insertions: set start = end + 1 (e.g. start="11" end="10")
---   means "insert after line 10, before line 11" without deleting.
--- Deletions: normal range with empty content.
--- New files: start="1" end="0" with full file content.

local M = {}

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
-- Grouping & validation
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

--- Validate a set of edits for a single file.
--- Checks: no overlaps, valid line ranges.
--- Sorts edits by start_line descending (bottom-to-top application order).
---@param path string File path relative to project root
---@param file_edits table List of edits for this file
---@param project_root string Project root directory
---@return boolean ok
---@return string|nil error_message
---@return table|nil sorted_edits
function M.validate_edits(path, file_edits, project_root)
  local full_path = project_root .. "/" .. path
  local file_exists = vim.fn.filereadable(full_path) == 1

  -- Sort descending by start_line for bottom-to-top application
  local sorted = {}
  for _, e in ipairs(file_edits) do
    table.insert(sorted, {
      path = e.path,
      start_line = e.start_line,
      end_line = e.end_line,
      content = e.content,
    })
  end
  table.sort(sorted, function(a, b)
    return a.start_line > b.start_line
  end)

  -- Check for overlaps
  for i = 1, #sorted - 1 do
    local upper = sorted[i]
    local lower = sorted[i + 1]
    if upper.start_line <= lower.end_line then
      return false,
        string.format("Overlapping edits on %s: lines %d-%d and %d-%d",
          path, lower.start_line, lower.end_line, upper.start_line, upper.end_line),
        nil
    end
  end

  -- Validate line ranges against file
  if file_exists then
    local line_count = #vim.fn.readfile(full_path)
    for _, edit in ipairs(sorted) do
      local is_insertion = edit.start_line == edit.end_line + 1
      if not is_insertion then
        if edit.start_line < 1 then
          return false, string.format("Invalid start_line %d in %s", edit.start_line, path), nil
        end
        if edit.end_line > line_count then
          return false,
            string.format("end_line %d exceeds file length %d in %s", edit.end_line, line_count, path),
            nil
        end
        if edit.start_line > edit.end_line then
          return false,
            string.format("start_line %d > end_line %d in %s (did you mean insertion?)",
              edit.start_line, edit.end_line, path),
            nil
        end
      else
        if edit.end_line < 0 or edit.end_line > line_count then
          return false,
            string.format("Insertion point %d out of range (0-%d) in %s",
              edit.end_line, line_count, path),
            nil
        end
      end
    end
  else
    -- New file: only allow a single edit starting at line 1
    if #sorted ~= 1 then
      return false, string.format("New file %s must have exactly one edit block", path), nil
    end
    local edit = sorted[1]
    if edit.start_line ~= 1 or edit.end_line ~= 0 then
      return false,
        string.format("New file %s edit must start at line 1 (got start=%d end=%d)",
          path, edit.start_line, edit.end_line),
        nil
    end
  end

  return true, nil, sorted
end

--------------------------------------------------------------------------------
-- Apply edits
--------------------------------------------------------------------------------

--- Split content string into lines (without trailing newlines).
---@param content string
---@return table lines
local function content_to_lines(content)
  if content == "" then return {} end
  local lines = {}
  for line in content:gmatch("([^\n]*)\n?") do
    table.insert(lines, line)
  end
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

--- Apply a list of validated, sorted edits to a single file.
--- Edits MUST be sorted bottom-to-top (descending start_line).
---@param path string Relative file path
---@param sorted_edits table Validated edits sorted descending
---@param project_root string
---@return boolean ok
---@return string|nil error_message
function M.apply_edits_to_file(path, sorted_edits, project_root)
  local full_path = project_root .. "/" .. path
  local file_exists = vim.fn.filereadable(full_path) == 1

  local existing_lines
  if file_exists then
    existing_lines = vim.fn.readfile(full_path)
  else
    existing_lines = {}
  end

  -- Apply edits bottom-to-top
  for _, edit in ipairs(sorted_edits) do
    local new_lines = content_to_lines(edit.content)
    local is_insertion = edit.start_line == edit.end_line + 1

    if is_insertion then
      local before = vim.list_slice(existing_lines, 1, edit.end_line)
      local after  = vim.list_slice(existing_lines, edit.end_line + 1)
      existing_lines = {}
      for _, l in ipairs(before) do table.insert(existing_lines, l) end
      for _, l in ipairs(new_lines) do table.insert(existing_lines, l) end
      for _, l in ipairs(after) do table.insert(existing_lines, l) end
    else
      local before = vim.list_slice(existing_lines, 1, edit.start_line - 1)
      local after  = vim.list_slice(existing_lines, edit.end_line + 1)
      existing_lines = {}
      for _, l in ipairs(before) do table.insert(existing_lines, l) end
      for _, l in ipairs(new_lines) do table.insert(existing_lines, l) end
      for _, l in ipairs(after) do table.insert(existing_lines, l) end
    end
  end

  -- Ensure parent directory exists
  local dir = vim.fs.dirname(full_path)
  if dir and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end

  -- Write the file
  local ok = vim.fn.writefile(existing_lines, full_path)
  if ok ~= 0 then
    return false, string.format("Failed to write %s", path)
  end

  return true, nil
end

--- Main entry point: parse edits from AI response, validate, and apply them.
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
    local file_edits = grouped[path]
    local ok, err, sorted = M.validate_edits(path, file_edits, project_root)

    if not ok then
      table.insert(results, { path = path, ok = false, error = err })
    else
      local apply_ok, apply_err = M.apply_edits_to_file(path, sorted, project_root)
      table.insert(results, {
        path  = path,
        ok    = apply_ok,
        error = apply_err,
      })

      -- Reload if file is open in a buffer
      if apply_ok then
        local full_path = project_root .. "/" .. path
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_get_name(buf) == full_path then
            vim.api.nvim_buf_call(buf, function()
              vim.cmd("checktime")
            end)
          end
        end
      end
    end
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

return M