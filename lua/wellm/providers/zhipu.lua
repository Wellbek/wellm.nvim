-- wellm/providers/zhipu.lua
local M = {}

function M.build_request(cfg, messages, system_prompt, tool_defs, force_tool)
  local msgs = vim.deepcopy(messages)
  table.insert(msgs, 1, { role = "system", content = system_prompt })

  local body = {
    model      = cfg.model,
    messages   = msgs,
    max_tokens = cfg.max_tokens,
  }
  if tool_defs and #tool_defs > 0 then
    body.tools = tool_defs
    -- force_tool=true forces a function call this turn instead of allowing
    -- plain text — OpenAI-compatible APIs (Zhipu/GLM included) use the
    -- string "required" for this, vs Anthropic's {type="any"} object.
    -- Used on the first round of a fresh chat task so the model can't just
    -- keep deliberating in text without ever acting.
    body.tool_choice = force_tool and "required" or "auto"
  end

  --- vim.notify(vim.fn.json_encode(body))

  return {
    url = "https://open.bigmodel.cn/api/paas/v4/chat/completions",
    headers = {
      "-H", "Authorization: Bearer " .. cfg.api_key,
      "-H", "content-type: application/json",
    },
    body = vim.fn.json_encode(body),
  }
end

function M.build_stream_request(cfg, messages, system_prompt, tool_defs, force_tool)
  local req  = M.build_request(cfg, messages, system_prompt, tool_defs, force_tool)
  local body = vim.fn.json_decode(req.body)
  body.stream = true
  req.body    = vim.fn.json_encode(body)
  -- local f = io.open("/tmp/zhipu_request.json", "w")
  -- if f then
  --   f:write(req.body)
  --   f:close()
  -- end
  return req
end

function M.parse_stream_line(line)
  local data = line:match("^data:%s*(.+)$")
  if not data then
    return nil, nil, nil, false
  end

  if data == "[DONE]" then
    return nil, nil, nil, true
  end

  local ok, dec = pcall(vim.fn.json_decode, data)
  if not ok then
    return nil, nil, nil, false
  end

  -- Detect error responses returned as SSE data events.
  -- Zhipu sometimes wraps errors inside the stream rather than using HTTP
  -- status codes, so we must check here in addition to the on_exit fallback.
  if dec.error then
    local msg = dec.error.message or "API error"
    if dec.error.code then
      msg = msg .. " (code: " .. tostring(dec.error.code) .. ")"
    end
    return nil, nil, nil, true, msg
  end

  local delta_text = nil
  local tool_calls = nil
  local usage_data = nil
  local is_done = false

  if dec.choices and dec.choices[1] then
    local choice = dec.choices[1]
    local delta = choice.delta

    if delta then
      delta_text = delta.content or delta.reasoning_content

      if delta.tool_calls then
        tool_calls = {}

        for _, tc in ipairs(delta.tool_calls) do
          local args = tc["function"] and tc["function"].arguments
          -- Normalize: arguments MUST be a string for OpenAI‑compatible APIs.
          -- Some models (e.g. GLM 5.1) return arguments as a JSON object.
          if type(args) == "table" then
            args = vim.json.encode(args)
          elseif args == nil then
            args = ""
          end
          table.insert(tool_calls, {
            id = tc.id,
            index = tc.index,
            type = "function",
            func = {
              name = tc["function"] and tc["function"].name or "",
              arguments = args,
            }
          })
        end
      end
    end

    local finish_reason = choice.finish_reason

    if finish_reason == "stop"
      or finish_reason == "tool_calls"
    then
      is_done = true
    elseif finish_reason == "model_context_window_exceeded" then
      is_done = true
      -- Propagate as error so callers can react
      return nil, nil, usage_data, true, "model_context_window_exceeded"
    end
  end

  if dec.usage then
    usage_data = {
      input_tokens = dec.usage.prompt_tokens or 0,
      output_tokens = dec.usage.completion_tokens or 0,
    }
  end

  return delta_text, tool_calls, usage_data, is_done, nil
end

function M.parse_response(decoded)
  if decoded.error then
    return nil, nil, nil, decoded.error.message or "Unknown API error"
  end

  local content = ""
  local tool_calls = {}
  local usage = {
    input_tokens  = 0,
    output_tokens = 0,
  }

  if decoded.choices and decoded.choices[1] then
    local message = decoded.choices[1].message
    if message then
      content = message.content or message.reasoning_content or ""
      if message.tool_calls then
        for _, tc in ipairs(message.tool_calls) do
          local args = tc["function"] and tc["function"].arguments
          -- Normalize: arguments MUST be a string for OpenAI‑compatible APIs.
          if type(args) == "table" then
            args = vim.json.encode(args)
          elseif args == nil then
            args = ""
          end
          local call = {
            id = tc.id,
            type = "function",
          }
          call["func"] = {
            name = tc["function"] and tc["function"].name or "",
            arguments = args,
          }
          table.insert(tool_calls, call)
        end
      end
    end
  end

  if decoded.usage then
    usage.input_tokens  = decoded.usage.prompt_tokens     or 0
    usage.output_tokens = decoded.usage.completion_tokens or 0
  end

  return content, tool_calls, usage, nil
end

return M
