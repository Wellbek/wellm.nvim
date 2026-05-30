--- editor.lua - Semantic file editing via search/replace blocks
---
--- Format:
---   <wellm_edit path="relative/path">
---   <search>
---   exact existing code block (optional)
---   </search>
---   <replace>
---   new code block (optional)
---   </replace>
---   </wellm_edit>
---
--- Rules:
---   - If <search> is empty/missing, <replace> is prepended at the top.
---   - If <replace> is empty/missing, the <search> block is deleted.
---   - Otherwise, replace the first occurrence of <search> with <replace>.
---   - Multiple edits are applied in the order they appear.
---   - Edits for the same file are applied sequentially (each sees the result of previous edits).

local M = {}
local state = require("wellm.state")

--------------------------------------------------------------------------------
-- Parsing
--------------------------------------------------------------------------------

--- Parse all <wellm_edit> blocks from AI response text.
--- Returns a list of { path, search, replace }
function M.parse_edits(text)
  local edits = {}
  local pos = 1

  while true do
    local tag_start = text:find("<wellm_edit ", pos, true)
    if not tag_start then break end

    local tag_end = text:find(">", tag_start, true)
    if not tag_end then break end

    -- Extract path attribute
    local path = text:sub(tag_start, tag_end):match('path="([^"]*)"')
    if not path then
      pos = tag_end + 1
      goto continue
    end

    local content_start = tag_end + 1
    local close_pos = text:find("</wellm_edit>", content_start, true)
    if not close_pos then break end

    local block = text:sub(content_start, close_pos - 1)

    -- Extract <search> and <replace> tags
    local search = block:match("<search>(.-)</search>")
    local replace = block:match("<replace>(.-)</replace>")

    -- Clean up leading/trailing newlines (one each, as in old editor)
    if search then
      if search:sub(1,1) == "\n" then search = search:sub(2) end
      if search:sub(-1) == "\n" then search = search:sub(1,-2) end
    end
    if replace then
      if replace:sub(1,1) == "\n" then replace = replace:sub(2) end
      if replace:sub(-1) == "\n" then replace = replace:sub(1,-2) end
    end

    table.insert(edits, {
      path = path,
      search = search or "",
      replace = replace or "",
    })

    pos = close_pos + #"</wellm_edit>"

    ::continue::
  end

  return edits
end

--------------------------------------------------------------------------------
-- Apply a single search/replace to file content (string)
--------------------------------------------------------------------------------

--- Apply one edit to the given file content string.
--- Returns new content (string) or nil + error.
---@param content string Current file content
---@param edit table { search, replace }
---@return string|nil new_content
---@return string|nil error
local function apply_search_replace(content, edit)
  local search = edit.search
  local replace = edit.replace

  -- Normalize line endings (remove \r)
  content = content:gsub("\r\n", "\n")
  search = search:gsub("\r\n", "\n")
  replace = replace:gsub("\r\n", "\n")

  -- Case 1: No search → prepend replace
  if search == "" then
    if replace == "" then return content end
    return replace .. (content ~= "" and "\n" .. content or "")
  end

  -- Case 2: No replace → delete search (first occurrence)
  if replace == "" then
    local pos = content:find(search, 1, true)
    if not pos then
      -- Try stripping one trailing newline from search
      local alt_search = search:gsub("\n$", "")
      if alt_search ~= search then
        pos = content:find(alt_search, 1, true)
      end
    end
    if not pos then
      return nil, "Search block not found"
    end
    return content:sub(1, pos - 1) .. content:sub(pos + #search)
  end

  -- Case 3: Replace first occurrence
  local pos = content:find(search, 1, true)
  if not pos then
    -- Try stripping trailing newline
    local alt_search = search:gsub("\n$", "")
    if alt_search ~= search then
      pos = content:find(alt_search, 1, true)
    end
  end
  if not pos then
    return nil, "Search block not found"
  end
  return content:sub(1, pos - 1) .. replace .. content:sub(pos + #search)
end

--------------------------------------------------------------------------------
-- Apply all edits for a single file
--------------------------------------------------------------------------------

--- Read file, apply all edits (in order), write back.
---@param path string Relative path
---@param edits table List of edits (already filtered for this path)
---@param project_root string
---@return boolean ok, string|nil error
function M.apply_edits_to_file(path, edits, project_root)
  local full_path = project_root .. "/" .. path
  local file_exists = vim.fn.filereadable(full_path) == 1

  -- Read current content (empty string for new file)
  local content = ""
  if file_exists then
    local lines = vim.fn.readfile(full_path)
    content = table.concat(lines, "\n")
  end

  -- Apply edits sequentially (in the order they appear in the AI response)
  for _, edit in ipairs(edits) do
    local new_content, err = apply_search_replace(content, edit)
    if not new_content then
      return false, string.format("Edit failed: %s", err)
    end
    content = new_content
  end

  -- Ensure parent directory exists
  local dir = vim.fs.dirname(full_path)
  if dir and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end

  -- Write final content (split into lines)
  local lines = vim.split(content, "\n", { plain = true })
  if vim.fn.writefile(lines, full_path) ~= 0 then
    return false, "Failed to write " .. path
  end

  -- Mark cache dirty
  if state.current_session then
    state.current_session:mark_file_dirty(full_path)
  end

  return true, nil
end

--------------------------------------------------------------------------------
-- Public API (compatible with existing callers)
--------------------------------------------------------------------------------

--- Main entry point: parse edits from AI response, group by file,
--- apply edits for each file sequentially.
function M.process_response(text, project_root)
  local edits = M.parse_edits(text)
  if #edits == 0 then
    return {}
  end

  -- Group by path while preserving order of first occurrence
  local grouped = {}
  local order = {}
  for _, edit in ipairs(edits) do
    if not grouped[edit.path] then
      grouped[edit.path] = {}
      table.insert(order, edit.path)
    end
    table.insert(grouped[edit.path], edit)
  end

  local results = {}
  for _, path in ipairs(order) do
    local ok, err = M.apply_edits_to_file(path, grouped[path], project_root)
    if not ok then
      vim.notify(string.format("[Wellm] Edit failed for %s: %s", path, err), vim.log.levels.ERROR)
    else
      -- Reload buffer if open
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

--- Format results for display
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

-- Deprecated compatibility stub
function M.validate_edits(path, file_edits, project_root)
  return true, nil, file_edits
end

return M