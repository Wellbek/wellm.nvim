-- wellm/tools.lua
-- Tool definitions and execution for function calling
local M = {}

local context   = require("wellm.context")
local editor    = require("wellm.editor")
local wellagent = require("wellm.wellagent")
local state     = require("wellm.state")

-- Return tool definitions in the format expected by the given provider
-- provider: "anthropic" or "zhipu" (or "openai")
function M.get_tool_definitions(provider)
  -- Common parameters for the tools (OpenAI style)
  local read_file_params = {
    type = "object",
    properties = {
      path = { type = "string", description = "Relative path from the project root" }
    },
    required = { "path" }
  }
  local edit_file_params = {
    type = "object",
    properties = {
      path = { type = "string", description = "Relative path from the project root" },
      search = { type = "string", description = "Exact block of code to replace" },
      replace = { type = "string", description = "New code block (empty to delete)" }
    },
    required = { "path", "search", "replace" }
  }
  local edit_multiple_params = {
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

  if provider == "anthropic" then
    -- Anthropic format (Claude)
    return {
      {
        name = "read_file",
        description = "Read the complete content of a file. Use this when you need to see a file's content before editing.",
        input_schema = read_file_params
      },
      {
        name = "edit_file",
        description = "Replace the first occurrence of `search` with `replace` in a file. Use exact string matching. To delete, set `replace` to an empty string.",
        input_schema = edit_file_params
      },
      {
        name = "edit_file_multiple",
        description = "Apply multiple search/replace edits to one or more files. Edits are applied in the order given.",
        input_schema = edit_multiple_params
      }
    }
  else
    -- OpenAI‑compatible format (Zhipu, OpenAI, etc.)
    return {
      {
        type = "function",
        ["function"] = {
          name = "read_file",
          description = "Read the complete content of a file. Use this when you need to see a file's content before editing.",
          parameters = read_file_params
        }
      },
      {
        type = "function",
        ["function"] = {
          name = "edit_file",
          description = "Replace the first occurrence of `search` with `replace` in a file. Use exact string matching. To delete, set `replace` to an empty string.",
          parameters = edit_file_params
        }
      },
      {
        type = "function",
        ["function"] = {
          name = "edit_file_multiple",
          description = "Apply multiple search/replace edits to one or more files. Edits are applied in the order given.",
          parameters = edit_multiple_params
        }
      }
    }
  end
end

-- Execute a tool call (same for all providers)
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

    local edits = { { path = path, search = search, replace = replace } }
    local ok, err = editor.apply_edits_to_file(edits, proj)
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
      local should_apply = true
      if confirm_callback then
        local msg = string.format("Apply edit to %s?\nSearch:\n%s", edit.path, edit.search)
        if not confirm_callback(msg) then
          table.insert(results, "Skipped: " .. edit.path)
          should_apply = false
        end
      end
      if should_apply then
        local ok, err = editor.apply_edits_to_file({ edit }, proj)
        table.insert(results, ok and ("Applied: " .. edit.path) or ("Failed: " .. edit.path .. " - " .. err))
      end
    end
    return table.concat(results, "\n")
  end

  return "Unknown tool: " .. tool_name
end

return M