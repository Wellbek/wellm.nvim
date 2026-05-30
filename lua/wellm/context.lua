-- wellm/context.lua
-- Manages M.state.data.context_files: add, remove, clear.
local hash_util = require("wellm.util.hash")
local state     = require("wellm.state")

local M = {}

local SKIP_PATTERNS = {
  "%.lock$", "%.min%.js$", "%.map$", "%.png$", "%.jpg$", "%.jpeg$",
  "%.gif$", "%.svg$", "%.ico$", "%.woff", "%.ttf$", "%.eot$",
  "%.zip$", "%.tar", "%.gz$",
}

local function should_skip(name)
  if name:match("^%.") then return true end
  for _, pat in ipairs(SKIP_PATTERNS) do
    if name:match(pat) then return true end
  end
  return false
end

---@param messages table
---@param path string Absolute file path
---@param turn_index number
function M.inject_file(messages, path, turn_index)
  turn_index = turn_index or 0
  local session = state.current_session
  local cache = session and session.file_cache or {}
  local current_hash, content = hash_util.hash_file(path)

  if not current_hash or not content then
    table.insert(messages, {
      role    = "user",
      content = string.format("<file path=\"%s\">[unreadable]</file>", path),
    })
    return
  end

  local cached = cache[path]

  if not cached then
    cache[path] = { hash = current_hash, turn = turn_index }
    table.insert(messages, {
      role    = "user",
      content = string.format("<file path=\"%s\">\n%s\n</file>", path, content),
    })
  elseif cached.hash == current_hash then
    table.insert(messages, {
      role    = "user",
      content = string.format(
        "<file_ref path=\"%s\" status=\"unchanged\" since_turn=\"%d\" />",
        path, cached.turn
      ),
    })
  else
    cache[path] = { hash = current_hash, turn = turn_index }
    table.insert(messages, {
      role    = "user",
      content = string.format(
        "<file path=\"%s\" status=\"changed\">\n%s\n</file>",
        path, content
      ),
    })
  end
end

---@param messages table
---@param path string
---@param start_line number
---@param end_line number
---@param content string
---@param turn_index number
function M.inject_visual_selection(messages, path, start_line, end_line, content, turn_index)
  turn_index = turn_index or 0
  local session   = state.current_session
  local cache     = session and session.file_cache or {}
  local line_range = string.format("%d-%d", start_line, end_line)
  local cache_key  = string.format("%s:%s", path, line_range)
  local current_hash = hash_util.hash_string(content)
  local cached = cache[cache_key]

  if not cached then
    cache[cache_key] = { hash = current_hash, turn = turn_index, line_range = line_range }
    table.insert(messages, {
      role    = "user",
      content = string.format(
        "<selection path=\"%s\" start=\"%d\" end=\"%d\">\n%s\n</selection>",
        path, start_line, end_line, content
      ),
    })
  elseif cached.hash == current_hash then
    table.insert(messages, {
      role    = "user",
      content = string.format(
        "<selection_ref path=\"%s\" start=\"%d\" end=\"%d\" status=\"unchanged\" since_turn=\"%d\" />",
        path, start_line, end_line, cached.turn
      ),
    })
  else
    cache[cache_key] = { hash = current_hash, turn = turn_index, line_range = line_range }
    table.insert(messages, {
      role    = "user",
      content = string.format(
        "<selection path=\"%s\" start=\"%d\" end=\"%d\" status=\"changed\">\n%s\n</selection>",
        path, start_line, end_line, content
      ),
    })
  end
end

---@param messages table
---@param role string
---@param content string
function M.inject_message(messages, role, content)
  table.insert(messages, { role = role, content = content })
end

-- Per-session chunk cache (keyed by path)
local chunk_cache = {}

---@param path string
---@param query string|nil Optional query for relevance scoring
function M.add_file_smart(path, query)
  if not chunk_cache[path] then
    -- populate chunk_cache[path].chunks from file on first call
    local _, content = hash_util.hash_file(path)
    if not content then return end
    -- simple chunking: one chunk per top-level block (fallback: whole file)
    chunk_cache[path] = { chunks = {{ content = content, start_line = 1, end_line = 0 }} }
  end

  local cached = chunk_cache[path]

  if not query or query == "" then
    -- no query: add all chunks (fallback)
    for _, ch in ipairs(cached.chunks) do
      M.add_file_chunks(path, nil, nil, ch.content, ch.start_line, ch.end_line)
    end
    return
  end
  -- Score chunks: simple keyword overlap on first line (function sig, heading)
  local scored = {}
  for _, ch in ipairs(cached.chunks) do
    local first_line = ch.content:match("^[^\n]*") or ""
    local score = 0
    for word in query:gmatch("%w+") do
      if first_line:lower():match(word:lower()) then
        score = score + 1
      end
    end
    table.insert(scored, { chunk = ch, score = score })
  end

  table.sort(scored, function(a, b) return a.score > b.score end)
  for i = 1, math.min(3, #scored) do
    local ch = scored[i].chunk
    M.add_file_chunks(path, nil, nil, ch.content, ch.start_line, ch.end_line)
  end
end

---@param session table Current session object
---@param messages table Message array to append into
---@param contexts table List of context descriptors
function M.inject_contexts(session, messages, contexts)
  local turn_index = #session.messages
  for _, ctx in ipairs(contexts) do
    if ctx.type == "file" then
      M.inject_file(messages, ctx.path, turn_index)
    elseif ctx.type == "visual" then
      M.inject_visual_selection(messages, ctx.path, ctx.start_line, ctx.end_line, ctx.content, turn_index)
    elseif ctx.type == "message" then
      M.inject_message(messages, ctx.role, ctx.content)
    end
  end
end

function M.add_file_chunks(path, start_line, end_line, content, auto_detect_start, auto_detect_end)
  local key = path .. ":" .. (start_line or auto_detect_start or 0) .. "-" .. (end_line or auto_detect_end or 0)
  if state.data.context_files[key] then return end
  state.data.context_files[key] = {
    content    = content,
    path       = path,
    start_line = start_line or auto_detect_start,
    end_line   = end_line   or auto_detect_end,
    ttl        = (require("wellm").config.context and require("wellm").config.context.item_ttl) or 1,
    persistent = false,
  }
  vim.notify("[Wellm] Added chunk: " .. vim.fn.fnamemodify(path, ":~:.") ..
    " lines " .. (start_line or "?") .. "-" .. (end_line or "?"))
end

--- Add a single file to context (kept for compatibility, but prefers chunking)
function M.add_file(path)
  path = path or vim.fn.expand("%:p")
  if not path or path == "" or vim.fn.filereadable(path) == 0 then
    vim.notify("[Wellm] Cannot read: " .. tostring(path), vim.log.levels.WARN)
    return false
  end
  M.add_file_smart(path, nil) -- fallback: add all chunks
  return true
end

--- Remove a file or chunk from context.
function M.remove_file(path)
  for k, _ in pairs(state.data.context_files) do
    if k:match("^" .. vim.pesc(path) .. ":") or k == path then
      state.data.context_files[k] = nil
    end
  end
  vim.notify("[Wellm] Removed: " .. vim.fn.fnamemodify(path, ":~:."))
end

--- Add all non-skipped files from a directory (non-recursive by default).
function M.add_folder(path, recursive)
  path = path or vim.fn.input("Folder: ", vim.fn.expand("%:p:h"), "dir")
  if not path or path == "" then return end

  local count = 0
  local handle = vim.loop.fs_scandir(path)
  if not handle then
    vim.notify("[Wellm] Cannot scan: " .. path, vim.log.levels.WARN)
    return
  end

  while true do
    local name, ftype = vim.loop.fs_scandir_next(handle)
    if not name then break end
    local full = path .. "/" .. name
    if ftype == "file" and not should_skip(name) then
      if M.add_file(full) then count = count + 1 end
    elseif ftype == "directory" and recursive and not should_skip(name) then
      M.add_folder(full, true)
    end
  end
  vim.notify(string.format("[Wellm] Added %d file(s) from %s", count, vim.fn.fnamemodify(path, ":~:.")))
end

--- Clear all context files.
function M.clear()
  state.data.context_files = {}
  vim.notify("[Wellm] Context cleared.")
end

--- Build a context block string for injection into prompts.
function M.build_block()
  local parts = {}
  for key, item in pairs(state.data.context_files) do
    local content = type(item) == "table" and item.content or item
    local label = key
    if type(item) == "table" and item.path then
      label = item.path
      if item.start_line and item.end_line then
        label = label .. " (lines " .. item.start_line .. "-" .. item.end_line .. ")"
      end
    end
    table.insert(parts, string.format("### File: %s\n```\n%s\n```", label, content))
  end
  if #parts == 0 then return nil end
  return "## Selected Context Files\n\n" .. table.concat(parts, "\n\n")
end

--- Return a list of currently loaded paths.
function M.list()
  local keys = {}
  for k, _ in pairs(state.data.context_files) do
    table.insert(keys, k)
  end
  return keys
end

--- Inject a file content string directly (used by auto-read loop).
function M.inject_raw(path, content)
  local key = path .. ":0-0"
  state.data.context_files[key] = {
    content    = content,
    path       = path,
    start_line = 0,
    end_line   = 0,
    ttl        = 1,
  }
end

--- Expire context items with TTL <= 0 (call after each assistant response)
function M.expire()
  local to_remove = {}
  for key, item in pairs(state.data.context_files) do
    local ttl = type(item) == "table" and item.ttl
    if ttl and ttl <= 0 and not (type(item) == "table" and item.persistent) then
      table.insert(to_remove, key)
    elseif type(item) == "table" and item.ttl then
      item.ttl = item.ttl - 1
    end
  end
  for _, key in ipairs(to_remove) do
    state.data.context_files[key] = nil
  end
end

return M
