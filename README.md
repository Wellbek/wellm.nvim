# wellm.nvim

My Neovim plugin for seamless interaction with Claude AI and GLM-4. It allows for context-aware code generation, modification, and chat directly within your editor.

## Features

*   **Multi-Provider Support**: Switch between Anthropic (Claude) and ZhipuAI (GLM-4).
*   **Context Awareness**: Reference entire files or folders to give the AI deep knowledge of project structures.
*   **Chat Interface**: A persistent chat window with memory to view conversation history.
*   **Quick Actions**: Fast code replacement and insertion modes.
*   **Professional Prompting**: Built-in system prompts designed for high-quality coding tasks.

## 📋 Prerequisites

-   Neovim 0.9 or higher
-   `curl` installed on your system
-   An API key for:
    -   **Anthropic** (for Claude): [Get Key Here](https://console.anthropic.com/)
    -   **ZhipuAI** (for GLM-4): [Get Key Here](https://open.bigmodel.cn/)

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim), add this to your Neovim configuration:

```lua
{
  'Wellbek/wellm.nvim',
  lazy = false,
  config = function()
    require('wellm').setup({
      -- Provider Selection: "anthropic" or "zhipu"
      provider = "anthropic", 

      -- It is recommended to set your API key as an environment variable
      -- e.g., export ANTHROPIC_API_KEY="sk-..."
      -- e.g., export ZHIPUAI_API_KEY="..."
      api_key_name = "ANTHROPIC_API_KEY", 

      model = "claude-3-5-sonnet-20240620",
      max_tokens = 8192,
    })
  end
}
```

### Configuration Examples

#### Option A: Using Claude (Default)
Ensure your environment variable is set (`export ANTHROPIC_API_KEY="..."`).

```lua
require('wellm').setup({
  provider = "anthropic",
  api_key_name = "ANTHROPIC_API_KEY", 
  model = "claude-3-5-sonnet-20240620",
})
```

#### Option B: Using GLM 4 (ZhipuAI)
Ensure your environment variable is set (`export ZHIPUAI_API_KEY="..."`).

```lua
require('wellm').setup({
  provider = "zhipu",
  api_key_name = "ZHIPUAI_API_KEY", 
  model = "glm-4",
})
```

#### Option C: Custom Keymaps
If you prefer to define your own mappings:

```lua
require('wellm').setup({
  skip_default_mappings = true, -- Turn off plugin defaults
})

-- Define your own
vim.keymap.set('v', '<leader>r', ":WellmReplace<CR>", { desc = "AI Replace" })
vim.keymap.set('n', '<leader>c', ":WellmChat<CR>", { desc = "AI Chat" })
```

---

## Usage

### Default Keybindings

| Mode | Key | Action | Description |
| :--- | :--- | :--- | :--- |
| **Visual** | `<leader>cr` | Replace | Replaces selected code with AI improved version |
| **Normal** | `<leader>cc` | Insert | Opens prompt to insert new code at cursor |
| **Normal** | `<leader>ca` | Chat | Opens/Toogles the AI Chat window |
| **Normal** | `<leader>caf` | Add File | Adds current file to AI Context |
| **Normal** | `<leader>cad` | Add Folder | Adds current folder to AI Context |
| **Normal** | `<leader>cac` | Clear Context | Clears all history and context |

*(Note: `<leader>` is usually mapped to the Space key)*

### Available Commands

*   `:WellmReplace` - Trigger replacement on visual selection.
*   `:WellmInsert` - Trigger insertion at cursor.
*   `:WellmChat` - Open the interactive chat window.
*   `:WellmAddFile` - Manually add a specific file path to context.
*   `:WellmAddFolder` - Manually add a folder path to context.
*   `:WellmSystem` - Update the system prompt/personality on the fly.

---

## Usage Examples

### 1. Code Replacement (Refactoring)
You have a messy function you want cleaned up.

1.  Enter Visual Mode (`v`) and select the function code.
2.  Press `<leader>cr` (or `:WellmReplace`).
3.  Wait a moment.
4.  The code is automatically replaced with the cleaner version.

### 2. Context-Aware Coding (Cross Referencing)
You want to use a utility function from `utils/helpers.lua` inside `main.lua`, but you don't want to look up the syntax.

1.  **Add Context**: Navigate to `utils/helpers.lua` and press `<leader>caf`. You should see a notification: `[Wellm] Added context: .../utils/helpers.lua`.
2.  **Navigate**: Go to `main.lua`.
3.  **Trigger**: Place cursor where you want code, press `<leader>cc`.
4.  **Prompt**: Type `Use the parseUser function from context to create a new user parser here`.
5.  **Result**: The AI sees the content of `helpers.lua` and generates code that matches the function signatures found there.

### 3. Folder Analysis
You want to understand how authentication works across your entire project.

1.  Press `<leader>cad`.
2.  Enter path to your `auth/` folder (or press Enter for current folder).
3.  Press `<leader>ca` to open Chat.
4.  Type: `How does the login flow work based on the files in context?`
5.  The AI analyzes all added files and provides a summary.

### 4. Chat & History
You are debugging an error and want a back-and-forth conversation.

1.  Press `<leader>ca` to open the side window.
2.  Type: `Why is this loop infinite?` and press Enter.
3.  The AI responds in the window.
4.  Follow up: `Okay, fix the condition but keep the logging logic.`
5.  Type: `Apply this fix` (If the AI provided code, you can copy it manually, or use the Insert/Replace modes in your main buffer).

### 5. Changing AI Persona
You need a security audit instead of standard coding help.

1.  Run command `:WellmSystem`.
2.  Input: `You are a Cyber Security Expert. Analyze code for vulnerabilities and output strictly a list of security flaws.`
3.  Now use `<leader>cr` on your code. The AI will act as a security auditor.
