-- wellm/llm.lua
-- Central LLM call with tool use (function calling) support
-- Replaces [READ] parsing and manual edit extraction with native tool calls.
local M = {}

local state     = require("wellm.state")
local providers = require("wellm.providers")
local context   = require("wellm.context")
local wellagent = require("wellm.wellagent")
local usage     = require("wellm.usage")
local session   = require("wellm.session")
local spinner   = require("wellm.ui.spinner")
local tools     = require("wellm.tools")

-- Token estimation heuristic (conservative: /3 chars-per-token + per-message overhead)
-- Uses /3 instead of /3.5 because code and Chinese text have higher token-to-char ratios.
-- Per-message overhead of 8 tokens accounts for role markers, formatting, etc.
function M.estimate_tokens(messages)
  local total = 0
  for _, msg in ipairs(messages) do
    local content = msg.content or ""
    -- If content is a table (multi-part), flatten
    if type(content) == "table" then
      local flat = ""
      for _, part in ipairs(content) do
        if type(part) == "table" and part.text then
          flat = flat .. part.text
        elseif type(part) == "string" then
          flat = flat .. part
        end
      end
      content = flat
    end
    total = total + math.ceil(#content / 3) + 8

    -- Count tool_calls JSON overhead (function name + serialized arguments).
    -- The API serializes these as structured JSON which the estimator was
    -- completely ignoring, causing systematic under-counting and
    -- "model_context_window_exceeded" errors at the API level.
    if msg.tool_calls then
      for _, tc in ipairs(msg.tool_calls) do
        local fn = tc["function"] or tc.func or {}
        local args = fn.arguments
        if type(args) == "table" then
          args = vim.json.encode(args)
        end
        local name = fn.name or ""
        -- function name + arguments text + ~15 tokens structural overhead per call
        total = total + math.ceil(#(name .. tostring(args or "")) / 3) + 15
      end
    end

    -- Tool result messages carry a tool_call_id that adds overhead beyond content.
    if msg.role == "tool" and msg.tool_call_id then
      total = total + math.ceil(#msg.tool_call_id / 3) + 8
    end
  end
  return total
end

-- Payload builder
function M.build_payload(user_text, mode, extra_file_ctx)
  local cfg = require("wellm").config
  local state = require("wellm.state")
  local context = require("wellm.context")
  local wellagent = require("wellm.wellagent")
  local session = require("wellm.session")

  -- System prompt
  local sys = state.data.system_override
    or (mode == "chat" and cfg.prompts.chat)
    or cfg.prompts.coding

  -- Append file‑editing instructions (for models without tool support)
  local filechanges = cfg.filechanges or "filechanges_confirm"
  if mode == "chat" and filechanges ~= "filechanges_off" and cfg.prompts.fileops then
    sys = sys .. "\n\n" .. cfg.prompts.fileops
  end

  -- Prepend .wellagent project context
  local proj_ctx = wellagent.build_system_context()
  if proj_ctx then
    sys = proj_ctx .. "\n\n---\n\n" .. sys
  end

  -- Inject session context (intent + summary) into system prompt
  if state.current_session then
    local sess_hdr = state.current_session:context_header()
    if sess_hdr then
      sys = sess_hdr .. "\n\n---\n\n" .. sys
    end
  end

  -- Build message list using rolling summary (keeps only recent turns + summary)
  local messages = {}
  if state.current_session then
    messages = state.current_session:get_messages()  -- uses session.summary
  else
    -- Fallback to full history if no session
    for _, msg in ipairs(state.data.history) do
      table.insert(messages, { role = msg.role, content = msg.content })
    end
  end

  -- Assemble current user message
  local parts = { user_text }
  local ctx_block = context.build_block()
  if ctx_block then table.insert(parts, ctx_block) end

  if extra_file_ctx then
    local lines = vim.split(extra_file_ctx, "\n")
    local numbered = {}
    for i, l in ipairs(lines) do
      numbered[i] = string.format("%4d: %s", i, l)
    end
    table.insert(parts, "## Current File (with line numbers)\n```\n" .. table.concat(numbered, "\n") .. "\n```")
  end

  table.insert(messages, {
    role = "user",
    content = table.concat(parts, "\n\n"),
  })

  -- Token limit protection using actual context window (not response max_tokens)
  local config_module = require("wellm.config")
  local context_window = cfg.context_window
    or (config_module.context_windows and config_module.context_windows[cfg.model])
    or config_module.default_context_window
    or 128000
  local max_out = cfg.max_tokens or 8192
  local reserve = (cfg.llm and cfg.llm.output_reserve) or 4096
  -- Reserve must cover the model's max output tokens, otherwise the model
  -- could generate up to max_tokens of output and blow past the context window.
  reserve = math.max(reserve, max_out)
  local safety_margin = (cfg.llm and cfg.llm.context_safety_margin) or 0.20
  local sys_tokens = M.estimate_tokens({{role="system", content=sys}})
  local total_tokens = M.estimate_tokens(messages) + sys_tokens
  -- Apply safety margin: only use (1 - margin) of the context window
  local soft_limit = math.floor((context_window - reserve) * (1 - safety_margin))

  if total_tokens > soft_limit then
    vim.notify(string.format(
      "[Wellm] Context too large (~%d tokens, budget %d, window %d), truncating...",
      total_tokens, soft_limit, context_window), vim.log.levels.WARN)

    -- Phase 1: Remove oldest conversation messages (keep last user message)
    while #messages > 1 and total_tokens > soft_limit do
      table.remove(messages, 1)
      total_tokens = M.estimate_tokens(messages) + sys_tokens
    end

    -- Phase 2: If still over, strip context file blocks from remaining messages
    if total_tokens > soft_limit then
      for i = #messages, 1, -1 do
        if total_tokens <= soft_limit then break end
        local msg = messages[i]
        if msg.role == "user" and msg.content and msg.content:find("<file ") then
          -- Replace full file injections with references
          msg.content = msg.content:gsub(
            '<file path="([^"]+)">%s*.-%s*</file>',
            '<file path="%1">[truncated]</file>'
          )
          msg.content = msg.content:gsub(
            '<file path="([^"]+)" status="changed">%s*.-%s*</file>',
            '<file path="%1" status="changed">[truncated]</file>'
          )
          total_tokens = M.estimate_tokens(messages) + sys_tokens
        end
      end
    end
  end

  return messages, sys
end

-- Strip pre-tool reasoning preamble from assistant content before persisting.
-- The model often emits a wall of thinking before the first tool call; that text
-- has no value in future context and is the main driver of snowballing loops.
-- We keep content that appears after the last tool call result, or the full
-- content when there were no tool calls (i.e. the final natural-language reply).
local function clean_assistant_content(content, had_tool_calls)
  if not content or content == "" then return "" end
  if not had_tool_calls then return content end

  -- If the response was purely tool dispatch (no prose after tools), store empty.
  -- The tool call/result pairs are already in the in-flight messages table and
  -- don't need to be duplicated in history.
  local trimmed = vim.trim(content)
  if trimmed == "" then return "" end

  -- Heuristic: drop everything up to and including the first blank line after
  -- a sentence that looks like a reasoning preamble ("Let me", "I'll", "I need to",
  -- "Now I", "First", "Looking at"). This catches the common Claude pattern of
  -- "Let me read the file first.\n\n<actual content>".
  local preamble_pat = "^[^\n]*%f[%a][Ll]et me [^\n]*\n+(.+)$"
  local stripped = trimmed:match(preamble_pat)
              or  trimmed:match("^[^\n]*I'?ll [^\n]*\n+(.+)$")
              or  trimmed:match("^[^\n]*I need to [^\n]*\n+(.+)$")
              or  trimmed:match("^[^\n]*[Nn]ow [^\n]*\n+(.+)$")
              or  trimmed:match("^[^\n]*[Ff]irst[,% ][^\n]*\n+(.+)$")
  return vim.trim(stripped or trimmed)
end

-- Duplicate tool-call detection: returns (is_duplicate, key).
-- If the (name, args) pair has already been executed, is_duplicate=true.
-- The key is always returned so the caller can count duplicates.
local function check_duplicate_tool_call(call, executed)
  local args = call.func.arguments
  if type(args) == "table" then
    args = vim.json.encode(args)
  end
  -- args is now always a string; don't double-encode
  local key = call.func.name .. ":" .. args
  if executed[key] then return true, key end
  executed[key] = true
  return false, key
end

-- Raw non‑streaming call with tool definitions
-- Wrapped with the rate limiter: waits for capacity before sending, reads
-- anthropic-ratelimit-* response headers afterward, and auto-retries once
-- on 429 using Retry-After.
function M.raw_call(messages, sys, cb, tool_defs)
  local cfg = require("wellm").config
  local provider = require("wellm.providers").get(cfg.provider)
  local req = provider.build_request(cfg, messages, sys, tool_defs)
  local ratelimit = require("wellm.ratelimit")
  local rl_key = ratelimit.key_for(cfg)

  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  if f then f:write(req.body); f:close() end

  local retried = false

  local function do_request()
    local header_tmp = os.tmpname()
    local curl_cmd = { "curl", "-s", "-X", "POST", req.url }
    for _, h in ipairs(req.headers) do table.insert(curl_cmd, h) end
    table.insert(curl_cmd, "-d")
    table.insert(curl_cmd, "@" .. tmp)
    -- Dump response headers separately so the rate limiter can read them
    -- without disturbing the JSON body parsing below.
    table.insert(curl_cmd, "-D")
    table.insert(curl_cmd, header_tmp)

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
        local hf = io.open(header_tmp, "r")
        local raw_headers = hf and hf:read("*a") or nil
        if hf then hf:close() end
        os.remove(header_tmp)

        local status = ratelimit.update_from_headers(rl_key, raw_headers)

        if code ~= 0 then
          os.remove(tmp)
          vim.schedule(function() cb(nil, nil, nil, "curl exit " .. code) end)
          return
        end

        if status == 429 and not retried then
          retried = true
          local wait = ratelimit.seconds_until_available(rl_key)
          vim.schedule(function()
            vim.notify(string.format(
              "[Wellm] Rate limited (429). Retrying in %ds...", math.ceil(wait)), vim.log.levels.WARN)
          end)
          ratelimit.run_when_ready(rl_key, do_request)
          return
        end

        os.remove(tmp)
        local raw = table.concat(chunks, "")
        local ok, decoded = pcall(vim.fn.json_decode, raw)
        vim.schedule(function()
          if status == 429 then
            cb(nil, nil, nil, "Rate limited (429) after retry")
            return
          end
          if not ok then
            cb(nil, nil, nil, "JSON decode failed")
            return
          end
          local content, tool_calls, used, err = provider.parse_response(decoded)
          cb(content, tool_calls, used, err)
        end)
      end,
    })
  end

  ratelimit.run_when_ready(rl_key, do_request)
end

-- Raw streaming call with tool definitions
-- Raw streaming call with tool definitions
-- The `completed` guard prevents double-firing of on_done: when a stream error
-- (e.g. context_window_exceeded) is detected in on_stdout, we call on_done
-- and kill the job — but on_exit still fires with code=0, which would call
-- on_done again, causing a duplicate retry in start_conversation.
function M.raw_stream(messages, sys, on_delta, on_done, tool_defs)
  local cfg = require("wellm").config
  local provider = require("wellm.providers").get(cfg.provider)
  local ratelimit = require("wellm.ratelimit")
  local rl_key = ratelimit.key_for(cfg)
  local completed = false  -- guard against double on_done calls

  if not provider.build_stream_request then
    M.raw_call(messages, sys, function(content, tool_calls, used, err)
      if content and content ~= "" then
        vim.schedule(function() on_delta(content) end)
      end
      on_done(content, tool_calls, used, err)
    end, tool_defs)
    return
  end

  local req = provider.build_stream_request(cfg, messages, sys, tool_defs)
  local tmp = os.tmpname()
  local f = io.open(tmp, "w")
  if f then f:write(req.body); f:close() end

  local header_tmp = os.tmpname()
  local curl_cmd = { "curl", "-s", "-N", "-X", "POST", req.url }
  for _, h in ipairs(req.headers) do table.insert(curl_cmd, h) end
  table.insert(curl_cmd, "-d")
  table.insert(curl_cmd, "@" .. tmp)
  -- Headers go to a separate file so the rate limiter can read them without
  -- interfering with the SSE stream on stdout.
  table.insert(curl_cmd, "-D")
  table.insert(curl_cmd, header_tmp)

  local full_content = ""
  local tool_calls_by_id = {}   -- accumulate by id
  local usage_acc = { input_tokens = 0, output_tokens = 0 }
  local raw_lines = {}

  -- Helper: safely call on_done exactly once
  local function safe_done(content, tc, used, err)
    if completed then return end
    completed = true
    local hf = io.open(header_tmp, "r")
    local raw_headers = hf and hf:read("*a") or nil
    if hf then hf:close() end
    os.remove(header_tmp)
    ratelimit.update_from_headers(rl_key, raw_headers)
    on_done(content, tc, used, err)
  end

  local function do_request()
    state.data.job_id = vim.fn.jobstart(curl_cmd, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(raw_lines, line)
          local delta, tc_fragments, used, is_done, stream_err = provider.parse_stream_line(line)
          -- Handle stream-level errors (e.g. model_context_window_exceeded)
          if stream_err then
            vim.schedule(function()
              safe_done(nil, nil, usage_acc, stream_err)
            end)
            -- Kill the curl job to stop further processing
            if state.data.job_id then
              vim.fn.jobstop(state.data.job_id)
              state.data.job_id = nil
            end
            return
          end

          if delta and delta ~= "" then
            full_content = full_content .. delta
            vim.schedule(function() on_delta(delta) end)
          end
          -- Accumulate tool call fragments by id
          if tc_fragments and #tc_fragments > 0 then
            for _, frag in ipairs(tc_fragments) do
              local call_id = frag.id
              if not call_id then
                -- Some providers don't send id in every chunk; fallback to index
                call_id = tostring(frag.index or #tool_calls_by_id + 1)
              end
              if not tool_calls_by_id[call_id] then
                tool_calls_by_id[call_id] = {
                  id = frag.id,
                  type = frag.type or "function",
                  func = {
                    name = frag.func and frag.func.name or "",
                    arguments = ""
                  }
                }
              end
              -- Append arguments chunk (always normalize to string)
              if frag.func and frag.func.arguments then
                local chunk = frag.func.arguments
                if type(chunk) == "table" then
                  chunk = vim.json.encode(chunk)
                end
                tool_calls_by_id[call_id].func.arguments = tool_calls_by_id[call_id].func.arguments .. chunk
              end
              -- Update name if received later (rare)
              if frag.func and frag.func.name then
                tool_calls_by_id[call_id].func.name = frag.func.name
              end
            end
          end
          if used then
            if used.input_tokens then usage_acc.input_tokens = usage_acc.input_tokens + used.input_tokens end
            if used.output_tokens then usage_acc.output_tokens = usage_acc.output_tokens + used.output_tokens end
          end
          -- When the stream ends (is_done = true), we don't have a final signal here.
          -- We'll finalise on_exit.
        end
      end
    end,
    on_exit = function(_, code)
      os.remove(tmp)
      vim.schedule(function()
        if completed then return end  -- already called on_done from on_stdout
        if code ~= 0 then
          safe_done(nil, nil, nil, "curl exit " .. code)
          return
        end
        -- Convert accumulated map to array
        local final_tool_calls = {}
        for _, call in pairs(tool_calls_by_id) do
          table.insert(final_tool_calls, call)
        end
        if full_content == "" and #final_tool_calls == 0 then
          local raw = table.concat(raw_lines, "")
          vim.notify("[Wellm] Empty response, raw (first 200 chars): " .. raw:sub(1,200), vim.log.levels.WARN)
          local ok, decoded = pcall(vim.fn.json_decode, raw)
          if ok and decoded.error then
            safe_done(nil, nil, nil, decoded.error.message or "API error")
            return
          end
        end
        safe_done(full_content, final_tool_calls, usage_acc, nil)
      end)
    end,
  })
  end

  ratelimit.run_when_ready(rl_key, do_request)
end

-- wellm/llm.lua – streaming call with tool use
function M.call_stream(user_text, mode, on_delta, callback, extra_file_ctx)
  local cfg = require("wellm").config
  if not cfg.api_key or cfg.api_key == "" then
    vim.notify("[Wellm] No API key", vim.log.levels.ERROR)
    callback(nil)
    return
  end

  local sess = session.get_or_create()   -- ensures state.current_session exists

  local wellagent = require("wellm.wellagent")
  wellagent.build_file_cache()

  -- Per-request duplicate tracker (cleared on each new user request)
  local executed_in_this_request = {}
  local duplicate_count        = 0
  local duplicate_tolerance    = (cfg.llm and cfg.llm.duplicate_tolerance) or 5
  local save_interval          = (cfg.llm and cfg.llm.save_interval_chars) or 2000
  local chars_since_last_save  = 0

  local full_assistant_response = ""
  local function acc_delta(delta)
    full_assistant_response = full_assistant_response .. delta
    chars_since_last_save = chars_since_last_save + #delta
    -- Periodically update the assistant message in session and save
    if chars_since_last_save >= save_interval then
      chars_since_last_save = 0
      local last_msg = sess.messages[#sess.messages]
      if last_msg and last_msg.role == "assistant" then
        last_msg.content = full_assistant_response
      end
      if cfg.sessions and cfg.sessions.save_automatically then
        session.auto_save()
      end
    end
    on_delta(delta)
  end

  local state = require("wellm.state")

  local ctx_retry_count = 0
  local CTX_MAX_RETRIES = 2  -- max auto-retries on context window exceeded

  local function start_conversation(messages, sys, tool_round)
    tool_round = tool_round or 0
    -- Use config value; fallback to 30
    local max_tool_rounds = (cfg.llm and cfg.llm.max_tool_rounds) or 30
    local tool_defs = require("wellm.tools").get_tool_definitions(cfg.provider)

    -- Reset per-round accumulator – this prevents the model seeing its own preamble
    local round_response = ""

    -- Custom delta handler for this round only
    local function round_delta(delta)
      round_response = round_response .. delta
      acc_delta(delta)
    end

    M.raw_stream(messages, sys, round_delta, function(content, tc, used, err)
      if used then require("wellm.usage").record(cfg.model, used.input_tokens, used.output_tokens) end
      if err then
        local err_msg = tostring(err)

        -- Auto-retry on context window exceeded: aggressively truncate and retry.
        -- Match flexibly because Zhipu returns errors as HTTP JSON (e.g.
        -- "This model's maximum context length is 128000 tokens...") not as
        -- the finish_reason string that parse_stream_line checks for.
        local lower_err = err_msg:lower()
        local is_ctx_exceeded = err_msg == "model_context_window_exceeded"
          or lower_err:match("context.*exceed")
          or lower_err:match("maximum.*context.*length")
          or lower_err:match("token.*exceed")
          or lower_err:match("too many tokens")
          or lower_err:match("prompt.*too.*long")
          or lower_err:match("length.*exceed")
          or lower_err:match("exceeds.*context")
          or lower_err:match("exceeds.*token")
        if is_ctx_exceeded and ctx_retry_count < CTX_MAX_RETRIES then
          ctx_retry_count = ctx_retry_count + 1
          local removed = 0
          -- Remove oldest messages until we're at 60% of current count.
          -- Remove assistant+tool groups atomically: if we delete an assistant
          -- message that had tool_calls but leave the orphaned tool results,
          -- the API will immediately reject the retry.
          local target = math.max(2, math.floor(#messages * 0.6))
          while #messages > target do
            local first = messages[1]
            if not first then break end
            table.remove(messages, 1)
            removed = removed + 1
            -- If we removed an assistant with tool_calls, also remove the
            -- orphaned tool result messages that followed it.
            if first.role == "assistant" and first.tool_calls then
              while messages[1] and messages[1].role == "tool" do
                table.remove(messages, 1)
                removed = removed + 1
              end
            end
          end
          if removed > 0 then
            vim.notify(
              string.format("[Wellm] Context window exceeded (retry %d/%d) — auto-truncated %d oldest messages, retrying...",
                ctx_retry_count, CTX_MAX_RETRIES, removed),
              vim.log.levels.WARN
            )
            require("wellm.ui.spinner").set_status("Retrying with truncated context...")
            round_response = ""
            start_conversation(messages, sys, tool_round)
            return
          else
            err_msg = "Context window exceeded — even minimal context is too large. "
              .. "Try reducing context files, using a model with a larger context window, or starting a new session."
          end
        elseif is_ctx_exceeded then
          err_msg = "Context window exceeded after " .. CTX_MAX_RETRIES .. " auto-retries. "
            .. "Try reducing context files, using a model with a larger context window, or starting a new session."
        end

        -- Save session even on error so no conversation data is lost
        local last_msg = sess.messages[#sess.messages]
        if last_msg and last_msg.role == "assistant" then
          last_msg.content = full_assistant_response ~= "" and full_assistant_response or "[Error: " .. err_msg .. "]"
        end
        if cfg.sessions and cfg.sessions.save_automatically then
          session.auto_save()
        end
        require("wellm.ui.spinner").stop()
        vim.notify("API Error: " .. err_msg, vim.log.levels.ERROR)
        callback(nil)
        return
      end

      -- If there are tool calls and we haven't exceeded the limit
      if tc and #tc > 0 and tool_round < max_tool_rounds then
        -- Append assistant message with tool_calls
        local assistant_msg = {
          role = "assistant",
          content = content,
          tool_calls = {},
        }
        for _, call in ipairs(tc) do
          local args = call.func.arguments
          -- Ensure arguments is a JSON string for the API
          if type(args) == "table" then
            args = vim.json.encode(args)
          end
          table.insert(assistant_msg.tool_calls, {
            id = call.id,
            type = "function",
            ["function"] = {
              name = call.func.name,
              arguments = args,
            }
          })
        end
        table.insert(messages, assistant_msg)

        -- Determine confirmation behaviour
        local confirm_mode = cfg.filechanges or "filechanges_confirm"
        local confirm_cb = nil
        if confirm_mode == "filechanges_confirm" then
          confirm_cb = function(msg)
            return vim.fn.confirm(msg, "&Yes\n&No", 2) == 1
          end
        elseif confirm_mode == "filechanges_on" then
          confirm_cb = function() return true end
        else
          confirm_cb = function() return false end
        end

        -- Execute each tool call and append tool_result
        for _, call in ipairs(tc) do
          local args = call.func.arguments
          if type(args) == "table" then
            args = vim.json.encode(args)
          end
          if type(args) == "string" then
            local ok, decoded = pcall(vim.json.decode, args)
            if ok then
              args = decoded
            else
              vim.notify("[Wellm] Failed to decode tool arguments: " .. tostring(args), vim.log.levels.WARN)
            end
          end

          local key = call.func.name .. ":" .. vim.json.encode(args)
          local result
          if executed_in_this_request[key] then
            duplicate_count = duplicate_count + 1
            if duplicate_count >= duplicate_tolerance then
              -- Tolerance exceeded: save session and stop
              result = "[ERROR: duplicate tool call tolerance exceeded. Stopping.]"
              vim.notify("[Wellm] Duplicate tool call tolerance (" .. duplicate_tolerance .. ") exceeded, stopping.", vim.log.levels.WARN)
              local last_msg = sess.messages[#sess.messages]
              if last_msg and last_msg.role == "assistant" then
                last_msg.content = full_assistant_response ~= "" and full_assistant_response or "[Stopped: duplicate tool call tolerance exceeded]"
              end
              if cfg.sessions and cfg.sessions.save_automatically then
                session.auto_save()
              end
              require("wellm.ui.spinner").stop()
              callback("Stopped due to duplicate tool call tolerance exceeded.")
              return
            else
              result = "[WARNING: duplicate tool call skipped (" .. duplicate_count .. "/" .. duplicate_tolerance .. "). Try a different approach.]"
              vim.notify("[Wellm] Duplicate tool call skipped (" .. duplicate_count .. "/" .. duplicate_tolerance .. "): " .. call.func.name, vim.log.levels.WARN)
            end
          else
            executed_in_this_request[key] = true
            result = require("wellm.tools").execute(call.func.name, args, confirm_cb)
          end

          table.insert(messages, {
            role = "tool",
            tool_call_id = call.id,
            content = result,
          })
        end

        require("wellm.ui.spinner").set_status("LLM processing tool results...")
        start_conversation(messages, sys, tool_round + 1)
        return
      end

      if tool_round >= max_tool_rounds then
        vim.notify("[Wellm] Max tool rounds reached (" .. max_tool_rounds .. "), stopping.", vim.log.levels.WARN)
      end

      -- Final answer: strip pre‑tool reasoning preamble
      local clean_response = clean_assistant_content(full_assistant_response, tool_round > 0)

      -- Update the placeholder assistant message (already added at stream start)
      local last_msg = sess.messages[#sess.messages]
      if last_msg and last_msg.role == "assistant" then
        last_msg.content = clean_response
      end
      sess:update_summary()   -- non‑blocking, cheap LLM call

      if cfg.sessions and cfg.sessions.save_automatically then
        session.auto_save()
      end

      require("wellm.ui.spinner").stop()
      callback(clean_response)   -- return cleaned content, not the raw accumulated one
    end, tool_defs)
  end

  local messages, sys = M.build_payload(user_text, mode, extra_file_ctx)

  -- Save user message to session immediately (preserves input if streaming crashes).
  -- This MUST happen after build_payload, since build_payload reads from the session
  -- and also appends the user text to the messages array for the LLM.
  sess:add_message("user", user_text)
  sess:update_user_intent(user_text)
  -- Add placeholder assistant message that will be updated during streaming
  sess:add_message("assistant", "")
  if cfg.sessions and cfg.sessions.save_automatically then
    session.auto_save()
  end

  require("wellm.ui.spinner").start("LLM thinking...")
  start_conversation(messages, sys, 0)
end

-- Buffered (non‑streaming) call – adapted for tools as well
function M.call(user_text, mode, callback, extra_file_ctx)
  local cfg = require("wellm").config
  if not cfg.api_key or cfg.api_key == "" then
    vim.notify("[Wellm] No API key", vim.log.levels.ERROR)
    callback("> [!] No API key")
    return
  end

  local sess = session.get_or_create()   -- ensures state.current_session exists

  wellagent.build_file_cache()

  local full_response = ""
  local tool_calls = {}
  local executed_calls = {}
  local duplicate_count = 0
  local duplicate_tolerance = (cfg.llm and cfg.llm.duplicate_tolerance) or 5

  local function attempt(messages, sys, tool_round)
    tool_round = tool_round or 0
    local max_tool_rounds = (cfg.llm and cfg.llm.max_tool_rounds) or 7
    local tool_defs = tools.get_tool_definitions(cfg.provider)

    M.raw_call(messages, sys, function(content, tc, used, err)
      if used then usage.record(cfg.model, used.input_tokens, used.output_tokens) end
      if err then
        -- Save session even on error
        local last_msg = sess.messages[#sess.messages]
        if last_msg and last_msg.role == "assistant" then
          last_msg.content = full_response ~= "" and full_response or "[Error: " .. tostring(err) .. "]"
        end
        if cfg.sessions and cfg.sessions.save_automatically then
          session.auto_save()
        end
        spinner.stop()
        callback("> [!] API Error: " .. tostring(err))
        return
      end
      if not content and (not tc or #tc == 0) then
        -- Save session even on empty response
        local last_msg = sess.messages[#sess.messages]
        if last_msg and last_msg.role == "assistant" then
          last_msg.content = "[Empty response]"
        end
        if cfg.sessions and cfg.sessions.save_automatically then
          session.auto_save()
        end
        spinner.stop()
        callback("> [!] Empty response")
        return
      end

      full_response = full_response .. (content or "")
      tool_calls = tc or {}

      if #tool_calls > 0 and tool_round < max_tool_rounds then
        local assistant_msg = {
            role = "assistant",
            content = content,
            tool_calls = {},
        }

        for _, call in ipairs(tc) do
            local args = call.func.arguments
            if type(args) == "table" then
              args = vim.json.encode(args)
            end
            table.insert(assistant_msg.tool_calls, {
                id = call.id,
                type = "function",
                ["function"] = {
                    name = call.func.name,
                    arguments = args,
                }
            })
        end
        table.insert(messages, assistant_msg)

        local confirm_mode = cfg.filechanges or "filechanges_confirm"
        local confirm_cb = nil
        if confirm_mode == "filechanges_confirm" then
          confirm_cb = function(msg) return vim.fn.confirm(msg, "&Yes\n&No", 2) == 1 end
        elseif confirm_mode == "filechanges_on" then
          confirm_cb = function() return true end
        else
          confirm_cb = function() return false end
        end

        for _, call in ipairs(tool_calls) do
          local args = call.func.arguments
          if type(args) == "string" then
            local ok, decoded = pcall(vim.json.decode, args)
            if ok then
              args = decoded
            else
              -- Malformed JSON – pass the raw string so the tool can report the error
              vim.notify("[Wellm] Failed to decode tool arguments: " .. tostring(args), vim.log.levels.WARN)
            end
          end

          local result
          local is_dup, _ = check_duplicate_tool_call(call, executed_calls)
          if is_dup then
            duplicate_count = duplicate_count + 1
            if duplicate_count >= duplicate_tolerance then
              result = "[ERROR: duplicate tool call tolerance exceeded. Stopping.]"
              vim.notify("[Wellm] Duplicate tool call tolerance (" .. duplicate_tolerance .. ") exceeded, stopping.", vim.log.levels.WARN)
            else
              result = "[WARNING: duplicate tool call skipped (" .. duplicate_count .. "/" .. duplicate_tolerance .. "). Try a different approach.]"
              vim.notify("[Wellm] Duplicate tool call skipped (" .. duplicate_count .. "/" .. duplicate_tolerance .. "): " .. call.func.name, vim.log.levels.WARN)
            end
          else
            result = tools.execute(call.func.name, args, confirm_cb)
          end

          table.insert(messages, { role = "tool", tool_call_id = call.id, content = result })
        end

        -- Stop further rounds if duplicate tolerance exceeded
        if duplicate_count >= duplicate_tolerance then
          -- Fall through to final answer handling (which saves the session)
        else
          attempt(messages, sys, tool_round + 1)
          return
        end
      end

      -- No tool calls or max rounds reached
      if mode == "replace" or mode == "insert" then
        full_response = full_response:gsub("^```%w*\n", ""):gsub("\n```$", "")
      end

      local had_tools = tool_round > 0
      local clean_response = clean_assistant_content(full_response, had_tools)

      -- Update the placeholder assistant message (already added at call start)
      local last_msg = sess.messages[#sess.messages]
      if last_msg and last_msg.role == "assistant" then
        last_msg.content = clean_response
      end
      sess:update_summary()   -- non‑blocking, cheap LLM call

      if cfg.sessions and cfg.sessions.save_automatically then
        session.auto_save()
      end

      spinner.stop()
      callback(full_response)
    end, tool_defs)
  end

  local messages, sys = M.build_payload(user_text, mode, extra_file_ctx)

  -- Save user message to session immediately (preserves input if call crashes).
  -- This MUST happen after build_payload for the same reason as in call_stream.
  sess:add_message("user", user_text)
  sess:update_user_intent(user_text)
  sess:add_message("assistant", "")
  if cfg.sessions and cfg.sessions.save_automatically then
    session.auto_save()
  end

  spinner.start("LLM thinking...")
  attempt(messages, sys, 0)
end

-- Orient command unchanged
function M.orient(on_done)
  local cfg = require("wellm").config
  local proj_root = wellagent.get_project_root()
  local ignored = cfg.wellagent and cfg.wellagent.ignored_patterns or {}
  local tree = wellagent.generate_tree(proj_root, ignored)
  local prompt = cfg.prompts.orient .. "\n\n## File Tree\n```\n" .. proj_root .. "\n" .. tree .. "\n```"
  local msgs = {{ role = "user", content = prompt }}
  local sys = "You produce concise, accurate developer documentation. Output only valid Markdown."

  spinner.start("Orienting...")
  M.raw_call(msgs, sys, function(content, tool_calls, used, err)
    if used then usage.record(cfg.model, used.input_tokens, used.output_tokens) end
    if err or not content then
      spinner.stop()
      vim.notify("Orient failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    local overview = content:match("## OVERVIEW\n(.-)\n## STRUCTURE") or content
    local structure = content:match("## STRUCTURE\n(.+)$") or tree

    wellagent.write_context("OVERVIEW.md",  vim.trim(overview))
    wellagent.write_context("STRUCTURE.md", vim.trim(structure))

    wellagent.refresh_structure()
    spinner.stop("Project oriented.")
    if on_done then on_done() end
  end, nil)
end

return M
