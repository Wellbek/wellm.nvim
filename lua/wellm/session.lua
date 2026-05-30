-- wellm/session.lua
-- Sessions are stored as markdown:  .wellagent/sessions/<id>.md
-- An index for fast listing:        .wellagent/index.json
local hash_util = require("wellm.util.hash")

local Session = {}
Session.__index = Session

local M = {}

local function get_state()
  return require("wellm.state")
end

local function get_wellagent()
  return require("wellm.wellagent")
end

-- Index helpers

local function index_path()
  return get_wellagent().get_root() .. "/index.json"
end

function Session.new(opts)
  opts = opts or {}
  return setmetatable({
    id            = opts.id,
    title         = opts.title,
    messages      = opts.messages or {},
    created_at    = opts.created_at,
    updated_at    = opts.updated_at,
    provider      = opts.provider,
    model         = opts.model,
    system_prompt = opts.system_prompt,
    file_cache    = opts.file_cache or {},
  }, Session)
end

local function load_index()
  local p = index_path()
  if vim.fn.filereadable(p) == 0 then return {} end
  local ok, data = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(p), "\n"))
  return ok and data or {}
end

local function save_index(idx)
  get_wellagent().ensure_dirs()
  local f = io.open(index_path(), "w")
  if f then
    f:write(vim.json.encode(idx))
    f:close()
  end
end

function Session:to_table()
  return {
    id            = self.id,
    title         = self.title,
    messages      = self.messages,
    created_at    = self.created_at,
    updated_at    = self.updated_at,
    provider      = self.provider,
    model         = self.model,
    system_prompt = self.system_prompt,
    file_cache    = self.file_cache,
  }
end

function Session.from_table(t)
  return Session.new({
    id            = t.id,
    title         = t.title,
    messages      = t.messages or {},
    created_at    = t.created_at,
    updated_at    = t.updated_at,
    provider      = t.provider,
    model         = t.model,
    system_prompt = t.system_prompt,
    file_cache    = t.file_cache or {},
  })
end

---@param path string File path (must match the cache key exactly)
function Session:mark_file_dirty(path)
  if self.file_cache[path] then
    self.file_cache[path].hash = nil
  end
end

function Session:validate_file_cache()
  for path, entry in pairs(self.file_cache) do
    if not entry.line_range then
      local current_hash = hash_util.hash_file(path)
      if current_hash and current_hash ~= entry.hash then
        entry.hash = nil
      end
    end
  end
end

function M.new_id()
  return string.format("%d-%04x", os.time(), math.random(0, 0xFFFF))
end

--- Save current history to a markdown file and update the index.
function M.save(session_id, history, title)
  title = title or session_id
  local path = get_wellagent().get_root() .. "/sessions/" .. session_id .. ".md"
  get_wellagent().ensure_dirs()

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
  table.insert(idx, 1, { id = session_id, title = title, updated_at = os.time() })

  -- Trim old entries
  local cfg = require("wellm").config
  local max = cfg and cfg.sessions and cfg.sessions.max_sessions or 100
  while #idx > max do table.remove(idx) end
  save_index(idx)

  return session_id
end

--- Load a session's history from its markdown file.
function M.load(session_id)
  local path = get_wellagent().get_root() .. "/sessions/" .. session_id .. ".md"
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

function M.load_sessions()
  local idx = load_index()
  local sessions = {}
  for _, entry in ipairs(idx) do
    local path = get_wellagent().get_root() .. "/sessions/" .. entry.id .. ".json"
    if vim.fn.filereadable(path) == 1 then
      local ok, content = pcall(table.concat, vim.fn.readfile(path), "\n")
      if ok then
        local session = Session.from_table(vim.json.decode(content))
        if session then
          session:validate_file_cache()
          sessions[#sessions + 1] = session
        end
      end
    end
  end
  return sessions
end

function M.list()
  return load_index()
end

--- Auto-save current get_state().data.history (called after each LLM response).
function M.auto_save()
  if #get_state().data.history == 0 then return end
  local id = get_state().data.current_session_id or M.new_id()
  get_state().data.current_session_id = id
  M.save(id, get_state().data.history)
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
    "Previous summary: %s\n\nNew exchange:\nUSER: %s\nASSISTANT: %s\n\n" ..
    "Update the summary (max 300 tokens) to include key decisions, code added, and file context. " ..
    "Do NOT repeat verbatim. Use plain language only.",
    M.summary, user_msg, assistant_msg
  )
  llm.raw_call({{ role = "user", content = prompt }}, "You are a summarizer.", function(content, _, err)
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
  local full = get_state().data.history
  local messages = {}
  -- system prompt is added by llm.build_payload, not here
  if M.summary and M.summary ~= "" then
    table.insert(messages, { role = "user",      content = "Conversation summary so far:\n" .. M.summary })
    table.insert(messages, { role = "assistant", content = "Understood. I'll continue based on the summary and recent context." })
  end
  local start = math.max(1, #full - n * 2 + 1)
  for i = start, #full do
    table.insert(messages, full[i])
  end
  return messages
end

--- Return the full unpruned history (for explicit recall commands).
function M.get_full_messages()
  return get_state().data.history
end

return M
