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

--- Rolling summary memory
M.summary = ""   -- condensed summary of past conversation

--- Update the rolling summary using a cheap LLM call.
--- This should be called after each assistant response.
function M.update_summary(user_msg, assistant_msg)
  local cfg = require("wellm").config
  if not cfg or not cfg.model then return end
  local llm = require("wellm.llm")
  local prompt = string.format(
    "You maintain a concise, information-dense running summary of a coding conversation. " ..
    "Previous summary: %s\n\n" ..
    "New exchange:\nUSER: %s\nASSISTANT: %s\n\n" ..
    "Update the summary (max 300 tokens) to include key decisions, code added, and file context. " ..
    "Do NOT repeat verbatim. Use plain language only.",
    M.summary, user_msg, assistant_msg
  )
  llm.raw_call({{role="user", content=prompt}}, "You are a summarizer.", function(content, _, err)
    if content and not err then
      M.summary = content
    end
  end)
end

--- Build messages array for chat: system + rolling summary + last N turns.
--- @param recent_turns number how many full turns to keep (default: cfg.session.summary_turns or 3)
function M.get_messages(recent_turns)
  local cfg = require("wellm").config
  local n = recent_turns or (cfg.sessions and cfg.sessions.summary_turns) or 3
  local full = state.data.history
  local messages = {}
  -- system prompt is added by llm.build_payload, not here
  if M.summary and M.summary ~= "" then
    table.insert(messages, { role = "user", content = "Conversation summary so far:\n" .. M.summary })
    table.insert(messages, { role = "assistant", content = "Understood. I'll continue based on the summary and recent context." })
  end
  local start = math.max(1, #full - n*2 + 1)
  for i = start, #full do
    table.insert(messages, full[i])
  end
  return messages
end

--- Return the full unpruned history (for explicit recall commands).
function M.get_full_messages()
  return state.data.history
end

return M
