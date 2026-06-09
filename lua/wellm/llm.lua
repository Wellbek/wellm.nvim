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

-- Token estimation heuristic
function M.estimate_tokens(messages)
  local total = 0
  for _, msg in ipairs(messages) do
    total = total + math.ceil((msg.content and #msg.content or 0) / 3.5) + 5
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
  local context_window = cfg.context_window or 200000  -- most models support >=200k tokens
  local reserve = (cfg.llm and cfg.llm.output_reserve) or 1024
  local sys_tokens = M.estimate_tokens({{role="system", content=sys}})
  local total_tokens = M.estimate_tokens(messages) + sys_tokens
  local soft_limit = context_window - reserve

  if total_tokens > soft_limit then
    vim.notify(string.format("[Wellm] Context too large (%d tokens, limit %d), truncating oldest messages...",
                total_tokens, soft_limit), vim.log.levels.WARN)
    while #messages > 1 and total_tokens > soft_limit do
      table.remove(messages, 1)
      total_tokens = M.estimate_tokens(messages) + sys_tokens
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

-- Duplicate tool-call detection: returns true if the exact same (name, args)
-- pair has already been executed this session. Catches the model looping on
-- read_file / edit_file with identical arguments.
local function is_duplicate_tool_call(call, executed)
  local key = call.func.name .. ":" .. vim.json.encode(call.func.arguments)
  if executed[key] then return true end
  executed[key] = true
  return false
end

-- Raw non‑streaming call with tool definitions
function M.raw_call(messages, sys, cb, tool_defs)
  local cfg = require("wellm").config
  local provider = require("wellm.providers").get(cfg.provider)
  local req = provider.build_request(cfg, messages, sys, tool_defs)

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
        vim.schedule(function() cb(nil, nil, nil, "curl exit " .. code) end)
        return
      end
      local raw = table.concat(chunks, "")
      local ok, decoded = pcall(vim.fn.json_decode, raw)
      vim.schedule(function()
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

-- Raw streaming call with tool definitions
function M.raw_stream(messages, sys, on_delta, on_done, tool_defs)
  local cfg = require("wellm").config
  local provider = require("wellm.providers").get(cfg.provider)

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

  local curl_cmd = { "curl", "-s", "-N", "-X", "POST", req.url }
  for _, h in ipairs(req.headers) do table.insert(curl_cmd, h) end
  table.insert(curl_cmd, "-d")
  table.insert(curl_cmd, "@" .. tmp)

  local full_content = ""
  local tool_calls_by_id = {}   -- accumulate by id
  local usage_acc = { input_tokens = 0, output_tokens = 0 }
  local raw_lines = {}

  state.data.job_id = vim.fn.jobstart(curl_cmd, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(raw_lines, line)
          local delta, tc_fragments, used, is_done = provider.parse_stream_line(line)
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
              -- Append arguments chunk
              if frag.func and frag.func.arguments then
                tool_calls_by_id[call_id].func.arguments = tool_calls_by_id[call_id].func.arguments .. frag.func.arguments
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
        if code ~= 0 then
          on_done(nil, nil, nil, "curl exit " .. code)
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
            on_done(nil, nil, nil, decoded.error.message or "API error")
            return
          end
        end
        on_done(full_content, final_tool_calls, usage_acc, nil)
      end)
    end,
  })
end

-- wellm/llm.lua – streaming call with tool use
function M.call_stream(user_text, mode, on_delta, callback, extra_file_ctx)
  local cfg = require("wellm").config
  if not cfg.api_key or cfg.api_key == "" then
    vim.notify("[Wellm] No API key", vim.log.levels.ERROR)
    callback(nil)
    return
  end

  local session = require("wellm.session")
  local sess = session.get_or_create()   -- ensures state.current_session exists

  local wellagent = require("wellm.wellagent")
  wellagent.build_file_cache()

  -- Per-request duplicate tracker (cleared on each new user request)
  local executed_in_this_request = {}

  local full_assistant_response = ""
  local function acc_delta(delta)
    full_assistant_response = full_assistant_response .. delta
    on_delta(delta)
  end

  local state = require("wellm.state")
  local session = state.current_session

  local function start_conversation(messages, sys, tool_round)
    tool_round = tool_round or 0
    -- Use config value; fallback to 7
    local max_tool_rounds = (cfg.llm and cfg.llm.max_tool_rounds) or 7
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
        require("wellm.ui.spinner").stop()
        vim.notify("API Error: " .. tostring(err), vim.log.levels.ERROR)
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
          table.insert(assistant_msg.tool_calls, {
            id = call.id,
            type = "function",
            ["function"] = {
              name = call.func.name,
              arguments = call.func.arguments,
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
          if type(args) == "string" then
            args = vim.json.decode(args)
          end

          local key = call.func.name .. ":" .. vim.json.encode(args)
          local result
          if executed_in_this_request[key] then
            result = "[ERROR: duplicate tool call detected and skipped. Do not repeat the same tool call.]"
            vim.notify("[Wellm] Duplicate tool call skipped in same request: " .. call.func.name, vim.log.levels.WARN)
            -- Stop further rounds immediately to break the loop
            require("wellm.ui.spinner").stop()
            callback("Stopped due to duplicate tool call.")
            return
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

      -- Save to session (not directly to state.data.history)
      sess:add_message("user", user_text)
      sess:update_user_intent(user_text)

      sess:add_message("assistant", clean_response)
      sess:update_summary()   -- non‑blocking, cheap LLM call

      if cfg.sessions and cfg.sessions.save_automatically then
        session.auto_save()
      end

      require("wellm.ui.spinner").stop()
      callback(clean_response)   -- return cleaned content, not the raw accumulated one
    end, tool_defs)
  end

  local messages, sys = M.build_payload(user_text, mode, extra_file_ctx)
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

  local session = require("wellm.session")
  local sess = session.get_or_create()   -- ensures state.current_session exists

  wellagent.build_file_cache()

  local full_response = ""
  local tool_calls = {}
  local executed_calls = {}

  local function attempt(messages, sys, tool_round)
    tool_round = tool_round or 0
    local max_tool_rounds = (cfg.llm and cfg.llm.max_tool_rounds) or 7
    local tool_defs = tools.get_tool_definitions(cfg.provider)

    M.raw_call(messages, sys, function(content, tc, used, err)
      if used then usage.record(cfg.model, used.input_tokens, used.output_tokens) end
      if err then
        spinner.stop()
        callback("> [!] API Error: " .. tostring(err))
        return
      end
      if not content and (not tc or #tc == 0) then
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
            table.insert(assistant_msg.tool_calls, {
                id = call.id,
                type = "function",
                ["function"] = {
                    name = call.func.name,
                    arguments = call.func.arguments,
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
            args = vim.json.decode(args)
          end

          local result
          if is_duplicate_tool_call(call, executed_calls) then
            result = "[skipped: identical call already executed this turn]"
            vim.notify("[Wellm] Duplicate tool call skipped: " .. call.func.name, vim.log.levels.WARN)
          else
            result = tools.execute(call.func.name, args, confirm_cb)
          end

          table.insert(messages, { role = "tool", tool_call_id = call.id, content = result })
        end

        attempt(messages, sys, tool_round + 1)
        return
      end

      -- No tool calls or max rounds reached
      if mode == "replace" or mode == "insert" then
        full_response = full_response:gsub("^```%w*\n", ""):gsub("\n```$", "")
      end

      local had_tools = tool_round > 0
      local clean_response = clean_assistant_content(full_response, had_tools)

      -- Save to session (not directly to state.data.history)
      sess:add_message("user", user_text)
      sess:update_user_intent(user_text)

      sess:add_message("assistant", clean_response)
      sess:update_summary()   -- non‑blocking, cheap LLM call

      if cfg.sessions and cfg.sessions.save_automatically then
        session.auto_save()
      end

      spinner.stop()
      callback(full_response)
    end, tool_defs)
  end

  local messages, sys = M.build_payload(user_text, mode, extra_file_ctx)
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