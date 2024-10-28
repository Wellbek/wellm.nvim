# wellm.nvim

My simple Neovim plugin for seamless interaction with Claude AI, allowing for code generation, modification, and insertion directly within nvim editor.




https://github.com/user-attachments/assets/4ec774b6-2993-4800-98ba-a9b1cdaafe3e


## Prerequisites

- Neovim 0.5 or higher
- curl
- An Anthropic API key

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim), add this to your Neovim configuration:

```lua
{
    'Wellbek/wellm.nvim',
    config = function()  
        -- Setup the plugin
        local wellm = require('wellm')
        wellm.setup({
            api_key_name = "your-anthropic-api-key-here",  -- Replace with your API key
            model = "claude-3-5-sonnet-20241022", 
            max_tokens = 4096,  
            -- Optional: Override default prompts
            -- prompts = {
            --    replace = [[Your custom replace prompt here]],
            --    insert = [[Your custom insert prompt here]]
            -- }                 
        })
        
        -- Setup keybindings for visual mode
        vim.api.nvim_set_keymap('v', '<space>i', ':Claude<CR>', { noremap = true, silent = true })
        vim.api.nvim_set_keymap('v', '<space>r', ':ClaudeReplace<CR>', { noremap = true, silent = true })
    end
}
```

## Configuration Options

- `api_key_name`: Your Anthropic API key
- `model`: The Claude model to use (default: "claude-3-5-sonnet-20241022")
- `max_tokens`: Maximum tokens in the response (default: 4096)
- `prompts`: Optional table to override default system prompts
  - `replace`: Prompt for code replacement functionality
  - `insert`: Prompt for code insertion functionality

## Usage

### Default Keybindings (Visual Mode)
- `<space>i`: Insert AI-generated code after mouse cursor
- `<space>r`: Replace selection with AI-generated code

### Commands
- `:Claude`: Insert AI-generated code after mouse cursor
- `:ClaudeReplace`: Replace selection with AI-generated code

## Example Usage

1. **Replace existing code**:
   - Select code in visual mode (v)
   - Press `<space>r` or type `:ClaudeReplace`
   - Selected code will be replaced with improved version

2. **Insert new code**:
   - Write prompt as comment 
   - Press `<space>i` or type `:Claude`
   - New code will be inserted on a new line after mouse cursor
