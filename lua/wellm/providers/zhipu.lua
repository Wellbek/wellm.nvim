-- wellm/providers/zhipu.lua
local M = {}

function M.build_request(cfg, messages, system_prompt)
  local msgs = vim.deepcopy(messages)
  table.insert(msgs, 1, { role = "system", content = system_prompt })

  return {
    url = "https://open.bigmodel.cn/api/paas/v4/chat/completions",
    headers = {
      "-H", "Authorization: Bearer " .. cfg.api_key,
      "-H", "content-type: application/json",
    },
    body = vim.fn.json_encode({
      model      = cfg.model,
      messages   = msgs,
      max_tokens = cfg.max_tokens,
    }),
  }
end

-- Streaming variant: identical but with stream = true in body
function M.build_stream_request(cfg, messages, system_prompt)
  local req  = M.build_request(cfg, messages, system_prompt)
  local body = vim.fn.json_decode(req.body)
  body.stream = true
  req.body    = vim.fn.json_encode(body)
  return req
end

--- Parse one SSE line from Zhipu's OpenAI-compatible event stream.
--- Returns: delta_text (string|nil), usage (table|nil), is_done (bool)
function M.parse_stream_line(line)
  local data = line:match("^data:%s*(.+)$")
  if not data then return nil, nil, false end
  if data == "[DONE]" then return nil, nil, true end

  local ok, dec = pcall(vim.fn.json_decode, data)
  if not ok then return nil, nil, false end

  local delta_text = nil
  if dec.choices and dec.choices[1] and dec.choices[1].delta then
    delta_text = dec.choices[1].delta.content
  end

  local usage_data = nil
  if dec.usage then
    usage_data = {
      input_tokens  = dec.usage.prompt_tokens     or 0,
      output_tokens = dec.usage.completion_tokens or 0,
    }
  end

  -- finish_reason == "stop" signals the last chunk
  local is_done = (dec.choices
    and dec.choices[1]
    and dec.choices[1].finish_reason == "stop") or false

  return delta_text, usage_data, is_done
end

function M.parse_response(decoded)
  local content = ""
  local usage = {
    input_tokens  = 0,
    output_tokens = 0,
    total_tokens  = 0,
  }

  if decoded.choices and decoded.choices[1] then
    content = decoded.choices[1].message.content or ""
  end
  if decoded.usage then
    usage.input_tokens  = decoded.usage.prompt_tokens     or 0
    usage.output_tokens = decoded.usage.completion_tokens or 0
    usage.total_tokens  = decoded.usage.total_tokens      or 0

    if decoded.usage.prompt_tokens_details then
      usage.cached_tokens = decoded.usage.prompt_tokens_details.cached_tokens or 0
    end
  end
  if decoded.error then
    return nil, usage, decoded.error.message or "Unknown API error"
  end

  return content, usage, nil
end

return M
