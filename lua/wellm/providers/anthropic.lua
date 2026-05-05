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
