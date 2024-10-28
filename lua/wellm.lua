-- wellm.lua
local M = {}

-- Configure setup with user-provided settings
M.config = {}

function M.setup(opts)
    M.config.api_key = opts.api_key_name
    M.config.model = opts.model
    M.config.max_tokens = opts.max_tokens
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
    
    -- Split the line at cursor position
    local before = string.sub(current_line, 1, col + 1)
    local after = string.sub(current_line, col + 2)
    
    -- Insert text at cursor position
    local new_line = before .. text .. after
    vim.api.nvim_set_current_line(new_line)
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

local function call_claude_api(prompt, callback)
    local api_key = M.config.api_key
    local model = M.config.model
    local max_tokens = M.config.max_tokens
    
    local url = "https://api.anthropic.com/v1/messages"
    
    -- payload for Anthropic API
    local body = vim.fn.json_encode({
        model = model,
        messages = {
            { role = "user", content = prompt }
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
                        callback(decoded.content[1].text)
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
        call_claude_api(selected_text, insert_at_cursor)
    end
end

-- Define the :ClaudeReplace command for replacing selection
function M.claude_replace()
    local selected_text = get_visual_selection()
    if selected_text ~= "" then
        call_claude_api(selected_text, replace_visual_selection)
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