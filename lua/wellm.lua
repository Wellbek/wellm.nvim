-- wellm.lua
local M = {}

-- Configure setup with user-provided settings
M.config = {}

function M.setup(opts)
    M.config.api_key = opts.api_key_name
    M.config.model = opts.model
    M.config.max_tokens = opts.max_tokens
end

local function call_claude_api(prompt)
    local api_key = M.config.api_key
    local model = M.config.model
    local max_tokens = M.config.max_tokens
    
    local url = "https://api.anthropic.com/v1/messages"
    
    local body = vim.fn.json_encode({
        model = model,
        messages = {
            { role = "user", content = prompt }
        },
        max_tokens = max_tokens 
    })
    
    -- Make an asynchronous HTTP POST request with updated headers
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
                        print(decoded.content[1].text)
                    else
                        print("Claude API Response: " .. response)
                    end
                end
            end
        end,
        on_stderr = function(_, err)
            if err then
                print("Error calling Claude API: " .. vim.inspect(err))
            end
        end,
    })
end

-- Define the :Claude command
function M.claude(prompt)
    call_claude_api(prompt or "")
end

vim.api.nvim_create_user_command("Claude", function(opts)
    M.claude(opts.args)
end, { nargs = 1 })  -- Command expects a single argument (the prompt)

return M