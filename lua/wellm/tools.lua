-- wellm/tools.lua
-- Tool definitions and execution for function calling
local M = {}

local context   = require("wellm.context")
local editor    = require("wellm.editor")
local wellagent = require("wellm.wellagent")
local state     = require("wellm.state")
local hash_util = require("wellm.util.hash")

-- NEW: symbol extraction for outlines
local symbols = require("wellm.symbols")

-- Return tool definitions in the format expected by the given provider
-- provider: "anthropic" or "zhipu" (or "openai")
function M.get_tool_definitions(provider)
  -- Common parameters for the tools (OpenAI style)
  -- MODIFIED: read_file now includes optional "outline" parameter
  local read_file_params = {
    type = "object",
    properties = {
      path = { type = "string", description = "Relative path from the project root" },
      outline = { type = "boolean", description = "If true, returns only a compact symbol outline (function names, classes, variables) instead of full content. Much cheaper. Default false." }
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
        description = "Read the complete content of a file. Use this when you need to see a file's content before editing. If outline=true, returns only a compact symbol outline (function names, classes, variables) – much cheaper. Use outline first to discover what's available, then request full content only if needed.",
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
          description = "Read the complete content of a file. Use this when you need to see a file's content before editing. If outline=true, returns only a compact symbol outline (function names, classes, variables) – much cheaper. Use outline first to discover what's available, then request full content only if needed.",
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
    local outline_only = params.outline == true   -- NEW
    local proj = wellagent.get_project_root()
    local full = path:sub(1,1) == "/" and path or (proj .. "/" .. path)
    
    -- Get current session
    local session = state.current_session
    if not session then
      -- Fallback if no session: just read the file (full content or outline)
      local f, err = io.open(full, "r")
      if not f then
        return "Error: cannot read file " .. path .. " - " .. (err or "file not found")
      end
      local content = f:read("*a")
      f:close()
      if outline_only then
        content = symbols.build_outline(full, content)
      else
        context.inject_raw(full, content)
      end
      return content
    end
    
    -- Initialize read_files table if not exists
    if not session.read_files then
      session.read_files = {}
    end
    
    -- Check if file exists and is readable
    local f, err = io.open(full, "r")
    if not f then
      return "Error: cannot read file " .. path .. " - " .. (err or "file not found")
    end
    
    -- Read content and compute hash
    local content = f:read("*a")
    f:close()
    local current_hash = hash_util.hash_string(content)
    
    -- NEW: If not outline mode, check if we have a diff since last snapshot
    if not outline_only then
      local diff = session:get_diff_since_last_snapshot(full)
      if diff and diff ~= "" then
        -- File changed since last read; return diff instead of full content
        return string.format(
          "File %s changed. Here is the unified diff (context: ±3 lines):\n```diff\n%s\n```\nYou can use this to see what changed without re‑reading the whole file.",
          path, diff
        )
      end
    end
    
    -- Check session cache for unchanged file (only for full content reads)
    if not outline_only then
      local cached = session.read_files[full]
      if cached and cached.hash == current_hash then
        -- File unchanged since last read, return short reference
        local turn_info = cached.turn and (" (since turn " .. cached.turn .. ")") or ""
        return string.format(
          "[File unchanged%s. Content already provided in previous turn. Use that content.]",
          turn_info
        )
      end
    end
    
    -- Store new hash and current turn
    local turn_index = #(state.data.history or {}) + 1
    session.read_files[full] = { hash = current_hash, turn = turn_index }
    
    -- NEW: Store full snapshot for future diff (only in full mode)
    if not outline_only then
      session:store_file_snapshot(full, content, current_hash)
    end
    
    -- Inject raw content into context for future reference (only full mode)
    if not outline_only then
      context.inject_raw(full, content)
    end
    
    -- Return content (full or outline)
    if outline_only then
      return symbols.build_outline(full, content)
    else
      return content
    end
  end

  if tool_name == "edit_file" then
    local path = params.path
    local search = params.search
    local replace = params.replace
    local proj = wellagent.get_project_root()
    local full = path:sub(1,1) == "/" and path or (proj .. "/" .. path)

    if confirm_callback then
      local msg = string.format("Apply edit to %s?\nSearch:\n%s\nReplace:\n%s", path, search, replace)
      if not confirm_callback(msg) then
        return "Edit cancelled by user."
      end
    end

    -- Mark file as dirty in session cache if it was previously read
    local session = state.current_session
    if session and session.read_files and session.read_files[full] then
      session.read_files[full] = nil
    end

    -- NEW: Store a snapshot *before* the edit (so we can later show diff)
    if session then
      local before_content = hash_util.hash_file(full) -- actually we need content, but hash is enough; diff will fetch content
      -- We'll store after successful edit, but we need the old content for diff.
      -- Actually, store snapshot after edit? Let's store old content before edit.
      local f = io.open(full, "r")
      if f then
        local old_content = f:read("*a")
        f:close()
        if old_content then
          session:store_file_snapshot(full, old_content)
        end
      end
    end

    local edits = {
    {
        path = path,
        search = search,
        replace = replace,
    }
    }

    local ok, err = editor.apply_edits_to_file(path, edits, proj)
    if not ok then
      return "Edit failed: " .. (err or "unknown error")
    end

    -- NEW: After successful edit, store new snapshot for future diff
    if session then
      local new_content = hash_util.hash_file(full) -- get content after edit
      -- Actually we need the new content string; we can read again
      local f = io.open(full, "r")
      if f then
        local new_content = f:read("*a")
        f:close()
        if new_content then
          session:store_file_snapshot(full, new_content)
        end
      end
      -- Also mark the file as dirty in read_files cache (already done above)
    end

    return "Edit applied successfully to " .. path
  end

  if tool_name == "edit_file_multiple" then
    local edits = params.edits
    local proj = wellagent.get_project_root()
    local results = {}
    
    -- Mark all affected files as dirty in session cache
    local session = state.current_session
    for _, edit in ipairs(edits) do
      local full = edit.path:sub(1,1) == "/" and edit.path or (proj .. "/" .. edit.path)
      if session and session.read_files and session.read_files[full] then
        session.read_files[full] = nil
      end
      -- NEW: store snapshot before edit (if possible)
      if session then
        local f = io.open(full, "r")
        if f then
          local old_content = f:read("*a")
          f:close()
          if old_content then
            session:store_file_snapshot(full, old_content)
          end
        end
      end
    end
    
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
        local ok, err = editor.apply_edits_to_file(
            edit.path,
            { edit },
            proj
            )
        table.insert(results, ok and ("Applied: " .. edit.path) or ("Failed: " .. edit.path .. " - " .. err))
        -- NEW: after successful edit, store new snapshot
        if ok and session then
          local full = edit.path:sub(1,1) == "/" and edit.path or (proj .. "/" .. edit.path)
          local f = io.open(full, "r")
          if f then
            local new_content = f:read("*a")
            f:close()
            if new_content then
              session:store_file_snapshot(full, new_content)
            end
          end
        end
      end
    end
    return table.concat(results, "\n")
  end

  return "Unknown tool: " .. tool_name
end

return M