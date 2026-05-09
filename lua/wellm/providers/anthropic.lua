-- wellm/providers/anthropic.lua
local M = {}

function M.build_request(cfg, messages, system_prompt)
  return {
    url = "https://api.anthropic.com/v1/messages",
    headers = {
      "-H", "x-api-key: " .. cfg.api_key,
      "-H", "anthropic-version: 2023-06-01",
      "-H", "content-type: application/json",
    },
    body = vim.fn.json_encode({
      model      = cfg.model,
      system     = system_prompt,
      messages   = messages,
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

--- Parse one SSE line from Anthropic's event stream.
--- Returns: delta_text (string|nil), usage (table|nil), is_done (bool)
function M.parse_stream_line(line)
  local data = line:match("^data:%s*(.+)$")
  if not data then return nil, nil, false end
  if data == "[DONE]" then return nil, nil, true end

  local ok, dec = pcall(vim.fn.json_decode, data)
  if not ok then return nil, nil, false end

  -- Text delta
  if dec.type == "content_block_delta"
      and dec.delta
      and dec.delta.type == "text_delta" then
    return dec.delta.text, nil, false
  end

  -- Output-token usage arrives in message_delta
  if dec.type == "message_delta" and dec.usage then
    return nil, { output_tokens = dec.usage.output_tokens or 0 }, false
  end

  -- Input-token usage arrives in message_start
  if dec.type == "message_start" and dec.message and dec.message.usage then
    return nil, { input_tokens = dec.message.usage.input_tokens or 0 }, false
  end

  -- message_stop signals end of stream
  if dec.type == "message_stop" then
    return nil, nil, true
  end

  return nil, nil, false
end

function M.parse_response(decoded)
  local content = ""
  local usage   = { input_tokens = 0, output_tokens = 0 }

  if decoded.content and decoded.content[1] then
    content = decoded.content[1].text or ""
  end
  if decoded.usage then
    usage.input_tokens  = decoded.usage.input_tokens  or 0
    usage.output_tokens = decoded.usage.output_tokens or 0
  end
  if decoded.error then
    return nil, usage, decoded.error.message or "Unknown API error"
  end

  return content, usage, nil
end

return M
