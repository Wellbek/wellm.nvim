-- wellm/providers/anthropic.lua
local M = {}

function M.build_request(cfg, messages, system_prompt, tool_defs)
  local body = {
    model      = cfg.model,
    system     = system_prompt,
    messages   = messages,
    max_tokens = cfg.max_tokens,
  }
  if tool_defs and #tool_defs > 0 then
    body.tools = tool_defs
    body.tool_choice = { type = "auto" }
  end
  return {
    url = "https://api.anthropic.com/v1/messages",
    headers = {
      "-H", "x-api-key: " .. cfg.api_key,
      "-H", "anthropic-version: 2023-06-01",
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

  if dec.type == "content_block_delta"
      and dec.delta
      and dec.delta.type == "text_delta" then
    return dec.delta.text, nil, nil, false
  end

  if dec.type == "content_block_start"
      and dec.content_block
      and dec.content_block.type == "tool_use" then
    return nil, nil, nil, false
  end

  if dec.type == "message_delta" and dec.usage then
    return nil, nil, { output_tokens = dec.usage.output_tokens or 0 }, false
  end

  if dec.type == "message_start" and dec.message and dec.message.usage then
    return nil, nil, { input_tokens = dec.message.usage.input_tokens or 0 }, false
  end

  if dec.type == "message_stop" then
    return nil, nil, nil, true
  end

  return nil, nil, nil, false
end

function M.parse_response(decoded)
  if decoded.error then
    return nil, nil, nil, decoded.error.message or "Unknown API error"
  end

  local content = ""
  local tool_calls = {}
  for _, block in ipairs(decoded.content or {}) do
    if block.type == "text" then
      content = content .. block.text
    elseif block.type == "tool_use" then
      local call = {
        id = block.id,
        type = "function",
      }
      call["func"] = {
        name = block.name,
        arguments = block.input,
      }
      table.insert(tool_calls, call)
    end
  end

  local usage = nil
  if decoded.usage then
    usage = {
      input_tokens  = decoded.usage.input_tokens or 0,
      output_tokens = decoded.usage.output_tokens or 0,
    }
  end

  return content, tool_calls, usage, nil
end

return M