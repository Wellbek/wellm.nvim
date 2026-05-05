# wellm.nvim

Neovim LLM integration with persistent project context, session history, file picker, and usage tracking.

## Structure

```
lua/wellm/
├── init.lua          # Entry point: setup(), keymaps, user commands
├── config.lua        # Default config + model pricing table
├── state.lua         # Single mutable state table
├── llm.lua           # Core API call, [READ:] loop, orient
├── actions.lua       # Replace selection, insert at cursor
├── context.lua       # Add/remove/clear context files
├── wellagent.lua     # .wellagent/ folder management
├── session.lua       # Session save/load/list
├── usage.lua         # Token & cost tracking
└── ui/
    ├── chat.lua      # Split-right chat window
    ├── picker.lua    # Floating checkbox file-tree
    ├── history.lua   # Session browser with preview
    └── usage.lua     # Usage & cost display
```

## .wellagent folder

```
.wellagent/
├── context/
│   ├── OVERVIEW.md   <- LLM-generated project summary (auto)
│   ├── STRUCTURE.md  <- Annotated file tree (auto)
│   └── DECISIONS.md  <- Rolling log; append with :WellmDecision
├── sessions/
│   └── 2026-05-05T14-32-00.md
├── index.json        <- Session index for fast listing
├── usage.json        <- Monthly token/cost ledger
└── .gitignore
```

## Setup (lazy.nvim)

```lua
{
  "yourname/wellm.nvim",
  config = function()
    require("wellm").setup({
      provider     = "anthropic",     -- or "zhipu"
      api_key_name = "ANTHROPIC_API_KEY",
      model        = "claude-sonnet-4-5",
      max_tokens   = 8192,

      wellagent = {
        enabled     = true,
        auto_init   = true,   -- create .wellagent on first buffer open
        auto_orient = true,   -- generate OVERVIEW + STRUCTURE if missing
      },

      sessions = {
        save_automatically = true,
        max_sessions       = 100,
      },

      -- Override any key (see config.lua for all defaults)
      keys = {
        chat    = { "<leader>ca", mode = "n", desc = "AI Chat" },
        replace = { "<leader>cr", mode = "v", desc = "AI Replace" },
      },

      -- skip_default_mappings = true,  -- if you want full manual control
    })
  end,
}
```

## Default Keymaps

| Key            | Mode | Action                        |
|----------------|------|-------------------------------|
| `<leader>ca`   | n    | Open chat window              |
| `<leader>cr`   | v    | Replace selection with AI     |
| `<leader>cc`   | n    | Insert at cursor              |
| `<leader>cap`  | n    | File picker (checkbox tree)   |
| `<leader>ch`   | n    | Session history browser       |
| `<leader>cu`   | n    | Usage & cost summary          |
| `<leader>co`   | n    | Re-orient project             |
| `<leader>caf`  | n    | Add current file to context   |
| `<leader>cad`  | n    | Add folder to context         |
| `<leader>cac`  | n    | Clear context + history       |

## Commands

| Command                   | Description                            |
|---------------------------|----------------------------------------|
| `:WellmChat`              | Open chat                              |
| `:WellmReplace`           | Replace visual selection               |
| `:WellmInsert`            | Insert at cursor                       |
| `:WellmPicker`            | Open file picker                       |
| `:WellmHistory`           | Browse session history                 |
| `:WellmUsage`             | Show monthly usage & cost              |
| `:WellmOrient`            | Re-generate OVERVIEW + STRUCTURE       |
| `:WellmAddFile`           | Add current file to context            |
| `:WellmAddFolder`         | Add folder to context                  |
| `:WellmClear`             | Clear all context + history            |
| `:WellmSystem`            | Edit system prompt for this session    |
| `:WellmModel <name>`      | Switch model mid-session               |
| `:WellmNewSession`        | Save current session, start fresh      |
| `:WellmDecision <text>`   | Manually append to DECISIONS.md        |

## Chat window keys

| Key          | Action                            |
|--------------|-----------------------------------|
| `<CR>`       | Send message (normal mode)        |
| `i` / `A`    | Jump to input line                |
| `q`          | Close                             |
| `<C-c>`      | Cancel running request            |
| `<leader>cn` | New conversation (saves current)  |

## File picker keys

| Key      | Action                        |
|----------|-------------------------------|
| `<Space>`| Toggle file / toggle dir      |
| `a`      | Select all                    |
| `n`      | Select none                   |
| `<CR>`   | Confirm and load into context |
| `q`/`Esc`| Cancel                       |

## LLM auto file-read

In any prompt, the model can request files it needs:

```
[READ: src/parser.lua]
```

The plugin detects this, injects the file into context, and continues the
conversation automatically (up to 3 hops to prevent loops).

## Updating pricing

Edit the `pricing` table in `lua/wellm/config.lua`:

```lua
M.pricing = {
  ["claude-sonnet-4-5"] = { input = 3.0, output = 15.0 },  -- USD per MTok
  ...
}
```
