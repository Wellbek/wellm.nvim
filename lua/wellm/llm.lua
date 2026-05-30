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

-- Payload builder (unchanged except no extra parsing)
function M.build_payload(user_text, mode, extra_file_ctx)
  local cfg = require("wellm").config

  -- System prompt
  local sys = state.data.system_override
    or (mode == "chat" and cfg.prompts.chat)
    or cfg.prompts.coding

  -- Append file-editing instructions – these are now largely replaced by tool definitions,
  -- but kept for compatibility with models that do not support tools.
  local filechanges = cfg.filechanges or "filechanges_confirm"
  if mode == "chat" and filechanges ~= "filechanges_off" and cfg.prompts.fileops then
    sys = sys .. "\n\n" .. cfg.prompts.fileops
  end

  -- Prepend .wellagent project context
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
    local lines = vim.split(extra_file_ctx, "\n")
    local numbered = {}
    for i, l in ipairs(lines) do
      numbered[i] = string.format("%4d: %s", i, l)
    end
    table.insert(parts, "## Current File (with line numbers)\n```\n" .. table.concat(numbered, "\n") .. "\n```")
  end

  table.insert(messages, {
    role    = "user",
    content = table.concat(parts, "\n\n"),
  })

  -- Token limit protection (prevent context overflow)
  local max_tokens = cfg.max_tokens or 8192
  local reserve = (cfg.llm and cfg.llm.output_reserve) or 1024
  local sys_tokens = M.estimate_tokens({{role="system", content=sys}})
  local total_tokens = M.estimate_tokens(messages) + sys_tokens
  local soft_limit = max_tokens - reserve

  if total_tokens > soft_limit then
    vim.notify("[Wellm] Context too large, truncating oldest messages...", vim.log.levels.WARN)
    while #messages > 2 and total_tokens > soft_limit do
      table.remove(messages, 2)
      total_tokens = M.estimate_tokens(messages) + sys_tokens
    end
  end

  return messages, sys
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
  local tool_calls = {}
  local usage_acc = { input_tokens = 0, output_tokens = 0 }
  local raw_lines = {}

  state.data.job_id = vim.fn.jobstart(curl_cmd, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then return end
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(raw_lines, line)
          local delta, tc, used, _ = provider.parse_stream_line(line)
          if delta and delta ~= "" then
            full_content = full_content .. delta
            vim.schedule(function() on_delta(delta) end)
          end
          if tc then
            for _, call in ipairs(tc) do
              tool_calls[#tool_calls+1] = call
            end
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
          on_done(nil, nil, nil, "curl exit " .. code)
          return
        end
        if full_content == "" and #tool_calls == 0 then
          local raw = table.concat(raw_lines, "")
          vim.notify("[Wellm] Empty response, raw (first 200 chars): " .. raw:sub(1,200), vim.log.levels.WARN)
          local ok, decoded = pcall(vim.fn.json_decode, raw)
          if ok and decoded.error then
            on_done(nil, nil, nil, decoded.error.message or "API error")
            return
          end
        end
        on_done(full_content, tool_calls, usage_acc, nil)
      end)
    end,
  })
end

-- Public streaming call with tool loop
function M.call_stream(user_text, mode, on_delta, callback, extra_file_ctx)
  local cfg = require("wellm").config
  if not cfg.api_key or cfg.api_key == "" then
    vim.notify("[Wellm] No API key", vim.log.levels.ERROR)
    callback(nil)
    return
  end

  wellagent.build_file_cache()

  -- Accumulate the full assistant response across potential multiple rounds
  local full_assistant_response = ""
  local current_round_response = ""
  local function acc_delta(delta)
    full_assistant_response = full_assistant_response .. delta
    current_round_response = current_round_response .. delta
    on_delta(delta)
  end

  local function start_conversation(messages, sys, tool_round)
    tool_round = tool_round or 0
    local max_tool_rounds = 10
    local tool_defs = tools.get_tool_definitions()

    M.raw_stream(messages, sys, acc_delta, function(content, tc, used, err)
      if used then usage.record(cfg.model, used.input_tokens, used.output_tokens) end
      if err then
        spinner.stop()
        vim.notify("API Error: " .. tostring(err), vim.log.levels.ERROR)
        callback(nil)
        return
      end

      -- If there are tool calls, execute them and continue
      if tc and #tc > 0 and tool_round < max_tool_rounds then
        -- Add assistant message containing tool_use
        local assistant_msg = { role = "assistant", content = content }
        assistant_msg.tool_calls = tc
        table.insert(messages, assistant_msg)

        -- Determine confirmation behaviour based on filechanges setting
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

        -- Execute each tool call and append tool_result messages
        for _, call in ipairs(tc) do
          -- Arguments may be a table or a JSON string; ensure table
          local args = call.func.arguments
          if type(args) == "string" then
            args = vim.json.decode(args)
          end
          local result = tools.execute(call.func.name, args, confirm_cb)
          table.insert(messages, {
            role = "tool",
            tool_call_id = call.id,
            content = result,
          })
        end

        -- Continue the conversation
        spinner.set_status("LLM processing tool results...")
        start_conversation(messages, sys, tool_round + 1)
        return
      end

      -- No tool calls: final answer. Save to history.
      local last_msg = state.data.history[#state.data.history]
      if not last_msg or last_msg.role ~= "user" or last_msg.content ~= user_text then
        table.insert(state.data.history, { role = "user", content = user_text })
      end
      table.insert(state.data.history, { role = "assistant", content = full_assistant_response })

      if cfg.sessions and cfg.sessions.save_automatically then
        session.auto_save()
      end

      spinner.stop()
      callback(current_round_response)
    end, tool_defs)
  end

  local messages, sys = M.build_payload(user_text, mode, extra_file_ctx)
  spinner.start("LLM thinking...")
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

  wellagent.build_file_cache()

  local full_response = ""
  local tool_calls = {}

  local function attempt(messages, sys, tool_round)
    tool_round = tool_round or 0
    local max_tool_rounds = 10
    local tool_defs = tools.get_tool_definitions()

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
        -- Add assistant message with tool calls
        local assistant_msg = { role = "assistant", content = content }
        assistant_msg.tool_calls = tool_calls
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
          local result = tools.execute(call.func.name, args, confirm_cb)
          table.insert(messages, { role = "tool", tool_call_id = call.id, content = result })
        end

        attempt(messages, sys, tool_round + 1)
        return
      end

      -- No tool calls or max rounds reached
      if mode == "replace" or mode == "insert" then
        full_response = full_response:gsub("^```%w*\n", ""):gsub("\n```$", "")
      end

      local last_msg = state.data.history[#state.data.history]
      if not last_msg or last_msg.role ~= "user" or last_msg.content ~= user_text then
        table.insert(state.data.history, { role = "user", content = user_text })
      end
      table.insert(state.data.history, { role = "assistant", content = full_response })
      if cfg.sessions and cfg.sessions.save_automatically then session.auto_save() end

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