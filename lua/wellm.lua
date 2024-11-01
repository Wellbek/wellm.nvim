local M = {}

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

local function insert_after_cursor(text)
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local cursor_line = cursor_pos[1]
    local lines_to_insert = vim.split(text, "\n")
    vim.api.nvim_buf_set_lines(0, cursor_line, cursor_line, false, lines_to_insert)
end

local function replace_visual_selection(text)
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local start_line = start_pos[2] - 1
    local end_line = end_pos[2] - 1
    local start_col = start_pos[3] - 1
    local end_col = end_pos[3] - 1

    -- Get the length of the last line to ensure end_col doesn't exceed it
    local line_length = vim.api.nvim_buf_get_lines(0, end_line, end_line + 1, true)[1]:len()
    end_col = math.min(end_col, line_length)

    -- Replace the text
    vim.api.nvim_buf_set_text(
        0,
        start_line,
        start_col,
        end_line,
        end_col,
        vim.split(text, "\n")
    )
end

M.config = {
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
4. Format the code to match the surrounding context
5. Only add the new code that is to be inserted. Do not output what was already provided]]
    }
}

function M.setup(opts)
    M.config.api_key = opts.api_key_name
    M.config.model = opts.model
    M.config.max_tokens = opts.max_tokens

    if opts.prompts then
        if opts.prompts.replace then
            M.config.prompts.replace = opts.prompts.replace
        end
        if opts.prompts.insert then
            M.config.prompts.insert = opts.prompts.insert
        end
    end
end

local function call_claude_api(prompt, callback, system_prompt)
    local api_key = M.config.api_key
    local model = M.config.model
    local max_tokens = M.config.max_tokens

    local url = "https://api.anthropic.com/v1/messages"

    local full_prompt = system_prompt .. "\n\nHere is the code:\n" .. prompt

    local body = vim.fn.json_encode({
        model = model,
        messages = {
            { role = "user", content = full_prompt }
        },
        max_tokens = max_tokens
    })

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
                        local clean_text = decoded.content[1].text:gsub("```%w*\n?", ""):gsub("", "")
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

function M.claude()
    local entire_file = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
    call_claude_api(entire_file, insert_after_cursor, M.config.prompts.insert)
end

function M.claude_replace()
    local selected_text = get_visual_selection()
    if selected_text ~= "" then
        call_claude_api(selected_text, replace_visual_selection, M.config.prompts.replace)
    end
end

vim.api.nvim_create_user_command("Claude", function()
    M.claude()
end, { range = true })

vim.api.nvim_create_user_command("ClaudeReplace", function()
    M.claude_replace()
end, { range = true })

return M
