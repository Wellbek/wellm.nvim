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
  job_id = nil,          -- Current running job ID (to cancel if needed)
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
  
  if not M.config.api_key or M.config.api_key == "" then
    M.config.api_key = os.getenv(M.config.api_key_name)
  end

  if not M.config.api_key then
    vim.notify("[Wellm] API Key not found. Set " .. M.config.api_key_name, vim.log.levels.WARN)
  end

  -- Load Keymaps
  if not M.config.skip_default_mappings then
    M.set_keymaps()
  end

  -- Load Commands
  M.set_commands()
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
  vim.api.nvim_create_user_command("WellmReplace", function() M.action_replace() end, { range = true })
  vim.api.nvim_create_user_command("WellmInsert", function() M.action_insert() end, {})
  vim.api.nvim_create_user_command("WellmChat", function() M.open_chat() end, {})
  vim.api.nvim_create_user_command("WellmAddFile", function() M.add_context_file() end, {})
  vim.api.nvim_create_user_command("WellmAddFolder", function() M.add_context_folder() end, {})
  vim.api.nvim_create_user_command("WellmSystem", function() M.edit_system_prompt() end, {})
end

-- -------------------------------------------------------------------------------
-- CONTEXT MANAGEMENT
-- -------------------------------------------------------------------------------
function M.add_context_file(path)
  path = path or vim.fn.expand("%:p")
  if not path or path == "" or vim.fn.filereadable(path) == 0 then return end
  
  local content = table.concat(vim.fn.readfile(path), "\n")
  M.state.context_files[path] = content
  vim.notify(string.format("[Wellm] Added: %s", vim.fn.fnamemodify(path, ":t")))
end

function M.add_context_folder(path)
  path = path or vim.fn.input("Folder path: ", vim.fn.expand("%:p:h"), "dir")
  if path == "" then return end
  
  local scan = require("plenary.scandir").scan_dir or nil -- Fallback if plenary not present, use logic below
  
  -- Using vim.loop (uv) for native scanning
  local handle = vim.loop.fs_scandir(path)
  if not handle then return end

  local count = 0
  while true do
    local name, type = vim.loop.fs_scandir_next(handle)
    if not name then break end
    local full_path = path .. "/" .. name
    
    if type == "file" and not name:match("^%.") and not name:match("lock$") then
      M.add_context_file(full_path)
      count = count + 1
    end
  end
  vim.notify(string.format("[Wellm] Added %d files.", count))
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
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "wrap", true)
  
  local width = math.floor(vim.o.columns * 0.4)
  local win = vim.api.nvim_open_win(buf, true, {
    split = "right", width = width, style = "minimal"
  })
  
  M.state.chat_buffer = buf
  M.state.chat_win = win

  -- Keymaps for chat buffer
  vim.keymap.set("n", "q", function() vim.api.nvim_win_close(M.state.chat_win, true) end, { buffer = buf, silent = true })
  vim.keymap.set("n", "<CR>", function() M.submit_chat_input() end, { buffer = buf, silent = true })
  
  -- Render existing history
  M.render_chat_history()
  
  -- Instructions
  local instructions = { "Type your message and press <CR> to send.", "---" }
  vim.api.nvim_buf_set_lines(buf, 0, 0, false, instructions)
end

function M.render_chat_history()
  if not M.state.chat_buffer then return end
  local lines = {}
  for _, msg in ipairs(M.state.history) do
    table.insert(lines, "# " .. msg.role:upper())
    for _, l in ipairs(vim.split(msg.content, "\n")) do table.insert(lines, l) end
    table.insert(lines, "")
    table.insert(lines, "---")
    table.insert(lines, "")
  end
  
  -- Append to buffer (keeping instruction header if possible, but simplest is full redraw)
  vim.api.nvim_buf_set_lines(M.state.chat_buffer, 2, -1, false, lines)
  vim.api.nvim_win_set_cursor(M.state.chat_win, { vim.api.nvim_buf_line_count(M.state.chat_buffer), 0 })
end

function M.submit_chat_input()
  local lines = vim.api.nvim_buf_get_lines(M.state.chat_buffer, -2, -1, false)
  local input = lines[1] or ""
  
  if #input == 0 or input:match("^%s*$") then return end

  -- Clear input line
  vim.api.nvim_buf_set_lines(M.state.chat_buffer, -2, -1, false, {})

  -- Add user message immediately
  table.insert(M.state.history, { role = "user", content = input })
  M.render_chat_history()
  
  -- Add a temporary "Thinking..." indicator
  local last_line = vim.api.nvim_buf_line_count(M.state.chat_buffer)
  vim.api.nvim_buf_set_lines(M.state.chat_buffer, last_line, -1, false, { "...", "**Thinking...**" })

  M.call_llm(input, "chat", function(response)
    -- Remove "Thinking..." (simplistic approach: redraw whole history)
    table.insert(M.state.history, { role = "assistant", content = response })
    M.render_chat_history()
  end)
end

-- -------------------------------------------------------------------------------
-- CORE LOGIC
-- -------------------------------------------------------------------------------

function M.get_visual_selection()
  -- Helper to get reliable visual selection
  local _, srow, scol, _ = unpack(vim.fn.getpos("v"))
  local _, erow, ecol, _ = unpack(vim.fn.getpos("."))
  
  -- Swap if backwards
  if srow > erow or (srow == erow and scol > ecol) then
    srow, erow, scol, ecol = erow, srow, ecol, scol
  end

  local lines = vim.api.nvim_buf_get_lines(0, srow - 1, erow, false)
  if #lines == 0 then return "" end
  
  -- Truncate first and last line
  lines[#lines] = string.sub(lines[#lines], 1, ecol)
  lines[1] = string.sub(lines[1], scol)
  return table.concat(lines, "\n")
end

function M.build_payload(user_content, mode, extra_file_context)
  local messages = {}
  
  -- System Prompt
  local sys_prompt = M.state.system_override or M.config.prompts.coding
  if mode == "chat" then sys_prompt = M.config.prompts.chat end

  -- Add history
  for _, msg in ipairs(M.state.history) do
    table.insert(messages, { role = msg.role, content = msg.content })
  end

  -- Context Construction
  local context_str = ""
  for path, content in pairs(M.state.context_files) do
    context_str = context_str .. string.format("\nFile: %s\n```\n%s\n```\n", path, content)
  end
  
  if extra_file_context then
    context_str = context_str .. "\nCurrent File:\n```\n" .. extra_file_context .. "\n```\n"
  end

  local final_msg = user_content
  if context_str ~= "" then
    final_msg = final_msg .. "\n\nCONTEXT:\n" .. context_str
  end
  
  -- Add current request
  table.insert(messages, { role = "user", content = final_msg })

  return messages, sys_prompt
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

  -- Handle different Providers (Back to your working logic)
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
    url = "https://open.bigmodel.cn/api/paas/v4/chat/completions"
    table.insert(messages, 1, { role = "system", content = system_prompt })
    headers = {
      "-H", string.format("Authorization: Bearer %s", api_key),
      "-H", "content-type: application/json",
    }
    body = vim.fn.json_encode({
      model = model,
      messages = messages,
      max_tokens = M.config.max_tokens
    })
  else
    vim.notify("Unknown provider: " .. provider, vim.log.levels.ERROR)
    return
  end

  -- Write body to a temp file to prevent shell escaping errors
  local tmp_body = os.tmpname()
  local f = io.open(tmp_body, "w")
  if f then
    f:write(body)
    f:close()
  end

  if M.config.auto_open_chat and mode == "chat" then M.open_chat() end

  -- Construct Curl Command
  local curl_args = { "curl", "-s", "-X", "POST", url }
  for _, h in ipairs(headers) do table.insert(curl_args, h) end
  table.insert(curl_args, "-d")
  table.insert(curl_args, "@" .. tmp_body) -- Read body from file

  local response_chunks = {}

  vim.fn.jobstart(curl_args, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(response_chunks, line) end
        end
      end
    end,
    on_exit = function(_, exit_code)
      -- Clean up temp file
      os.remove(tmp_body)

      if exit_code ~= 0 then
        vim.schedule(function() 
          vim.notify("Wellm: Curl failed with code " .. exit_code, vim.log.levels.ERROR) 
        end)
        return
      end

      local response = table.concat(response_chunks, "")
      local ok, decoded = pcall(vim.fn.json_decode, response)
      
      vim.schedule(function()
        if not ok then
          vim.notify("Wellm: Failed to decode response", vim.log.levels.ERROR)
          return
        end

        local content = ""
        if provider == "anthropic" then
          content = (decoded.content and decoded.content[1]) and decoded.content[1].text or ""
        elseif provider == "zhipu" then
          content = (decoded.choices and decoded.choices[1]) and decoded.choices[1].message.content or ""
        end

        if content ~= "" then
          -- Clean markdown for code-only actions
          if mode == "replace" or mode == "insert" then
            content = content:gsub("^```%w*\n", ""):gsub("```$", "")
          end
          callback(content)
        else
          vim.notify("Wellm: Empty response from AI", vim.log.levels.WARN)
        end
      end)
    end,
  })
end

-- -------------------------------------------------------------------------------
-- ACTIONS
-- -------------------------------------------------------------------------------

function M.action_replace()
  -- Force exit visual mode to update the '< and '> marks
  vim.cmd('normal! \27') 
  
  -- Get the visual selection marks
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  
  -- Extract the text to be replaced
  local selection = M.get_visual_selection()
  if selection == "" then 
    vim.notify("[Wellm] No selection found.", vim.log.levels.WARN)
    return 
  end

  -- Ask the user what they want to do with this specific code
  vim.ui.input({ prompt = "Instruction to replace: " }, function(input)
    if not input or input == "" then return end
    
    vim.notify("[Wellm] Thinking...", vim.log.levels.INFO)
    
    -- We pass 'selection' as the main text and 'replace' as the mode
    M.call_llm(input, "replace", function(response)
      local lines = vim.split(response, "\n")
      
      -- Convert 1-based positions to 0-based for API
      local s_row, s_col = start_pos[2] - 1, start_pos[3] - 1
      local e_row, e_col = end_pos[2] - 1, end_pos[3]

      -- This specifically replaces ONLY the highlighted characters
      vim.api.nvim_buf_set_text(0, s_row, s_col, e_row, e_col, lines)
      
      vim.notify("[Wellm] Code rewritten.", vim.log.levels.INFO)
    end, selection) -- Pass the selected code as the 'file_context' parameter
  end)
end

function M.action_insert()
  local file_content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
  
  vim.ui.input({ prompt = "Instruction: " }, function(input)
    if not input or input == "" then return end
    
    vim.notify("[Wellm] Generating...", vim.log.levels.INFO)
    M.call_llm(input, "insert", function(response)
      local row, _ = unpack(vim.api.nvim_win_get_cursor(0))
      local lines = vim.split(response, "\n")
      vim.api.nvim_buf_set_lines(0, row, row, false, lines)
      vim.notify("[Wellm] Inserted.", vim.log.levels.INFO)
    end, file_content)
  end)
end

return M