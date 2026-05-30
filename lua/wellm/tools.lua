-- wellm/tools.lua
-- Tool definitions and execution for function calling
local M = {}

local context   = require("wellm.context")
local editor    = require("wellm.editor")
local wellagent = require("wellm.wellagent")
local state     = require("wellm.state")

-- Return tool definitions for the API (Anthropic/OpenAI format)
function M.get_tool_definitions()
  return {
    {
      name = "read_file",
      description = "Read the complete content of a file. Use this when you need to see a file's content before editing.",
      input_schema = {
        type = "object",
        properties = {
          path = { type = "string", description = "Relative path from the project root" }
        },
        required = { "path" }
      }
    },
    {
      name = "edit_file",
      description = "Replace the first occurrence of `search` with `replace` in a file. Use exact string matching. To delete, set `replace` to an empty string.",
      input_schema = {
        type = "object",
        properties = {
          path = { type = "string", description = "Relative path from the project root" },
          search = { type = "string", description = "Exact block of code to replace" },
          replace = { type = "string", description = "New code block (empty to delete)" }
        },
        required = { "path", "search", "replace" }
      }
    },
    {
      name = "edit_file_multiple",
      description = "Apply multiple search/replace edits to one or more files. Edits are applied in the order given.",
      input_schema = {
        type = "object",
        properties = {
          edits = {
            type = "array",
            items = {
              type = "object",
              properties = {
                path = { type = "string" },
                search = { type = "string" },
                replace = { type = "string" }
              },
              required = { "path", "search", "replace" }
            }
          }
        },
        required = { "edits" }
      }
    }
  }
end

-- Execute a tool call and return the result as a string (for tool_result content)
-- @param tool_name string
-- @param params table (tool input)
-- @param confirm_callback function(msg) -> boolean, optional (called before destructive actions)
function M.execute(tool_name, params, confirm_callback)
  if tool_name == "read_file" then
    local path = params.path
    local proj = wellagent.get_project_root()
    local full = path:sub(1,1) == "/" and path or (proj .. "/" .. path)
    local f, err = io.open(full, "r")
    if not f then
      return "Error: cannot read file " .. path .. " - " .. (err or "file not found")
    end
    local content = f:read("*a")
    f:close()
    -- Optionally inject into context for future turns
    context.inject_raw(full, content)
    return content
  end

  if tool_name == "edit_file" then
    local path = params.path
    local search = params.search
    local replace = params.replace
    local proj = wellagent.get_project_root()

    if confirm_callback then
      local msg = string.format("Apply edit to %s?\nSearch:\n%s\nReplace:\n%s", path, search, replace)
      if not confirm_callback(msg) then
        return "Edit cancelled by user."
      end
    end

    -- Use the existing editor.apply_edits_to_file with a single edit
    local edits = { { path = path, search = search, replace = replace } }
    local ok, err = editor.apply_edits_to_file(edits, proj)  -- we need to adapt this
    if not ok then
      return "Edit failed: " .. (err or "unknown error")
    end
    return "Edit applied successfully to " .. path
  end

  if tool_name == "edit_file_multiple" then
    local edits = params.edits
    local proj = wellagent.get_project_root()
    local results = {}
    for _, edit in ipairs(edits) do
      if confirm_callback then
        local msg = string.format("Apply edit to %s?\nSearch:\n%s", edit.path, edit.search)
        if not confirm_callback(msg) then
          table.insert(results, "Skipped: " .. edit.path)
          goto continue
        end
      end
      local ok, err = editor.apply_edits_to_file({ edit }, proj)
      table.insert(results, ok and ("Applied: " .. edit.path) or ("Failed: " .. edit.path .. " - " .. err))
      ::continue::
    end
    return table.concat(results, "\n")
  end

  return "Unknown tool: " .. tool_name
end

return M