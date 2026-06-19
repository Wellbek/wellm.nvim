-- wellm/providers/anthropic.lua
local M = {}

function M.build_request(cfg, messages, system_prompt, tool_defs, force_tool)
  -- Wrap system prompt as an array of content blocks with cache control.
  -- Anthropic's prompt caching reduces cost by ~90% for repeated prefixes
  -- (system prompt + early context). The cache_control breakpoint tells
  -- Anthropic to cache everything up to and including this block.
  local system_blocks = {
    {
      type = "text",
      text = system_prompt,
      cache_control = { type = "ephemeral" },
    }
  }

  local body = {
    model      = cfg.model,
    system     = system_blocks,
    messages   = messages,
    max_tokens = cfg.max_tokens,
  }
  if tool_defs and #tool_defs > 0 then
    -- Add cache control to the last tool definition so tool definitions
    -- are included in the cached prefix
    local cached_tools = vim.deepcopy(tool_defs)
    if #cached_tools > 0 then
      cached_tools[#cached_tools].cache_control = { type = "ephemeral" }
    end
    body.tools = cached_tools
    -- force_tool=true means "this turn must use a tool" — Anthropic's
    -- {type="any"} forces a tool_use block instead of allowing plain text.
    -- Used on the first round of a fresh chat task to stop the model from
    -- responding with only deliberation/analysis and never acting.
    if force_tool then
      body.tool_choice = { type = "any" }
    else
      body.tool_choice = { type = "auto" }
    end
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

function M.build_stream_request(cfg, messages, system_prompt, tool_defs, force_tool)
  local req  = M.build_request(cfg, messages, system_prompt, tool_defs, force_tool)
  local body = vim.fn.json_decode(req.body)
  body.stream = true
  req.body    = vim.fn.json_encode(body)
  return req
end

function M.parse_stream_line(line)
  local data = line:match("^data:%s*(.+)$")
  if not data then return nil, nil, nil, false, nil end
  if data == "[DONE]" then return nil, nil, nil, true, nil end

  local ok, dec = pcall(vim.fn.json_decode, data)
  if not ok then return nil, nil, nil, false, nil end

  if dec.type == "content_block_delta"
      and dec.delta
      and dec.delta.type == "text_delta" then
    return dec.delta.text, nil, nil, false, nil
  end

  if dec.type == "content_block_start"
      and dec.content_block
      and dec.content_block.type == "tool_use" then
    -- Emit a tool call fragment with id and name (arguments come in delta chunks)
    local args = dec.content_block.input
    if type(args) == "table" then
      args = vim.json.encode(args)
    elseif args == nil then
      args = ""
    end
    return nil, {{
      id = dec.content_block.id,
      type = "function",
      func = {
        name = dec.content_block.name or "",
        arguments = args,
      }
    }}, nil, false, nil
  end

  if dec.type == "content_block_delta"
      and dec.delta
      and dec.delta.type == "input_json_delta" then
    -- Partial arguments for a tool call (same index as the content_block_start)
    local partial = dec.delta.partial_json or ""
    return nil, {{
      id = nil,  -- no id in delta chunks; llm.lua will accumulate by index
      type = "function",
      func = {
        name = "",
        arguments = partial,
      }
    }}, nil, false, nil
  end

  if dec.type == "message_delta" and dec.usage then
    return nil, nil, { output_tokens = dec.usage.output_tokens or 0 }, false, nil
  end

  if dec.type == "message_start" and dec.message and dec.message.usage then
    return nil, nil, { input_tokens = dec.message.usage.input_tokens or 0 }, false, nil
  end

  if dec.type == "message_stop" then
    return nil, nil, nil, true, nil
  end

  return nil, nil, nil, false, nil
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
      -- Anthropic returns input as a parsed table; normalize to JSON string
      -- so downstream code (llm.lua) has a consistent format.
      local args = block.input
      if type(args) == "table" then
        args = vim.json.encode(args)
      elseif args == nil then
        args = ""
      end
      call["func"] = {
        name = block.name,
        arguments = args,
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
