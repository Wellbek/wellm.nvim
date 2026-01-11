local M = {}

-- -------------------------------------------------------------------------------
-- STATE MANAGEMENT
-- -------------------------------------------------------------------------------
M.state = {
  history = {},          -- Conversation history
  context_files = {},    -- Map of file path -> content
  system_override = nil, -- Temporary system prompt override
  chat_buffer = nil,     -- Buffer ID for the chat window
  chat_win = nil,        -- Window ID for the chat window
}

-- -------------------------------------------------------------------------------
-- DEFAULT CONFIGURATION
-- -------------------------------------------------------------------------------
M.defaults = {
  -- Provider: "anthropic" (Claude) or "zhipu" (GLM)
  provider = "anthropic", 
  api_key_name = "ANTHROPIC_API_KEY", -- Name of the environment variable
  api_key = nil, -- Or set the API key directly here
  model = "claude-sonnet-4-5", -- Default model
  max_tokens = 8192,
  auto_open_chat = true, -- Open chat window automatically for non-replace actions
  
  -- Professional System Prompts
  prompts = {
    coding = [[You are an expert Senior Software Engineer and AI Assistant.
Your purpose is to write clean, maintainable, and secure code.

INSTRUCTIONS:
1. Adhere strictly to the user's requested output format (code block, markdown, or raw text).
2. If writing code, prioritize readability and existing project patterns.
3. Always handle edge cases and errors implicitly or explicitly as appropriate.
4. If asked to "Replace" or "Insert", output ONLY the code segment, no markdown wrappers, no explanations.
5. If asked to "Explain" or "Chat", use Markdown formatting and be verbose.
6. Analyze the provided Context Files to understand imports, types, and architectural patterns used in the project.]],
    
    chat = [[You are a helpful AI coding assistant integrated into Neovim.
You have access to the user's codebase context.
Answer concisely but provide code examples when helpful.]]
  },

  -- Default Keymaps (can be disabled with skip_default_mappings = true)
  keys = {
    -- Actions
    replace = { "<leader>cr", mode = "v", desc = "AI Replace Selection" },
    insert = { "<leader>cc", mode = "n", desc = "AI Insert at Cursor" },
    chat = { "<leader>ca", mode = "n", desc = "Open AI Chat" },
    
    -- Context Management
    add_file = { "<leader>caf", mode = "n", desc = "AI: Add File to Context" },
    add_folder = { "<leader>cad", mode = "n", desc = "AI: Add Folder to Context" },
    clear_context = { "<leader>cac", mode = "n", desc = "AI: Clear Context" },
  }
}

-- -------------------------------------------------------------------------------
-- SETUP
-- -------------------------------------------------------------------------------
function M.setup(opts)
  -- Merge options
  M.config = vim.tbl_deep_extend("force", M.defaults, opts or {})
  
  -- DEBUG: Print the resolved API Key (Masked for security)
  local key_preview = M.config.api_key and string.sub(M.config.api_key, 1, 5) .. "..." or "nil"
  print("[Wellm Debug] Setup started. API Key received: " .. key_preview)
  
  -- Resolve API Key
  if not M.config.api_key or M.config.api_key == "" then
    M.config.api_key = os.getenv(M.config.api_key_name)
    print("[Wellm Debug] No config key found. Checked env var. Result: " .. tostring(M.config.api_key ~= nil))
  end

  if not M.config.api_key then
    vim.notify("[Wellm] API Key not found. Check config.", vim.log.levels.WARN)
  end

  -- Load Keymaps
  if not M.config.skip_default_mappings then
    M.set_keymaps()
  end

  -- Load Commands
  M.set_commands()
  
  vim.notify("[Wellm] Plugin loaded successfully.", vim.log.levels.INFO)
end

function M.set_keymaps()
  local k = vim.keymap.set
  local opts = { noremap = true, silent = true }

  -- Core Actions
  k("v", M.config.keys.replace[1], function() M.action_replace() end, vim.tbl_extend("force", opts, { desc = M.config.keys.replace[3] }))
  k("n", M.config.keys.insert[1], function() M.action_insert() end, vim.tbl_extend("force", opts, { desc = M.config.keys.insert[3] }))
  k("n", M.config.keys.chat[1], function() M.open_chat() end, vim.tbl_extend("force", opts, { desc = M.config.keys.chat[3] }))

  -- Context
  k("n", M.config.keys.add_file[1], function() M.add_context_file() end, vim.tbl_extend("force", opts, { desc = M.config.keys.add_file[3] }))
  k("n", M.config.keys.add_folder[1], function() M.add_context_folder() end, vim.tbl_extend("force", opts, { desc = M.config.keys.add_folder[3] }))
  k("n", M.config.keys.clear_context[1], function() M.clear_context() end, vim.tbl_extend("force", opts, { desc = M.config.keys.clear_context[3] }))
end

function M.set_commands()
  -- Check if commands exist to avoid duplicates if reloaded manually
  if not vim.api.nvim_get_commands({})["WellmReplace"] then
    vim.api.nvim_create_user_command("WellmReplace", function() M.action_replace() end, { range = true })
    vim.api.nvim_create_user_command("WellmInsert", function() M.action_insert() end, {})
    vim.api.nvim_create_user_command("WellmChat", function() M.open_chat() end, {})
    vim.api.nvim_create_user_command("WellmAddFile", function() M.add_context_file() end, {})
    vim.api.nvim_create_user_command("WellmAddFolder", function() M.add_context_folder() end, {})
    vim.api.nvim_create_user_command("WellmSystem", function() M.edit_system_prompt() end, {})
  end
end

-- -------------------------------------------------------------------------------
-- CONTEXT MANAGEMENT
-- -------------------------------------------------------------------------------
function M.add_context_file(path)
  path = path or vim.fn.expand("%:p")
  if not path or path == "" then return end
  
  local content = table.concat(vim.fn.readfile(path), "\n")
  M.state.context_files[path] = content
  vim.notify(string.format("[Wellm] Added context: %s (%d lines)", path, #vim.fn.readfile(path)))
end

function M.add_context_folder(path)
  path = path or vim.fn.input("Folder path: ", vim.fn.expand("%:p:h"), "dir")
  local handle = vim.loop.fs_scandir(path)
  
  if not handle then return end
  
  local count = 0
  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then break end
    
    local full_path = path .. "/" .. name
    -- Filter simple text/code files (heuristic)
    if type == "file" and not name:match("%.git") and not name:match("%.lock") then
      M.add_context_file(full_path)
      count = count + 1
    end
  end
  vim.notify(string.format("[Wellm] Added %d files from folder to context.", count))
end

function M.clear_context()
  M.state.context_files = {}
  M.state.history = {}
  vim.notify("[Wellm] Context and History cleared.")
end

function M.edit_system_prompt()
  local current = M.state.system_override or M.config.prompts.coding
  vim.ui.input({ prompt = "System Prompt: ", default = current }, function(input)
    if input then
      M.state.system_override = input
      vim.notify("[Wellm] System prompt updated.")
    end
  end)
end

-- -------------------------------------------------------------------------------
-- UI & CHAT
-- -------------------------------------------------------------------------------
function M.open_chat()
  if M.state.chat_win and vim.api.nvim_win_is_valid(M.state.chat_win) then
    -- Focus existing window
    vim.api.nvim_set_current_win(M.state.chat_win)
    return
  end

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "Wellm Chat")
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  
  -- Create window (right side split)
  local width = math.floor(vim.o.columns * 0.4)
  local win = vim.api.nvim_open_win(buf, true, {
    split = "right",
    width = width,
    style = "minimal"
  })
  
  M.state.chat_buffer = buf
  M.state.chat_win = win

  -- Keymaps for chat buffer
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(M.state.chat_win, true) end, { buffer = buf, silent = true })
  vim.keymap.set("n", "<CR>", function() M.submit_chat_input() end, { buffer = buf, silent = true })
  
  -- Render existing history
  M.render_chat_history()
end

function M.render_chat_history()
  if not M.state.chat_buffer then return end
  local lines = {}
  for _, msg in ipairs(M.state.history) do
    table.insert(lines, string.format("## %s", msg.role:upper()))
    table.insert(lines, msg.content)
    table.insert(lines, "---")
  end
  vim.api.nvim_buf_set_lines(M.state.chat_buffer, 0, -1, false, lines)
  -- Move cursor to end
  vim.api.nvim_win_set_cursor(M.state.chat_win, { #lines, 0 })
end

function M.submit_chat_input()
  -- Last line is the input
  local lines = vim.api.nvim_buf_get_lines(M.state.chat_buffer, -2, -1, false)
  local input = lines[1] or ""
  
  -- Remove input line
  vim.api.nvim_buf_set_lines(M.state.chat_buffer, -2, -1, false, {})
  
  if #input > 0 then
    M.call_llm(input, "chat", function(response)
      -- Add to history and render
      table.insert(M.state.history, { role = "user", content = input })
      table.insert(M.state.history, { role = "assistant", content = response })
      M.render_chat_history()
    end)
  end
end

-- -------------------------------------------------------------------------------
-- CORE LOGIC
-- -------------------------------------------------------------------------------

function M.get_visual_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.fn.getline(start_pos[2], end_pos[2])
  if #lines == 0 then return "" end
  if #lines == 1 then return string.sub(lines[1], start_pos[3], end_pos[3]) end
  lines[1] = string.sub(lines[1], start_pos[3])
  lines[#lines] = string.sub(lines[#lines], 1, end_pos[3])
  return table.concat(lines, "\n")
end

function M.build_payload(user_content, mode, extra_file_context)
  -- Construct the user prompt with Context
  local formatted_context = ""
  if next(M.state.context_files) ~= nil then
    formatted_context = "\n\n### REFERENCE CONTEXT FILES:\n"
    for path, content in pairs(M.state.context_files) do
      formatted_context = formatted_context .. string.format("File: %s\n%s\n", path, content)
    end
  end

  local active_code = ""
  if mode == "replace" then
    active_code = "\n\n### ACTIVE SELECTION TO MODIFY:\n" .. user_content
  elseif mode == "insert" then
    active_code = "\n\n### INSTRUCTION:\n" .. user_content
    if extra_file_context then
      active_code = active_code .. "\n\n### CURRENT FILE CONTEXT:\n" .. extra_file_context
    end
  end
  
  local final_user_msg = user_content .. active_code .. formatted_context
  
  -- Build messages array
  local messages = {}
  
  -- Previous history
  for _, msg in ipairs(M.state.history) do
    table.insert(messages, { role = msg.role, content = msg.content })
  end
  
  -- Current request
  table.insert(messages, { role = "user", content = final_user_msg })

  local system_prompt = M.state.system_override or M.config.prompts.coding
  if mode == "chat" then system_prompt = M.config.prompts.chat end

  return messages, system_prompt
end

function M.call_llm(input_text, mode, callback, file_context)
  local messages, system_prompt = M.build_payload(input_text, mode, file_context)
  local api_key = M.config.api_key
  local model = M.config.model
  local provider = M.config.provider

  if not api_key then
    vim.notify("Missing API Key", vim.log.levels.ERROR)
    return
  end

  local url, headers, body

  -- Handle different Providers
  if provider == "anthropic" then
    url = "https://api.anthropic.com/v1/messages"
    headers = {
      "-H", string.format("x-api-key: %s", api_key),
      "-H", "anthropic-version: 2023-06-01",
      "-H", "content-type: application/json",
    }
    body = vim.fn.json_encode({
      model = model,
      system = system_prompt,
      messages = messages,
      max_tokens = M.config.max_tokens
    })
  elseif provider == "zhipu" then
    -- GLM-4 OpenAI Compatible Endpoint
    url = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
    -- Prepend system prompt to messages for OpenAI-compatible format
    table.insert(messages, 1, { role = "system", content = system_prompt })
    
    headers = {
      "-H", string.format("Authorization: Bearer %s", api_key),
      "-H", "content-type: application/json",
    }
    body = vim.fn.json_encode({
      model = model, -- e.g., "glm-4"
      messages = messages,
      max_tokens = M.config.max_tokens
    })
  else
    vim.notify("Unknown provider: " .. provider, vim.log.levels.ERROR)
    return
  end

  -- Execute Request
  if M.config.auto_open_chat and mode == "chat" then M.open_chat() end

  local curl_args = { "curl", "-s", "-X", "POST", url }
  for _, h in ipairs(headers) do
    table.insert(curl_args, h)
  end
  table.insert(curl_args, "-d")
  table.insert(curl_args, body)

  print("[Wellm Debug] URL: " .. url)
  print("[Wellm Debug] Args: " .. vim.inspect(curl_args))

  vim.fn.jobstart(curl_args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if not data or type(data) == "number" then return end
      local response = table.concat(data, "\n")
    
      -- DEBUG PRINT: See the raw API response
      print("[Wellm Debug] Raw Response: " .. response)
        
      local ok, decoded = pcall(vim.fn.json_decode, response)
      
      if ok then
        -- 1. Check if Anthropic returned an explicit Error Object
        if decoded.type == "error" then
          local msg = decoded.error and decoded.error.message or "Unknown API Error"
          vim.notify("LLM API Error: " .. msg, vim.log.levels.ERROR)
          return
        end

        local content = ""
        
        if provider == "anthropic" then
          -- Handle normal text response
          if decoded.content and decoded.content[1] then
            content = decoded.content[1].text
          else
            -- Debug: If we got here, JSON is valid, but content structure is wrong.
            -- Print the raw response to :messages
            print("DEBUG: Anthropic returned valid JSON but unexpected structure:")
            print(vim.inspect(decoded))
            vim.notify("LLM Error: Could not find text in response. Check :messages for debug info.", vim.log.levels.ERROR)
            return
          end
          
        elseif provider == "zhipu" then
          if decoded.choices and decoded.choices[1] then
            content = decoded.choices[1].message.content
          else
            print("DEBUG: Zhipu returned valid JSON but unexpected structure:")
            print(vim.inspect(decoded))
            vim.notify("LLM Error: Could not find text in response. Check :messages for debug info.", vim.log.levels.ERROR)
            return
          end
        end

        if content and content ~= "" then
          -- Clean markdown code blocks for Replace/Insert modes
          if mode == "replace" or mode == "insert" then
            content = content:gsub("```%w*\n?", ""):gsub("", "")
          end
          callback(content)
        else
          vim.notify("LLM Error: Content was empty.", vim.log.levels.WARN)
        end
        
      else
        -- If JSON decode failed
        vim.notify("LLM API Error: " .. response, vim.log.levels.ERROR)
      end
    end,
  })
end

-- -------------------------------------------------------------------------------
-- ACTIONS
-- -------------------------------------------------------------------------------

function M.action_replace()
  local selection = M.get_visual_selection()
  if selection == "" then return end
  
  vim.notify("[Wellm] Requesting replacement...", vim.log.levels.INFO)
  
  M.call_llm(selection, "replace", function(response)
    -- Restore visual range to replace it
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_line = start_pos[2] - 1
    local end_line = end_pos[2] - 1
    local start_col = start_pos[3] - 1
    local end_col = end_pos[3] - 1

    local lines = vim.split(response, "\n")
    vim.api.nvim_buf_set_text(0, start_line, start_col, end_line, end_col, lines)
    vim.notify("[Wellm] Replaced code.", vim.log.levels.INFO)
  end)
end

function M.action_insert()
  local file_content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  -- For insert, we usually ask the user "What do you want to insert?"
  -- But to keep it fast, let's assume the prompt is "Generate code fitting for this context"
  -- We'll use the prompts.insert logic but simplified
  vim.ui.input({ prompt = "Describe code to insert: " }, function(input)
    if not input or input == "" then return end
    
    M.call_llm(input, "insert", function(response)
      local cursor_pos = vim.api.nvim_win_get_cursor(0)
      local cursor_line = cursor_pos[1]
      local lines = vim.split(response, "\n")
      vim.api.nvim_buf_set_lines(0, cursor_line, cursor_line, false, lines)
    end, file_content) -- Pass file content here
  end)
end

return M