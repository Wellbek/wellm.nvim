-- wellm.lua
local M = {}

-- Configure setup with user-provided settings
M.config = {}

function M.setup(opts)
    M.config.api_key_name = opts.api_key_name
    M.config.model = opts.model
    M.config.max_tokens = opts.max_tokens
end

local function call_claude_api(prompt)
    local api_key = M.config.api_key_name
    local model = M.config.model
    local max_tokens = M.config.max_tokens

    local url = "https://api.anthropic.com/v1/messages"
    local body = vim.fn.json_encode({
        model = model,
        prompt = prompt,
        max_tokens = max_tokens
    })

    -- Make an asynchronous HTTP POST request
    local headers = {
        ["Authorization"] = "Bearer " .. api_key,
        ["Content-Type"] = "application/json"
    }

    vim.fn.jobstart({
        "curl", "-s", "-X", "POST", url,
        "-H", "Authorization: Bearer " .. api_key,
        "-H", "Content-Type: application/json",
        "-d", body
    }, {
        stdout_buffered = true,
        on_stdout = function(_, data)
            if data then
                -- Join response lines and print to Neovim command line
                local response = table.concat(data, "\n")
                print(response)
            end
        end,
        on_stderr = function(_, err)
            if err then
                -- Convert the table to a string using vim.inspect for better readability
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
