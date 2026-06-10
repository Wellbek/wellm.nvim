-- wellm/session.lua
-- Sessions are stored as JSON:       .wellagent/sessions/<id>.json
-- Also saved as markdown (legacy):   .wellagent/sessions/<id>.md
-- An index for fast listing:         .wellagent/index.json
local hash_util = require("wellm.util.hash")

local Session = {}
Session.__index = Session

local M = {}

local state     = require("wellm.state")
local wellagent = require("wellm.wellagent")

-- Index helpers

local function index_path()
  return wellagent.get_root() .. "/index.json"
end

function Session.new(opts)
  opts = opts or {}
  local self = setmetatable({
    id            = opts.id,
    title         = opts.title,
    messages      = opts.messages or {},
    created_at    = opts.created_at or os.time(),
    updated_at    = opts.updated_at or os.time(),
    provider      = opts.provider,
    model         = opts.model,
    system_prompt = opts.system_prompt,
    file_cache    = opts.file_cache or {},
    read_files    = opts.read_files or {},               -- path -> { hash, turn }
    previous_file_content = opts.previous_file_content or {},
    executed_tool_calls = opts.executed_tool_calls or {},-- key -> true
    summary       = opts.summary or "",                  -- rolling summary of earlier conversation
    user_intent   = opts.user_intent or "",              -- high-level description of what the user wants
    intent_history = opts.intent_history or {},          -- { turn_index = intent_text } — log of intent evolution
  }, Session)
  return self
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
    read_files    = self.read_files,
    previous_file_content = self.previous_file_content,
    summary       = self.summary,
    user_intent   = self.user_intent,
    intent_history = self.intent_history,
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
    read_files    = t.read_files or {},
    previous_file_content = t.previous_file_content or {},
    summary       = t.summary or "",
    user_intent   = t.user_intent or "",
    intent_history = t.intent_history or {},
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

-- Store a snapshot of a file's content for diff generation
function Session:store_file_snapshot(path, content, hash)
  if not content then return end
  hash = hash or hash_util.hash_string(content)
  self.previous_file_content[path] = {
    content = content,
    hash = hash,
    turn = #self.messages,
  }
end

-- Get diff since last snapshot for a file (returns nil if unchanged or no snapshot)
function Session:get_diff_since_last_snapshot(path)
  local prev = self.previous_file_content[path]
  if not prev then return nil end
  local current_hash, current_content = hash_util.hash_file(path)
  if not current_content then return nil end
  if current_hash == prev.hash then return nil end
  local diff = require("wellm.diff").unified_diff(prev.content, current_content)
  if diff == "" then return nil end
  return diff
end

function M.new_id()
  return os.date("%Y-%m-%dT%H-%M-%S")
end

--- Save a Session object to JSON and a markdown preview, and update the index.
--- @param sess Session
function M.save_session(sess)
  if not sess or not sess.id then return end
  wellagent.ensure_dirs()

  -- 1. Save as JSON (primary format — preserves all fields)
  local json_path = wellagent.get_root() .. "/sessions/" .. sess.id .. ".json"
  sess.updated_at = os.time()
  local f = io.open(json_path, "w")
  if f then
    f:write(vim.json.encode(sess:to_table()))
    f:close()
  end

  -- 2. Save as markdown (human-readable preview)
  local md_path = wellagent.get_root() .. "/sessions/" .. sess.id .. ".md"
  local lines = {
    "# Session: " .. sess.id,
    "> **Title:** " .. (sess.title or "Untitled"),
    "> **Date:** "  .. os.date("%Y-%m-%d %H:%M", sess.updated_at),
    "",
  }
  if sess.user_intent and sess.user_intent ~= "" then
    table.insert(lines, "> **Intent:** " .. sess.user_intent:sub(1, 200))
    table.insert(lines, "")
  end
  -- Show intent evolution if there is any
  if sess.intent_history then
    local intent_entries = {}
    for k, v in pairs(sess.intent_history) do
      table.insert(intent_entries, { turn = tonumber(k) or 0, text = v })
    end
    table.sort(intent_entries, function(a, b) return a.turn < b.turn end)
    if #intent_entries > 1 then
      table.insert(lines, "> **Intent History:**")
      for _, ie in ipairs(intent_entries) do
        table.insert(lines, ">   Turn " .. ie.turn .. ": " .. ie.text:sub(1, 150))
      end
      table.insert(lines, "")
    end
  end
  if sess.summary and sess.summary ~= "" then
    table.insert(lines, "## SUMMARY")
    table.insert(lines, "")
    for _, l in ipairs(vim.split(sess.summary, "\n")) do
      table.insert(lines, l)
    end
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
  end
  for _, msg in ipairs(sess.messages) do
    table.insert(lines, "## " .. msg.role:upper())
    table.insert(lines, "")
    for _, l in ipairs(vim.split(msg.content or "", "\n")) do
      table.insert(lines, l)
    end
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
  end

  f = io.open(md_path, "w")
  if f then f:write(table.concat(lines, "\n")); f:close() end

  -- 3. Update index
  local idx = load_index()
  for i, e in ipairs(idx) do
    if e.id == sess.id then table.remove(idx, i); break end
  end
  local title = sess.title or "Untitled"
  table.insert(idx, 1, {
    id            = sess.id,
    title         = title,
    updated_at    = sess.updated_at,
    message_count = #sess.messages,
  })

  local cfg = require("wellm").config
  local max = cfg and cfg.sessions and cfg.sessions.max_sessions or 100
  while #idx > max do table.remove(idx) end
  save_index(idx)
end

--- Legacy: save history as markdown (kept for backwards compat).
--- Prefer M.save_session(sess) which preserves all session state.
function M.save(session_id, history, title)
  title = title or session_id
  wellagent.ensure_dirs()

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
    for _, l in ipairs(vim.split(msg.content, "\n")) do
      table.insert(lines, l)
    end
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
  end

  local f = io.open(path, "w")
  if f then f:write(table.concat(lines, "\n")); f:close() end

  local idx = load_index()
  for i, e in ipairs(idx) do
    if e.id == session_id then table.remove(idx, i); break end
  end
  table.insert(idx, 1, { id = session_id, title = title, updated_at = os.time() })

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

function M.load_sessions()
  local idx = load_index()
  local sessions = {}
  for _, entry in ipairs(idx) do
    local json_path = wellagent.get_root() .. "/sessions/" .. entry.id .. ".json"
    if vim.fn.filereadable(json_path) == 1 then
      local ok, content = pcall(function()
        return table.concat(vim.fn.readfile(json_path), "\n")
      end)
      if ok and content then
        local decode_ok, data = pcall(vim.json.decode, content)
        if decode_ok and data then
          local sess = Session.from_table(data)
          if sess then
            sess:validate_file_cache()
            sessions[#sessions + 1] = sess
          end
        end
      end
    end
  end
  return sessions
end

--- for JSON-based loading
function M.load_session(id)
  local json_path = wellagent.get_root() .. "/sessions/" .. id .. ".json"
  if vim.fn.filereadable(json_path) == 0 then return nil end
  local ok, content = pcall(function()
    return table.concat(vim.fn.readfile(json_path), "\n")
  end)
  if not ok or not content then return nil end
  local decode_ok, data = pcall(vim.json.decode, content)
  if not decode_ok or not data then return nil end
  local sess = Session.from_table(data)
  if sess then sess:validate_file_cache() end
  return sess
end

function M.list()
  return load_index()
end

--- Auto-save the current session (called after each LLM response).
--- Persists the full Session object including messages, summary, and user_intent.
function M.auto_save()
  local sess = state.current_session
  if not sess then
    -- Legacy path: no session object, use history directly
    if #state.data.history == 0 then return end
    local id = state.data.current_session_id or M.new_id()
    state.data.current_session_id = id
    M.save(id, state.data.history)
    return
  end
  -- Derive title from the first user message if not already set
  if not sess.title or sess.title == "New Session" then
    for _, msg in ipairs(sess.messages) do
      if msg.role == "user" and msg.content and msg.content ~= "" then
        sess.title = msg.content:sub(1, 80):gsub("\n", " ")
        break
      end
    end
  end
  M.save_session(sess)
end

--- Build messages array for the LLM: always includes the user_intent anchor,
--- a rolling summary of earlier conversation (if any), and the recent turns.
--- The user_intent is ALWAYS injected so the model never forgets what the
--- user originally asked for.  The summary condenses older turns so that
--- context stays within token limits without losing information.
--- @param recent_turns number how many full turns to keep verbatim (default: cfg.sessions.summary_turns or 6)
--- @return table messages array ready for the provider
function Session:get_messages(recent_turns)
  local cfg = require("wellm").config
  local n = recent_turns or (cfg.sessions and cfg.sessions.summary_turns) or 6
  local full = self.messages or {}
  local messages = {}
  local start = math.max(1, #full - n * 2 + 1)
  for i = start, #full do
    table.insert(messages, full[i])
  end
  return messages
end

---Returns formatted string for system prompt (intent + summary)
function Session:context_header()
  local parts = {}
  if self.user_intent and self.user_intent ~= "" then
    table.insert(parts, "## Current Conversation Goal\n" .. self.user_intent)
  end
  if self.summary and self.summary ~= "" then
    table.insert(parts, "## Previous Conversation Summary\n" .. self.summary)
  end
  if #parts == 0 then return nil end
  return table.concat(parts, "\n\n")
end

--- Return the full unpruned history (for explicit recall commands).
function M.get_full_messages()
  if state.current_session then
    return state.current_session.messages
  end
  return state.data.history
end

--- Add a message to the session's message list and also to state.data.history
--- (which the chat UI reads from for rendering).
--- @param role string "user" | "assistant" | "tool"
--- @param content string
--- @param extra table|nil optional extra fields (e.g. tool_calls, tool_call_id)
function Session:add_message(role, content, extra)
  local msg = vim.tbl_extend("force", { role = role, content = content or "" }, extra or {})
  table.insert(self.messages, msg)
  -- Keep state.data.history in sync for the chat UI
  table.insert(state.data.history, msg)
  self.updated_at = os.time()
end

--- Update the user_intent field — a short description of what the user is
--- trying to accomplish.  Called after each user message so it stays fresh.
--- On the first message, the intent is seeded directly.
--- On subsequent messages, the intent is updated when the user's message
--- appears to introduce a NEW goal or pivot.  The old intent is preserved
--- in intent_history so nothing is lost.
--- @param user_msg string The user's latest message
function Session:update_user_intent(user_msg)
  local turn_index = #self.messages

  -- If no intent yet, seed it from the first user message
  if not self.user_intent or self.user_intent == "" then
    self.user_intent = user_msg
    self.intent_history = self.intent_history or {}
    self.intent_history[tostring(turn_index)] = user_msg
    return
  end

  -- Heuristic: detect if the user is introducing a new direction.
  -- Continuation signals: "continue", "go on", "yes", "ok", "keep going",
  -- "and?", "what else", "more", etc. — these do NOT update intent.
  -- New task signals: imperatives, questions about different topics, or
  -- messages that are substantially different from the current intent.
  local continuation_patterns = {
    "^continue", "^go on", "^keep going", "^yes$", "^ok$",
    "^and%?", "^what else", "^more", "^go ahead", "^proceed",
    "^sure", "^right", "^correct", "^exactly", "^thanks$",
    "^please continue", "^carry on", "^next", "^then%?",
  }

  local lower_msg = vim.trim(user_msg:lower())
  local is_continuation = false
  for _, pat in ipairs(continuation_patterns) do
    if lower_msg:match(pat) then
      is_continuation = true
      break
    end
  end

  if is_continuation then
    -- Don't update intent for simple continuations
    return
  end

  -- For messages that aren't simple continuations, update the intent
  -- to reflect the current goal while preserving the original in history.
  -- If the new message is substantially different, it becomes the new intent.
  self.intent_history = self.intent_history or {}
  self.intent_history[tostring(turn_index)] = user_msg

  -- Update user_intent to include the latest goal alongside the original
  -- This way, when the user says "now fix the tests" after "implement feature X",
  -- the intent becomes: "implement feature X → now fix the tests"
  local original_intent = self.intent_history["0"] or self.user_intent
  if #self.intent_history <= 2 then
    -- Still early in the conversation; just use the latest message as intent
    self.user_intent = original_intent
  else
    -- Build a compact intent that traces the goal evolution
    local intent_parts = {}
    local sorted_entries = {}
    for k, v in pairs(self.intent_history) do
      table.insert(sorted_entries, { turn = tonumber(k) or 0, text = v })
    end
    table.sort(sorted_entries, function(a, b) return a.turn < b.turn end)
    -- Take the first (original) and last (current) intent, plus up to 2 pivots
    if #sorted_entries >= 1 then
      table.insert(intent_parts, "Original goal: " .. sorted_entries[1].text:sub(1, 200))
    end
    -- Add significant pivots (skip immediate successors)
    for i = 2, math.max(#sorted_entries - 1, 1) do
      if i < #sorted_entries then
        table.insert(intent_parts, "Then: " .. sorted_entries[i].text:sub(1, 150))
      end
    end
    if #sorted_entries >= 2 then
      table.insert(intent_parts, "Current goal: " .. sorted_entries[#sorted_entries].text:sub(1, 200))
    end
    self.user_intent = table.concat(intent_parts, " → ")
  end
end

--- Update the rolling summary using a cheap LLM call.
--- Called after each assistant response to condense older turns.
function Session:update_summary()
  local cfg = require("wellm").config
  if not cfg or not cfg.api_key or cfg.api_key == "" then return end
  if #self.messages < 4 then return end  -- nothing to summarize yet

  -- Only summarize if there are enough older turns beyond the recent window
  local n = (cfg.sessions and cfg.sessions.summary_turns) or 10
  local older_count = #self.messages - n * 2
  if older_count <= 0 then return end

  -- Gather the older messages that will be pruned
  local older_text = {}
  for i = 1, math.min(#self.messages, math.max(0, #self.messages - n * 2)) do
    local msg = self.messages[i]
    table.insert(older_text, msg.role:upper() .. ": " .. (msg.content or ""):sub(1, 500))
  end

  if #older_text == 0 then return end

  local llm = require("wellm.llm")
  local prompt = string.format(
    "You maintain a concise, information-dense running summary of a coding conversation.\n" ..
    "Current summary: %s\n\n" ..
    "Older conversation turns to incorporate:\n%s\n\n" ..
    "Update the summary (max 400 tokens) to include:\n" ..
    "- The user's original goal and any refinements\n" ..
    "- Key decisions made and why\n" ..
    "- Files read or modified (with paths)\n" ..
    "- Current progress toward the goal\n" ..
    "- Any outstanding tasks or next steps\n" ..
    "Do NOT repeat verbatim. Use plain language only.",
    self.summary or "(empty)",
    table.concat(older_text, "\n\n")
  )
  llm.raw_call({{ role = "user", content = prompt }}, "You are a summarizer.", function(content, _, err)
    if content and not err then
      self.summary = vim.trim(content)
    end
  end)
end

--- Get or create the current session.  This is the main entry point that
--- ensures state.current_session always points to a valid Session object
--- when a conversation is active.
--- @return Session
function M.get_or_create()
  if state.current_session then
    return state.current_session
  end

  -- Try to restore from a saved session ID
  if state.data.current_session_id then
    local sessions = M.load_sessions()
    for _, s in ipairs(sessions) do
      if s.id == state.data.current_session_id then
        state.current_session = s
        -- Sync messages back to state.data.history for the chat UI
        state.data.history = vim.deepcopy(s.messages)
        return s
      end
    end
  end

  -- Create a brand new session
  local id = M.new_id()
  local cfg = require("wellm").config
  local s = Session.new({
    id         = id,
    title      = "New Session",
    provider   = cfg.provider,
    model      = cfg.model,
    messages   = vim.deepcopy(state.data.history),   -- import existing history
  })
  -- Seed user_intent from first user message
  for _, msg in ipairs(s.messages) do
    if msg.role == "user" and msg.content and msg.content ~= "" then
      s.user_intent = msg.content
      break
    end
  end
  state.current_session      = s
  state.data.current_session_id = id
  -- keep state.data.history unchanged
  return s
end

return M
