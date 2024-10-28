-- wellm.lua
local M = {}

-- Configure setup with user-provided settings
M.config = {
    -- Default prompts that can be overridden in setup
    prompts = {
        replace = [[You are a code assistant. Follow these rules strictly:
1. Output only valid, clean code
2. Remove comments that contain instructions/requests after implementing them
3. Preserve non-instruction comments
4. Never use markdown code blocks or backticks
5. Never add explanations or additional text
6. Keep existing code structure unless specifically asked to change it]],
        
        insert = [[You are a code assistant. Follow these rules strictly:
1. Output only valid, clean code
2. Never use markdown code blocks or backticks
3. Never add explanations or additional text
4. Format the code to match the surrounding context]]
    }
}

function M.setup(opts)
    M.config.api_key = opts.api_key_name
    M.config.model = opts.model
    M.config.max_tokens = opts.max_tokens
    
    -- Allow custom prompts to override defaults
    if opts.prompts then
        if opts.prompts.replace then
            M.config.prompts.replace = opts.prompts.replace
        end
        if opts.prompts.insert then
            M.config.prompts.insert = opts.prompts.insert
        end
    end
end

local function get_visual_selection()
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local lines = vim.fn.getline(start_pos[2], end_pos[2])
    
    if #lines == 0 then
        return ""
    end
    
    -- Handle single line selection
    if #lines == 1 then
        return string.sub(lines[1], start_pos[3], end_pos[3])
    end
    
    -- Handle multi-line selection
    lines[1] = string.sub(lines[1], start_pos[3])
    lines[#lines] = string.sub(lines[#lines], 1, end_pos[3])
    return table.concat(lines, "\n")
end

local function insert_at_cursor(text)
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local line = cursor_pos[1] - 1
    local col = cursor_pos[2]
    
    -- Get current line content
    local current_line = vim.api.nvim_get_current_line()
    
    -- Split the text into lines
    local text_lines = vim.split(text, "\n")
    
    -- Handle the first line: combine with current line content
    local before = string.sub(current_line, 1, col + 1)
    local after = string.sub(current_line, col + 2)
    local first_line = before .. text_lines[1]
    
    -- If there's only one line, handle it differently
    if #text_lines == 1 then
        vim.api.nvim_set_current_line(first_line .. after)
        return
    end
    
    -- Prepare all lines for insertion
    local lines_to_insert = {first_line}
    for i = 2, #text_lines - 1 do
        table.insert(lines_to_insert, text_lines[i])
    end
    -- Add the last line with the remaining content from the original line
    table.insert(lines_to_insert, text_lines[#text_lines] .. after)
    
    -- Replace the current line and insert the new lines
    vim.api.nvim_buf_set_lines(0, line, line + 1, false, lines_to_insert)
end

local function replace_visual_selection(text)
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_line = start_pos[2]
    local end_line = end_pos[2]
    
    -- Replace the selected text with the new text
    vim.api.nvim_buf_set_text(
        0,
        start_line - 1,
        start_pos[3] - 1,
        end_line - 1,
        end_pos[3],
        vim.split(text, "\n")
    )
end

local function call_claude_api(prompt, callback, system_prompt)
    local api_key = M.config.api_key
    local model = M.config.model
    local max_tokens = M.config.max_tokens
    
    local url = "https://api.anthropic.com/v1/messages"
    
    -- Combine system prompt with user prompt
    local full_prompt = system_prompt .. "\n\nHere is the code:\n" .. prompt
    
    -- payload for Anthropic API
    local body = vim.fn.json_encode({
        model = model,
        messages = {
            { role = "user", content = full_prompt }
        },
        max_tokens = max_tokens
    })
    
    -- Make an asynchronous HTTP POST request
    vim.fn.jobstart({
        "curl", "-s", "-X", "POST", url,
        "-H", string.format("x-api-key: %s", api_key),
        "-H", "anthropic-version: 2023-06-01",
        "-H", "Content-Type: application/json",
        "-d", body
    }, {
        stdout_buffered = true,
        on_stdout = function(_, data)
            if data then
                local response = table.concat(data, "\n")
                if response ~= "" then
                    local decoded = vim.fn.json_decode(response)
                    if decoded and decoded.content and decoded.content[1] and decoded.content[1].text then
                        -- Strip any potential markdown code blocks that might have been added
                        local clean_text = decoded.content[1].text:gsub("```%w*\n?", ""):gsub("```", "")
                        callback(clean_text)
                    else
                        print("Claude API Response: " .. response)
                    end
                end
            end
        end,
        on_stderr = function(_, err)
            if err and #err > 0 and table.concat(err, "") ~= "" then
                print("Error calling Claude API: " .. vim.inspect(err))
            end
        end,
    })
end

-- Define the :Claude command for inserting after cursor
function M.claude()
    local selected_text = get_visual_selection()
    if selected_text ~= "" then
        call_claude_api(selected_text, insert_at_cursor, M.config.prompts.insert)
    end
end

-- Define the :ClaudeReplace command for replacing selection
function M.claude_replace()
    local selected_text = get_visual_selection()
    if selected_text ~= "" then
        call_claude_api(selected_text, replace_visual_selection, M.config.prompts.replace)
    end
end

-- Create commands
vim.api.nvim_create_user_command("Claude", function()
    M.claude()
end, { range = true })

vim.api.nvim_create_user_command("ClaudeReplace", function()
    M.claude_replace()
end, { range = true })

return M