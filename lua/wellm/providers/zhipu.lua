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
