-- wellm/llm.lua
-- Central LLM call with:
--   tiered context injection (wellagent ctx -> selected files -> user msg)
--   auto [READ: path] tool loop
--   usage recording
--   session auto-save
--   optional streaming (raw_stream / call_stream)
local M = {}

local state     = require("wellm.state")
local providers = require("wellm.providers")
local context   = require("wellm.context")
local wellagent = require("wellm.wellagent")
local usage     = require("wellm.usage")
local session   = require("wellm.session")
local spinner   = require("wellm.ui.spinner")

-- Token estimation heuristic
function M.estimate_tokens(messages)
  local total = 0
  for _, msg in ipairs(messages) do
    total = total + math.ceil((msg.content and #msg.content or 0) / 3.5) + 5
  end
  return total
end

-- Payload builder

--- Build the messages array and system prompt for the API call.
--- mode: "replace" | "insert" | "chat" | "orient"
function M.build_payload(user_text, mode, extra_file_ctx)
  local cfg = require("wellm").config

  -- System prompt
  local sys = state.data.system_override
    or (mode == "chat" and cfg.prompts.chat)
    or cfg.prompts.coding

  -- Append file-editing instructions for chat mode when filechanges is active
  local filechanges = cfg.filechanges or "filechanges_confirm"
  if mode == "chat" and filechanges ~= "filechanges_off" and cfg.prompts.fileops then
    sys = sys .. "\n\n" .. cfg.prompts.fileops
  end

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
  if ctx_block then table.insert(parts, ctx_block) end

  if extra_file_ctx then
    table.insert(parts, "## Current File\n```\n" .. extra_file_ctx .. "\n```")
  end

  table.insert(messages, {
    role    = "user",
    content = table.concat(parts, "\n\n"),
  })

  return messages, sys
end

-- Valid path heuristic
local function looks_like_real_path(s)
  s = vim.trim(s)
  if s == "" then return false end
  if not s:match("^[%a_./]") then return false end
  if s:match("[%^%$%(%)%%{%}%[%]%*%+%?<>|]") then return false end
  if not s:match("/") and not s:match("^%.") then return false end
  local lower = s:lower()
  for _, word in ipairs({"example","placeholder","your","path","similar","etc","foo","bar","todo"}) do
    if lower:match(word) then return false end
  end
  return true
end

--- Remove markdown code fences from text so tool-call markers
--- inside examples/documentation are never extracted.
local function strip_code_fences(text)
  -- Remove fenced code blocks (``` ... ```)
  return text:gsub("```.-```", "")
end

-- Extract multiple READ markers per line, return paths (relative)
local function extract_read_paths(text)
  local paths = {}
  -- Match each [READ: path] individually. The pattern captures the part between
  -- '[READ:' and the closing ']'. Works correctly even when multiple markers
  -- appear on the same line because each ']' ends a match.
  for path in text:gmatch("%[READ:%s*([^%]]+)%]") do
    local trimmed = vim.trim(path)
    if looks_like_real_path(trimmed) then
      paths[#paths+1] = trimmed
    end
  end
  return paths
end

-- Process reads: returns {success={path:full}, failure={rel_path}}
local function process_reads(rel_paths)
  local success = {}
  local failure = {}
  for _, rel in ipairs(rel_paths) do
    local proj = wellagent.get_project_root()
    local full = (rel:sub(1,1) == "/") and rel or (proj .. "/" .. rel)
    if vim.fn.filereadable(full) == 1 then
      local ok, lines = pcall(vim.fn.readfile, full)
      if ok then
        context.inject_raw(full, table.concat(lines, "\n"))
        success[#success+1] = rel
      else
        failure[#failure+1] = rel
      end
    else
      failure[#failure+1] = rel
    end
  end
  return success, failure
end

-- Raw non-streaming call
function M.raw_call(messages, sys, cb)
  local cfg = require("wellm").config
  local provider = require("wellm.providers").get(cfg.provider)
  local req = provider.build_request(cfg, messages, sys)

  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
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
        vim.schedule(function() cb(nil, nil, "curl exit " .. code) end)
        return
      end

      local raw = table.concat(chunks, "")
      local ok, decoded = pcall(vim.fn.json_decode, raw)

      vim.schedule(function()
        if not ok then
          cb(nil, nil, "JSON decode failed: " .. raw:sub(1,200))
          return
        end
        local content, used, err = provider.parse_response(decoded)
        cb(content, used, err)
      end)
    end,
  })
end

-- Raw streaming call

--- Fire a streaming API call.
---   on_delta(text)              called for each text chunk as it arrives
---   on_done(full_text, usage, err)  called once when the stream ends
---
--- Falls back to raw_call if the provider does not implement build_stream_request.
function M.raw_stream(messages, sys, on_delta, on_done)
  local cfg = require("wellm").config
  local provider = require("wellm.providers").get(cfg.provider)

  if not provider.build_stream_request then
    M.raw_call(messages, sys, function(content, used, err)
      if content and content ~= "" then
        vim.schedule(function() on_delta(content) end)
      end
      on_done(content, used, err)
    end)
    return
  end

  local req = provider.build_stream_request(cfg, messages, sys)

  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  if f then f:write(req.body); f:close() end

  -- -N / --no-buffer disables curl's internal output buffering so chunks
  -- arrive as soon as the server sends them.
  local curl_cmd = { "curl", "-s", "-N", "-X", "POST", req.url }
  for _, h in ipairs(req.headers) do table.insert(curl_cmd, h) end
  table.insert(curl_cmd, "-d")
  table.insert(curl_cmd, "@" .. tmp)

  local full_content = ""
  local usage_acc = { input_tokens = 0, output_tokens = 0 }
  local raw_lines = {}

  state.data.job_id = vim.fn.jobstart(curl_cmd, {
    -- stdout_buffered = false → on_stdout fires per-line as data arrives
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(raw_lines, line)
          local delta, used, _ = provider.parse_stream_line(line)

          if delta and delta ~= "" then
            full_content = full_content .. delta
            vim.schedule(function() on_delta(delta) end)
          end

          if used then
            if used.input_tokens then usage_acc.input_tokens = usage_acc.input_tokens + used.input_tokens end
            if used.output_tokens then usage_acc.output_tokens = usage_acc.output_tokens + used.output_tokens end
          end
        end
      end
    end,
    on_exit = function(_, code)
      os.remove(tmp)
      vim.schedule(function()
        if code ~= 0 then
          on_done(nil, nil, "curl exit " .. code)
          return
        end

        -- If no SSE deltas were parsed the server likely returned a plain
        -- JSON error body (auth failure, rate limit, etc.).
        if full_content == "" then
          local raw = table.concat(raw_lines, "")
          local ok, decoded = pcall(vim.fn.json_decode, raw)
          if ok and decoded.error then
            on_done(nil, nil, decoded.error.message or "API error")
            return
          end
        end

        on_done(full_content, usage_acc, nil)
      end)
    end,
  })
end

-- Public streaming call with automatic READ handling and continuation
function M.call_stream(user_text, mode, on_delta, callback, extra_file_ctx)
  local cfg = require("wellm").config
  if not cfg.api_key or cfg.api_key == "" then
    vim.notify("[Wellm] No API key", vim.log.levels.ERROR)
    callback(nil)
    return
  end

  wellagent.build_file_cache()

  local function start_conversation(initial_messages, initial_sys, read_round)
    read_round = read_round or 0
    local max_read_rounds = 3

    M.raw_stream(initial_messages, initial_sys, on_delta, function(content, used, err)
      if used then usage.record(cfg.model, used.input_tokens, used.output_tokens) end
      if err then
        spinner.stop()
        vim.notify("API Error: " .. tostring(err), vim.log.levels.ERROR)
        callback(nil)
        return
      end
      if not content or content == "" then
        spinner.stop()
        vim.notify("Empty response", vim.log.levels.WARN)
        callback(nil)
        return
      end

      -- Record usage
      if used then
        usage.record(cfg.model, used.input_tokens, used.output_tokens)
      end

      wellagent.extract_decisions(content)

      local cleaned = strip_code_fences(content)
      local read_paths = extract_read_paths(cleaned)

      if #read_paths > 0 and read_round < max_read_rounds then
        -- Process the reads
        spinner.set_status("reading files...")
        local success, failure = process_reads(read_paths)

        -- Build feedback message for the LLM
        local feedback_lines = {}
        if #success > 0 then
          feedback_lines[#feedback_lines+1] = "Successfully read: " .. table.concat(success, ", ")
        end
        if #failure > 0 then
          feedback_lines[#feedback_lines+1] = "Failed to read (file not found or unreadable): " .. table.concat(failure, ", ")
        end
        feedback_lines[#feedback_lines+1] = "Please continue with your answer. If some files were missing, provide guidance without them."

        local feedback = table.concat(feedback_lines, "\n")

        -- Do NOT save the intermediate READ-only response to history.
        -- Instead, append the assistant's marker and the feedback as a new user turn.
        local new_messages = vim.deepcopy(initial_messages)
        -- Add a placeholder assistant message (won't be saved later)
        table.insert(new_messages, { role = "assistant", content = "[Processing file reads]" })
        table.insert(new_messages, { role = "user", content = feedback })

        local _, new_sys = M.build_payload("", mode, nil)
        spinner.set_status("LLM thinking...")
        start_conversation(new_messages, new_sys, read_round + 1)
        return
      end

      -- No reads, or max rounds reached: this is the final answer
      -- Save the user message and this final assistant response
      table.insert(state.data.history, { role = "user", content = user_text })
      table.insert(state.data.history, { role = "assistant", content = content })

      if cfg.sessions and cfg.sessions.save_automatically then
        session.auto_save()
      end

      spinner.stop()
      callback(content)
    end)
  end

  local messages, sys = M.build_payload(user_text, mode, extra_file_ctx)
  spinner.start("LLM thinking...")
  start_conversation(messages, sys, 0)
end

-- Public streaming call (with READ loop)

--- Streaming variant of M.call. Used by the chat UI.
---
---   on_delta(text)   — called for each streamed chunk of the FINAL response
---   callback(text)   — called once with the complete response when done
---                      (nil on error)
function M.call_stream(user_text, mode, on_delta, callback, extra_file_ctx)
  local cfg = require("wellm").config

  if not cfg.api_key or cfg.api_key == "" then
    vim.notify("[Wellm] No API key", vim.log.levels.ERROR)
    callback("> [!] No API key")
    return
  end

  wellagent.build_file_cache()

  local function attempt(msgs, s, read_round)
    read_round = read_round or 0
    local max_read_rounds = 3

    M.raw_call(msgs, s, function(content, used, err)
      if used then usage.record(cfg.model, used.input_tokens, used.output_tokens) end
      if err then
        spinner.stop()
        callback("> [!] API Error: " .. tostring(err))
        return
      end
      if not content or content == "" then
        spinner.stop()
        callback("> [!] Empty response")
        return
      end

      wellagent.extract_decisions(content)

      local cleaned = strip_code_fences(content)
      local read_paths = extract_read_paths(cleaned)

      if #read_paths > 0 and read_round < max_read_rounds then
        local success, failure = process_reads(read_paths)
        local feedback_lines = {}
        if #success > 0 then
          feedback_lines[#feedback_lines+1] = "Successfully read: " .. table.concat(success, ", ")
        end
        if #failure > 0 then
          feedback_lines[#feedback_lines+1] = "Failed to read: " .. table.concat(failure, ", ")
        end
        feedback_lines[#feedback_lines+1] = "Continue with your answer."
        local feedback = table.concat(feedback_lines, "\n")

        local new_messages = vim.deepcopy(msgs)
        table.insert(new_messages, { role = "assistant", content = "[Processing reads]" })
        table.insert(new_messages, { role = "user", content = feedback })

        local _, new_sys = M.build_payload("", mode, nil)
        attempt(new_messages, new_sys, read_round + 1)
        return
      end

      if mode == "replace" or mode == "insert" then
        content = content:gsub("^```%w*\n", ""):gsub("\n```$", "")
      end

      table.insert(state.data.history, { role = "user", content = user_text })
      table.insert(state.data.history, { role = "assistant", content = content })
      if cfg.sessions and cfg.sessions.save_automatically then
        session.auto_save()
      end

      spinner.stop()
      callback(content)
    end)
  end

  local messages, sys = M.build_payload(user_text, mode, extra_file_ctx)
  spinner.start("LLM thinking...")
  attempt(messages, sys, 0)
end

-- Orient command
function M.orient(on_done)
  local cfg = require("wellm").config
  local proj_root = wellagent.get_project_root()
  local ignored = cfg.wellagent and cfg.wellagent.ignored_patterns or {}
  local tree = wellagent.generate_tree(proj_root, ignored)
  local prompt = cfg.prompts.orient .. "\n\n## File Tree\n```\n" .. proj_root .. "\n" .. tree .. "\n```"
  local msgs = {{ role = "user", content = prompt }}
  local sys = "You produce concise, accurate developer documentation. Output only valid Markdown."

  spinner.start("Orienting...")
  M.raw_call(msgs, sys, function(content, used, err)
    if used then usage.record(cfg.model, used.input_tokens, used.output_tokens) end
    if err or not content then
      spinner.stop()
      vim.notify("Orient failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if used then usage.record(cfg.model, used.input_tokens, used.output_tokens) end

    -- Split OVERVIEW / STRUCTURE sections
    local overview  = content:match("## OVERVIEW\n(.-)\n## STRUCTURE") or content
    local structure = content:match("## STRUCTURE\n(.+)$") or tree

    wellagent.write_context("OVERVIEW.md",  vim.trim(overview))
    wellagent.write_context("STRUCTURE.md", vim.trim(structure))

    -- Refresh the cached file structure after orient
    wellagent.refresh_structure()
    spinner.stop("Project oriented.")
    if on_done then on_done() end
  end)
end

return M