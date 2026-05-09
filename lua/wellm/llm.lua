-- wellm/llm.lua
-- Central LLM call with:
--   tiered context injection (wellagent ctx -> selected files -> user msg)
--   auto [READ: path] tool loop
--   usage recording
--   session auto-save
local M = {}

local state     = require("wellm.state")
local providers = require("wellm.providers")
local context   = require("wellm.context")
local wellagent = require("wellm.wellagent")
local usage     = require("wellm.usage")
local session   = require("wellm.session")
local spinner   = require("wellm.ui.spinner")

-- Payload builder

--- Build the messages array and system prompt for the API call.
--- mode: "replace" | "insert" | "chat" | "orient"
function M.build_payload(user_text, mode, extra_file_ctx)
  local cfg = require("wellm").config

  -- System prompt
  local sys = state.data.system_override
    or (mode == "chat" and cfg.prompts.chat)
    or cfg.prompts.coding

  -- Prepend .wellagent project context to system prompt
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
  if ctx_block then
    table.insert(parts, ctx_block)
  end

  if extra_file_ctx then
    table.insert(parts, "## Current File\n```\n" .. extra_file_ctx .. "\n```")
  end

  table.insert(messages, {
    role    = "user",
    content = table.concat(parts, "\n\n"),
  })

  return messages, sys
end

-- READ loop

--- Valid path: starts with a letter, contains only path-safe chars,
--- has at least one directory separator, and looks like a real file.
local function looks_like_real_path(s)
  s = vim.trim(s)
  if s == "" then return false end
  -- Must start with a letter or underscore (no regex chars, no dots, no angle brackets)
  if not s:match("^[%a_]") then return false end
  -- Must contain only path-safe characters
  if s:match("[%^%$%(%)%%{%}%[%]%*%+%?<>|]") then return false end
  -- Must have at least one path separator (reject bare filenames and single-segment placeholders)
  -- unless it's a common dotfile like .gitignore
  if not s:match("/") and not s:match("^%.%a") then return false end
  -- Must have a file extension or be a directory with multiple segments
  if not s:match("%.%a") and not s:match("/%a") then return false end
  -- Reject obvious placeholders
  local lower = s:lower()
  for _, word in ipairs({ "example", "placeholder", "your", "path", "similar", "etc", "foo", "bar", "todo" }) do
    if lower:match(word) then return false end
  end
  return true
end

--- Remove markdown code fences from text so tool-call markers
--- inside examples/documentation are never extracted.
local function strip_code_fences(text)
  -- Remove fenced code blocks (``` ... ```)
  return text:gsub("```.-```", "")
end

local function extract_reads(text)
  local reads = {}
  local seen = {}
  -- ONLY match lines where the marker starts at position 1
  -- This prevents matches inside code blocks, prose, examples, etc.
  for line in text:gmatch("[^\n]+") do
    local trimmed = line:match("^%s*%[READ:%s*([^%]]+)%]%s*$")
    if trimmed then
      trimmed = vim.trim(trimmed)
      if looks_like_real_path(trimmed) and not seen[trimmed] then
        seen[trimmed] = true
        local proj = wellagent.get_project_root()
        local full = (trimmed:sub(1, 1) == "/") and trimmed or (proj .. "/" .. trimmed)
        if vim.fn.filereadable(full) == 1 then
          table.insert(reads, full)
        else
          vim.notify("[Wellm] File not found: " .. trimmed, vim.log.levels.WARN)
        end
      end
    end
  end
  return reads
end

local function inject_read_files(reads)
  local injected = 0
  for _, path in ipairs(reads) do
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok then
      context.inject_raw(path, table.concat(lines, "\n"))
      injected = injected + 1
    end
  end
  return injected
end

-- Raw curl call

--- Fire a single API call. On completion, calls cb(content, usage_data, err).
function M.raw_call(messages, sys, cb)
  local cfg      = require("wellm").config
  local provider = require("wellm.providers").get(cfg.provider)
  local req      = provider.build_request(cfg, messages, sys)

  -- Write body to tempfile to avoid shell-escaping issues
  local tmp = os.tmpname()
  local f   = io.open(tmp, "w")
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
        vim.schedule(function()
          cb(nil, nil, "curl exited with code " .. code)
        end)
        return
      end

      local raw = table.concat(chunks, "")
      local ok, decoded = pcall(vim.fn.json_decode, raw)

      vim.schedule(function()
        if not ok then
          cb(nil, nil, "JSON decode failed: " .. raw:sub(1, 200))
          return
        end
        local content, used, err = provider.parse_response(decoded)
        cb(content, used, err)
      end)
    end,
  })
end

-- Public call (with READ loop)

--- Call the LLM for a given mode, with optional extra file context.
--- callback(response_text) is called on success.
function M.call(user_text, mode, callback, extra_file_ctx)
  local cfg = require("wellm").config

  if not cfg.api_key or cfg.api_key == "" then
    local err_msg = "[Wellm] No API key configured."
    vim.notify(err_msg, vim.log.levels.ERROR)
    callback("> [!] " .. err_msg)
    return
  end

  local messages, sys = M.build_payload(user_text, mode, extra_file_ctx)
  local max_reads     = 3    -- prevent infinite loops
  local read_count    = 0

  local function attempt(msgs, s)
    M.raw_call(msgs, s, function(content, used, err)
      -- Record usage regardless of error status 
      if used then
        usage.record(cfg.model, used.input_tokens, used.output_tokens)
      end
      
      if err then
        spinner.stop()
        local ui_err = "> [!] API Error: " .. tostring(err)
        vim.notify(ui_err, vim.log.levels.ERROR)
        callback(ui_err)
        return
      end
      if not content or content == "" then
        spinner.stop()
        local ui_err = "> [!] Empty response from AI."
        vim.notify(ui_err, vim.log.levels.WARN)
        callback(ui_err)
        return
      end

      -- Record usage
      if used then
        usage.record(cfg.model, used.input_tokens, used.output_tokens)
      end

      wellagent.extract_decisions(content)

      local cleaned = strip_code_fences(content)
      local reads = extract_reads(cleaned)
      if #reads > 0 and read_count < max_reads then
        spinner.set_status("reading files...")
        local injected = inject_read_files(reads)
        read_count = read_count + injected

        table.insert(msgs, { role = "assistant", content = content })
        table.insert(msgs, { role = "user", content = "Files loaded. Continue with your full answer." })

        local _, new_sys = M.build_payload("", mode, nil)
        spinner.set_status("LLM thinking...")
        attempt(msgs, new_sys)
        return
      end

      -- Clean code-only responses
      if mode == "replace" or mode == "insert" then
        content = content
          :gsub("^```%w*\n", "")
          :gsub("\n```$", "")
      end

      table.insert(state.data.history, { role = "user",      content = user_text })
      table.insert(state.data.history, { role = "assistant", content = content })

      if cfg.sessions and cfg.sessions.save_automatically then
        session.auto_save()
      end

      spinner.stop()
      callback(content)
    end)
  end

  spinner.start("LLM thinking...")
  attempt(messages, sys)
end

-- Orient call

--- One-shot call to generate OVERVIEW.md + STRUCTURE.md for a project.
function M.orient(on_done)
  local cfg        = require("wellm").config
  local proj_root  = wellagent.get_project_root()
  local ignored    = cfg.wellagent and cfg.wellagent.ignored_patterns or {}
  local tree       = wellagent.generate_tree(proj_root, ignored)

  local prompt = cfg.prompts.orient
    .. "\n\n## File Tree\n```\n" .. proj_root .. "\n" .. tree .. "\n```"

  local msgs = {{ role = "user", content = prompt }}
  local sys  = "You produce concise, accurate developer documentation. Output only valid Markdown."

  spinner.start("Orienting project...")

  M.raw_call(msgs, sys, function(content, used, err)
    -- Record usage regardless of error status 
    if used then
      usage.record(cfg.model, used.input_tokens, used.output_tokens)
    end

    if err or not content or content == "" then
      spinner.stop()
      vim.notify("[Wellm] Orient failed: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if used then usage.record(cfg.model, used.input_tokens, used.output_tokens) end

    -- Split OVERVIEW / STRUCTURE sections
    local overview  = content:match("## OVERVIEW\n(.-)\n## STRUCTURE") or content
    local structure = content:match("## STRUCTURE\n(.+)$") or tree

    wellagent.write_context("OVERVIEW.md",  vim.trim(overview))
    wellagent.write_context("STRUCTURE.md", vim.trim(structure))

    spinner.stop("[Wellm] Project oriented. OVERVIEW.md + STRUCTURE.md written.")
    if on_done then on_done() end
  end)
end

return M
