-- wellm/llm.lua
-- Central LLM call with:
--   tiered context injection (wellagent ctx -> selected files -> user msg)
--   auto [READ: path] tool loop
--   usage recording
--   session auto-save
local M = {}

local state     = require("wellm.state")
local providers = require("wellm.providers")
local context   = require("wellm.context")
local wellagent = require("wellm.wellagent")
local usage     = require("wellm.usage")
local session   = require("wellm.session")

-- Payload builder 

--- Build the messages array and system prompt for the API call.
--- mode: "replace" | "insert" | "chat" | "orient"
function M.build_payload(user_text, mode, extra_file_ctx)
  local cfg = require("wellm").config

  -- System prompt
  local sys = state.data.system_override
    or (mode == "chat" and cfg.prompts.chat)
    or cfg.prompts.coding

  -- Prepend .wellagent project context to system prompt
  local proj_ctx = wellagent.build_system_context()
  if proj_ctx then
    sys = proj_ctx .. "\n\n---\n\n" .. sys
  end

  -- Build messages from history
  local messages = {}
  for _, msg in ipairs(state.data.history) do
    table.insert(messages, { role = msg.role, content = msg.content })
  end

  -- Assemble user message
  local parts = { user_text }

  local ctx_block = context.build_block()
  if ctx_block then
    table.insert(parts, ctx_block)
  end

  if extra_file_ctx then
    table.insert(parts, "## Current File\n```\n" .. extra_file_ctx .. "\n```")
  end

  table.insert(messages, {
    role    = "user",
    content = table.concat(parts, "\n\n"),
  })

  return messages, sys
end

-- READ loop 

local function extract_reads(text)
  local reads = {}
  for path in text:gmatch("%[READ: ([^\]]+)%]") do
    -- Resolve relative to project root
    local proj = wellagent.get_project_root()
    local full  = (path:sub(1, 1) == "/") and path or (proj .. "/" .. path)
    table.insert(reads, full)
  end
  return reads
end

local function inject_read_files(reads)
  local injected = 0
  for _, path in ipairs(reads) do
    if vim.fn.filereadable(path) == 1 then
      local ok, lines = pcall(vim.fn.readfile, path)
      if ok then
        context.inject_raw(path, table.concat(lines, "\n"))
        injected = injected + 1
      end
    else
      vim.notify("[Wellm] LLM requested file not found: " .. path, vim.log.levels.WARN)
    end
  end
  return injected
end

-- Raw curl call 

--- Fire a single API call. On completion, calls cb(content, usage_data, err).
local function raw_call(messages, sys, cb)
  local cfg      = require("wellm").config
  local provider = providers.get(cfg.provider)
  local req      = provider.build_request(cfg, messages, sys)

  -- Write body to tempfile to avoid shell-escaping issues
  local tmp = os.tmpname()
  local f   = io.open(tmp, "w")
  if f then f:write(req.body); f:close() end

  local curl_cmd = { "curl", "-s", "-X", "POST", req.url }
  for _, h in ipairs(req.headers) do table.insert(curl_cmd, h) end
  table.insert(curl_cmd, "-d")
  table.insert(curl_cmd, "@" .. tmp)

  local chunks = {}

  state.data.job_id = vim.fn.jobstart(curl_cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(chunks, line) end
        end
      end
    end,
    on_exit = function(_, code)
      os.remove(tmp)
      if code ~= 0 then
        vim.schedule(function()
          cb(nil, nil, "curl exited with code " .. code)
        end)
        return
      end

      local raw = table.concat(chunks, "")
      local ok, decoded = pcall(vim.fn.json_decode, raw)

      vim.schedule(function()
        if not ok then
          cb(nil, nil, "JSON decode failed: " .. raw:sub(1, 200))
          return
        end
        local content, used, err = provider.parse_response(decoded)
        cb(content, used, err)
      end)
    end,
  })
end

-- Public call (with READ loop) 

--- Call the LLM for a given mode, with optional extra file context.
--- callback(response_text) is called on success.
function M.call(user_text, mode, callback, extra_file_ctx)
  local cfg = require("wellm").config

  if not cfg.api_key or cfg.api_key == "" then
    vim.notify("[Wellm] No API key configured.", vim.log.levels.ERROR)
    return
  end

  local messages, sys = M.build_payload(user_text, mode, extra_file_ctx)
  local max_reads     = 3    -- prevent infinite loops
  local read_count    = 0

  local function attempt(msgs, s)
    raw_call(msgs, s, function(content, used, err)
      if err then
        vim.notify("[Wellm] API error: " .. err, vim.log.levels.ERROR)
        return
      end
      if not content or content == "" then
        vim.notify("[Wellm] Empty response from AI.", vim.log.levels.WARN)
        return
      end

      -- Record usage
      if used then
        usage.record(cfg.model, used.input_tokens, used.output_tokens)
      end

      -- Extract and log any [DECISION] markers
      wellagent.extract_decisions(content)

      -- Check if the model wants to read files
      local reads = extract_reads(content)
      if #reads > 0 and read_count < max_reads then
        read_count = read_count + inject_read_files(reads)

        -- Append the model's "thinking" turn + user acknowledgement, then re-call
        table.insert(msgs, { role = "assistant", content = content })
        table.insert(msgs, {
          role    = "user",
          content = "Files injected. Please continue with your full answer.",
        })

        local new_msgs, new_sys = M.build_payload("", mode, nil)
        -- Replace messages (files are now in context_files)
        attempt(new_msgs, new_sys)
        return
      end

      -- Clean code-only responses
      if mode == "replace" or mode == "insert" then
        content = content:gsub("^```%w*\n", ""):gsub("\n?```$", "")
      end

      -- Append to history
      -- (user message was already appended before calling; append assistant now)
      table.insert(state.data.history, {
        role    = "assistant",
        content = content,
      })

      -- Auto-save session
      if cfg.sessions and cfg.sessions.save_automatically then
        session.auto_save()
      end

      callback(content)
    end)
  end

  -- Add user message to history before firing (so history stays consistent)
  table.insert(state.data.history, { role = "user", content = user_text })
  attempt(messages, sys)
end

-- Orient call 

--- One-shot call to generate OVERVIEW.md + STRUCTURE.md for a project.
function M.orient(on_done)
  local cfg        = require("wellm").config
  local proj_root  = wellagent.get_project_root()
  local ignored    = cfg.wellagent and cfg.wellagent.ignored_patterns or {}
  local tree       = wellagent.generate_tree(proj_root, ignored)

  local prompt = cfg.prompts.orient
    .. "\n\n## File Tree\n```\n" .. proj_root .. "\n" .. tree .. "\n```"

  local msgs = {{ role = "user", content = prompt }}
  local sys  = "You produce concise, accurate developer documentation. Output only valid Markdown."

  vim.notify("[Wellm] Orienting project... (this may take a moment)", vim.log.levels.INFO)

  raw_call(msgs, sys, function(content, used, err)
    if err or not content or content == "" then
      vim.notify("[Wellm] Orient failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if used then usage.record(cfg.model, used.input_tokens, used.output_tokens) end

    -- Split OVERVIEW / STRUCTURE sections
    local overview  = content:match("## OVERVIEW\n(.-)\n## STRUCTURE") or content
    local structure = content:match("## STRUCTURE\n(.+)$") or tree

    wellagent.write_context("OVERVIEW.md",  vim.trim(overview))
    wellagent.write_context("STRUCTURE.md", vim.trim(structure))

    vim.notify("[Wellm] Project oriented. OVERVIEW.md + STRUCTURE.md written.")
    if on_done then on_done() end
  end)
end

return M
