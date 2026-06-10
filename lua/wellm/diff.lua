-- wellm/diff.lua
-- Generate unified diffs between file versions.

local M = {}

--- Generate unified diff between old_text and new_text.
--- @param old_text string
--- @param new_text string
--- @param context_lines number (default 3)
--- @return string (empty if identical)
function M.unified_diff(old_text, new_text, context_lines)
  context_lines = context_lines or 3
  if not old_text or not new_text then return "[Diff not available]" end
  if old_text == new_text then return "" end
  
  -- Use Neovim's vim.diff (0.10+)
  if vim.diff then
    local result = vim.diff(old_text, new_text, {
      result_type = "string",
      context = context_lines,
    })
    return result or "[Diff generation failed]"
  end
  
  -- Fallback: crude line‑change indicator
  local old_lines = vim.split(old_text, "\n")
  local new_lines = vim.split(new_text, "\n")
  local max_lines = math.max(#old_lines, #new_lines)
  local changes = {}
  for i = 1, max_lines do
    if old_lines[i] ~= new_lines[i] then
      table.insert(changes, string.format("Line %d changed", i))
    end
  end
  if #changes == 0 then return ""
  else return "Changed lines: " .. table.concat(changes, ", ") end
end

return M