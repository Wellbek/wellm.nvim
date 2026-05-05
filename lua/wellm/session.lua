-- wellm/session.lua
-- Sessions are stored as markdown:  .wellagent/sessions/<id>.md
-- An index for fast listing:        .wellagent/index.json
local M = {}

local state     = require("wellm.state")
local wellagent = require("wellm.wellagent")

-- Index helpers 

local function index_path()
  return wellagent.get_root() .. "/index.json"
end

local function load_index()
  local p = index_path()
  if vim.fn.filereadable(p) == 0 then return {} end
  local ok, data = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(p), "\n"))
  return ok and data or {}
end

local function save_index(idx)
  wellagent.ensure_dirs()
  local f = io.open(index_path(), "w")
  if f then f:write(vim.fn.json_encode(idx)); f:close() end
end

-- Public API 

function M.new_id()
  return os.date("%Y-%m-%dT%H-%M-%S")
end

--- Save current history to a markdown file and update the index.
function M.save(session_id, history, title)
  if not history or #history == 0 then return end
  wellagent.ensure_dirs()

  session_id = session_id or M.new_id()
  title      = title or (history[1] and history[1].content:sub(1, 72) or "Untitled")
  -- Strip newlines from title
  title = title:gsub("\n", " ")

  local path = wellagent.get_root() .. "/sessions/" .. session_id .. ".md"

  local lines = {
    "# Session: " .. session_id,
    "> **Title:** " .. title,
    "> **Date:** "  .. os.date("%Y-%m-%d %H:%M"),
    "", "---", "",
  }
  for _, msg in ipairs(history) do
    table.insert(lines, "## " .. msg.role:upper())
    table.insert(lines, "")
    -- Indent content so markdown renders cleanly
    for _, l in ipairs(vim.split(msg.content, "\n")) do
      table.insert(lines, l)
    end
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
  end

  local f = io.open(path, "w")
  if f then f:write(table.concat(lines, "\n")); f:close() end

  -- Update index
  local idx = load_index()
  for i, e in ipairs(idx) do
    if e.id == session_id then table.remove(idx, i); break end
  end
  table.insert(idx, 1, {
    id            = session_id,
    title         = title,
    date          = os.date("%Y-%m-%d %H:%M"),
    file          = path,
    message_count = #history,
  })

  -- Trim old entries
  local cfg = require("wellm").config
  local max = cfg and cfg.sessions and cfg.sessions.max_sessions or 100
  while #idx > max do table.remove(idx) end
  save_index(idx)

  return session_id
end

--- Load a session's history from its markdown file.
function M.load(session_id)
  local path = wellagent.get_root() .. "/sessions/" .. session_id .. ".md"
  if vim.fn.filereadable(path) == 0 then return nil end

  local history      = {}
  local current_role = nil
  local buf          = {}

  for _, line in ipairs(vim.fn.readfile(path)) do
    local role = line:match("^## (USER)$") or line:match("^## (ASSISTANT)$")
    if role then
      if current_role and #buf > 0 then
        local content = table.concat(buf, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
        table.insert(history, { role = current_role:lower(), content = content })
      end
      current_role = role
      buf = {}
    elseif line ~= "---" and current_role then
      table.insert(buf, line)
    end
  end
  -- Flush last message
  if current_role and #buf > 0 then
    local content = table.concat(buf, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
    table.insert(history, { role = current_role:lower(), content = content })
  end

  return history
end

--- Return the full index list (newest first).
function M.list()
  return load_index()
end

--- Auto-save current state.data.history (called after each LLM response).
function M.auto_save()
  if #state.data.history == 0 then return end
  local id = state.data.current_session_id or M.new_id()
  state.data.current_session_id = id
  M.save(id, state.data.history)
end

return M
