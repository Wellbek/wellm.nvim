-- wellm/config.lua — defaults & model pricing table
local M = {}

-- Cost per million tokens (USD), based on pricing as of 2026-05-05.
-- Update as pricing changes.

M.pricing = {
  -- Claude models
  ["claude-opus-4-7"]   = { input = 5.0,   output = 25.0 },
  ["claude-opus-4-6"]   = { input = 5.0,   output = 25.0 },
  ["claude-opus-4-5"]   = { input = 5.0,   output = 25.0 },
  ["claude-sonnet-4-6"] = { input = 3.0,   output = 15.0 },
  ["claude-sonnet-4-5"] = { input = 3.0,   output = 15.0 },
  ["claude-haiku-4-5"]  = { input = 1.0,   output = 5.0  },
  ["claude-haiku-3-5"]  = { input = 0.80,  output = 4.0  },
  ["claude-haiku-3"]    = { input = 0.25,  output = 1.25 },

  -- GLM models
  ["glm-5.1"]           = { input = 1.4,   output = 4.4  },
  ["glm-5"]             = { input = 1.0,   output = 3.2  },
  ["glm-5-turbo"]       = { input = 1.2,   output = 4.0  },
  ["glm-4.7"]           = { input = 0.6,   output = 2.2  },
  ["glm-4.7-flashx"]    = { input = 0.07,  output = 0.4  },
  ["glm-4.6"]           = { input = 0.6,   output = 2.2  },
  ["glm-4.5"]           = { input = 0.6,   output = 2.2  },
  ["glm-4.5-x"]         = { input = 2.2,   output = 8.9  },
  ["glm-4.5-air"]       = { input = 0.2,   output = 1.1  },
  ["glm-4.5-airx"]      = { input = 1.1,   output = 4.5  },
  ["glm-4.32b"]         = { input = 0.1,   output = 0.1  },

  -- Free tiers (treated as zero cost)
  ["glm-4.7-flash"]     = { input = 0.0,   output = 0.0  },
  ["glm-4.5-flash"]     = { input = 0.0,   output = 0.0  },
}

M.defaults = {
  provider     = "anthropic",
  api_key_name = "ANTHROPIC_API_KEY",
  api_key      = nil,
  model        = "claude-sonnet-4-5",
  max_tokens   = 8192,
  context_window = 300000,
  filechanges = "filechanges_confirm", -- "filechanges_off" | "filechanges_confirm" | "filechanges_on"

  wellagent = {
    enabled          = true,
    auto_init        = true,   -- create .wellagent on first use
    auto_orient      = true,   -- generate OVERVIEW/STRUCTURE if missing
	max_entries_before_summarize = 8,
    ignored_patterns = {
      "%.git", "node_modules", "%.wellagent", "__pycache__",
      "%.pyc", "%.class", "dist", "build", "target", "%.cache",
    },
  },

  sessions = {
    save_automatically = true,
    max_sessions       = 100,
    summary_turns      = 6,
  },

  context = {
    chunk_size    = 50,
    smart_top_k   = 3,
    item_ttl      = 1,
  },

  llm = {
    output_reserve       = 2048,
    max_tool_rounds      = 30,     -- hard cap on tool call loops per request
    duplicate_tolerance  = 5,      -- allow this many duplicate tool calls before stopping
    save_interval_chars  = 2000,   -- auto-save session every N characters during streaming
  },

  prompts = {
    coding = [[You are an expert software engineer in Neovim. You have access to edit_file tool.

Use the edit_file tool to modify files. Never output code fences or explanations when in replace/insert mode.
For creating new files, use edit_file with search = "" and the full file content as replace.
After changes, add a line: [DECISION: summary]=]],

    chat = [[
    You are an expert software engineer working inside Neovim. Your goal is to help the user by actually performing tasks, not by explaining what you plan to do unless asked to do so.

    ## Core principle: ACT, don't narrate extensively.
    - Prefer making tool calls (read_file, edit_file, edit_file_multiple) immediately over writing long reasoning.
    - If you know what to do, do it directly. Do NOT say "Let me", "I'll", "First", "Now I", "Wait", "Actually", or "I need to".
    - After reading a file, make your edit right away
    - Each assistant message should contain EITHER tool calls OR a brief final answer, not a mix of thinking and action.

    ## Token budget awareness
    You have approximately 150k tokens of context remaining (out of 200k). Be concise.

    ## When you must write prose
    - Provide a short summary only after all tool calls for a given task are complete.
    - One line per key decision. Example: "[DECISION: refactored parse() to handle nil input]"

    ## Tool use guidelines
    - Use read_file only when you need the exact content (e.g., to edit). Prefer relying on outlines and symbol maps already in context.
    - After an edit, you do NOT need to re‑read the file unless the edit failed.
    - If a tool returns a warning about duplication, try a different approach.

    Now follow the user's instruction.
    ]]

    orient = [[Analyse this software project and produce two markdown sections.

## OVERVIEW
  Summary (800 worssds max):
  - What the project does
  - Main language(s) and frameworks
  - Key architectural patterns
  - Important entry points / commands

## STRUCTURE
  Copy the file tree below and annotate each significant file/directory with a comment (after a #).
  Skip lock files and generated directories.

  Output ONLY the two sections above, valid markdown, nothing else.]],

  --   fileops = [[When you need to modify files, use <wellm_edit> blocks with search/replace:

  -- <wellm_edit path="relative/path.py">
  -- <search>
  -- exact existing code block you want to replace
  -- </search>
  -- <replace>
  -- new code block
  -- </replace>
  -- </wellm_edit>

  -- Rules:
  -- - To delete code: put empty <replace></replace> (or omit replace tag)
  -- - To prepend: leave <search> empty (or omit search tag)
  -- - The search block must match the existing code EXACTLY (including indentation and blank lines).
  -- - Multiple edits are applied in the order you write them.
  -- - Each edit works on the result of previous edits.
  -- When making multiple edits to the same file in one response:
  -- - The first edit changes the file content.
  -- - Subsequent edits must **search for the content AFTER the previous edit**.
  -- - Always put <search> before <replace>. Never swap them.
  -- - If you need to revert a change, use the current state as search.

  -- Example: replace hello_world with foo_bar
  -- <wellm_edit path="fibonacci.py">
  -- <search>
  -- def hello_world():
  --     """Print a hello world message."""
  --     print("Hello, World!")
  -- </search>
  -- <replace>
  -- def foo_bar():
  --     """Print a foo bar message."""
  --     print("Foo, Bar!")
  -- </replace>
  -- </wellm_edit>

  -- To delete a duplicate line, search for the exact line and leave replace empty.
  -- To add a call inside main, search for the line inside the main block and replace with extended version.
  -- Never use line numbers. Always copy-paste the exact code from the context.]]
  },

  keys = {
    replace    = { "<leader>cr",  mode = "v", desc = "AI Replace Selection"     },
    insert     = { "<leader>cc",  mode = "n", desc = "AI Insert at Cursor"      },
    chat       = { "<leader>ca",  mode = "n", desc = "Open AI Chat"             },
    add_file   = { "<leader>caf", mode = "n", desc = "AI: Add File to Context"  },
    add_folder = { "<leader>cad", mode = "n", desc = "AI: Add Folder to Context"},
    clear_ctx  = { "<leader>cac", mode = "n", desc = "AI: Clear Context"        },
    picker     = { "<leader>cap", mode = "n", desc = "AI: File Picker"          },
    history    = { "<leader>ch",  mode = "n", desc = "AI: Session History"      },
    usage      = { "<leader>cu",  mode = "n", desc = "AI: Usage & Cost"         },
    orient     = { "<leader>co",  mode = "n", desc = "AI: Orient Project"       },
  },
}

return M
