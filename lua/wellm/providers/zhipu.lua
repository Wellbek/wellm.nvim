-- wellm/providers/zhipu.lua
local M = {}

function M.build_request(cfg, messages, system_prompt, tool_defs)
  local msgs = vim.deepcopy(messages)
  table.insert(msgs, 1, { role = "system", content = system_prompt })

  local body = {
    model      = cfg.model,
    messages   = msgs,
    max_tokens = cfg.max_tokens,
  }
  if tool_defs and #tool_defs > 0 then
    body.tools = tool_defs
    body.tool_choice = "auto"
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

function M.build_stream_request(cfg, messages, system_prompt, tool_defs)
  local req  = M.build_request(cfg, messages, system_prompt, tool_defs)
  local body = vim.fn.json_decode(req.body)
  body.stream = true
  req.body    = vim.fn.json_encode(body)
  return req
end

function M.parse_stream_line(line)
  local data = line:match("^data:%s*(.+)$")
  if not data then return nil, nil, nil, false end
  if data == "[DONE]" then return nil, nil, nil, true end

  local ok, dec = pcall(vim.fn.json_decode, data)
  if not ok then return nil, nil, nil, false end

  local delta_text = nil
  local is_done = false

  if dec.choices and dec.choices[1] then
    local delta = dec.choices[1].delta
    if delta then
      -- GLM models may send reasoning_content first, then content.
      -- We prioritize content if present, otherwise take reasoning_content.
      if delta.content then
        delta_text = delta.content
      elseif delta.reasoning_content then
        delta_text = delta.reasoning_content
      end
    end
    if dec.choices[1].finish_reason == "stop" then
      is_done = true
    end
  end

  local usage_data = nil
  if dec.usage then
    usage_data = {
      input_tokens  = dec.usage.prompt_tokens     or 0,
      output_tokens = dec.usage.completion_tokens or 0,
    }
  end

  return delta_text, nil, usage_data, is_done
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
          local call = {
            id = tc.id,
            type = "function",
          }
          call["func"] = {
            name = tc["function"].name,
            arguments = tc["function"].arguments,
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