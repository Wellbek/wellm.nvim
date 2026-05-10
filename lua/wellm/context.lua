-- wellm/context.lua
-- Manages M.state.data.context_files: add, remove, clear.
local M = {}

local state = require("wellm.state")

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

-- Chunk cache
local chunk_cache = {}  -- path -> { mtime, chunks: {{start, end, content}} }

--- Split file into ~chunk_size lines, return chunks with line numbers
function M.read_file_chunks(path, chunk_size)
  chunk_size = chunk_size or (require("wellm").config.context and require("wellm").config.context.chunk_size) or 50
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil end
  local chunks = {}
  for i = 1, #lines, chunk_size do
    local start_i = i
    local end_i = math.min(i + chunk_size - 1, #lines)
    local content = table.concat(lines, "\n", start_i, end_i)
    table.insert(chunks, { start_line = start_i, end_line = end_i, content = content })
  end
  return chunks
end

--- Add a file using chunking and optional smart retrieval.
--- @param path string absolute file path
--- @param query string|nil natural language query to score chunks
--- @param top_k number how many best chunks to inject (default: 3)
function M.add_file_smart(path, query, top_k)
  top_k = top_k or (require("wellm").config.context and require("wellm").config.context.smart_top_k) or 3
  local stat = vim.loop.fs_stat(path)
  if not stat then return end
  local cached = chunk_cache[path]
  if cached and cached.mtime == stat.mtime then
    -- use cached chunks
  else
    local chunks = M.read_file_chunks(path)
    if not chunks then return end
    chunk_cache[path] = { mtime = stat.mtime, chunks = chunks }
    cached = chunk_cache[path]
  end
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
  table.sort(scored, function(a,b) return a.score > b.score end)
  for i = 1, math.min(top_k, #scored) do
    local ch = scored[i].chunk
    M.add_file_chunks(path, nil, nil, ch.content, ch.start_line, ch.end_line)
  end
end

--- Add a specific chunk of a file to context (with dedup)
function M.add_file_chunks(path, start_line, end_line, content, auto_detect_start, auto_detect_end)
  local key = path .. ":" .. (start_line or auto_detect_start or 0) .. "-" .. (end_line or auto_detect_end or 0)
  if state.data.context_files[key] then return end -- dedup
  state.data.context_files[key] = {
    content = content,
    path = path,
    start_line = start_line or auto_detect_start,
    end_line = end_line or auto_detect_end,
    ttl = (require("wellm").config.context and require("wellm").config.context.item_ttl) or 1,
    persistent = false,
  }
  vim.notify("[Wellm] Added chunk: " .. vim.fn.fnamemodify(path, ":~:.") .. " lines " .. (start_line or "?") .. "-" .. (end_line or "?"))
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
  for k,_ in pairs(state.data.context_files) do
    table.insert(keys, k)
  end
  return keys
end

--- Inject a file content string directly (used by auto-read loop).
function M.inject_raw(path, content)
  local key = path .. ":0-0"
  state.data.context_files[key] = {
    content = content,
    path = path,
    start_line = 0, end_line = 0,
    ttl = 1,
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
