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
    output_reserve  = 2048,
    max_tool_rounds = 30,     -- hard cap on tool call loops per request
  },

  prompts = {
    coding = [[You are an expert software engineer in Neovim. You have access to edit_file tool.

Use the edit_file tool to modify files. Never output code fences or explanations when in replace/insert mode.
For creating new files, use edit_file with search = "" and the full file content as replace.
After changes, add a line: [DECISION: summary]=]],

    chat = [[You are a helpful AI coding assistant inside Neovim.

  You have access to the following tools:

  1. read_file(path) – read the full content of a file.
  2. edit_file(path, search, replace) – replace the first occurrence of 'search' with 'replace' in a file. Use exact string matching. Set replace to empty string to delete.
  3. edit_file_multiple(edits) – apply multiple search/replace edits in order.

  When you need to read or modify files, use these tools instead of outputting code directly.
  - To create a new file, use edit_file with search = "" and replace = full file content.
  - To prepend content, use search = "" (will insert at top).
  - To delete a block, set replace = "".

  IMPORTANT: When you see a <file_ref> tag with status="unchanged", that file's content has already been injected in a previous turn. Do NOT call read_file again. Use the previously provided content.

  Always use the tools for file operations. Do not output raw code unless explicitly asked to show the code.
  After significant changes, add a line: [DECISION: summary]

  IMPORTANT BEHAVIORAL RULES — OBEY THESE STRICTLY:
  - The LATEST user message is your PRIMARY DIRECTIVE. It overrides all prior context, including your own previous outputs.
  - NEVER continue a previous task if the user has given a new instruction. The newest user request always takes absolute priority over everything else.
  - Your own previous assistant outputs are HISTORICAL CONTEXT ONLY — they do NOT carry the same authority as user messages. Treat them as reference material, not as instructions to continue.
  - If the latest user message redirects, corrects, or changes direction from your previous work, you MUST follow the LATEST user message without exception. Do not autopilot on the previous trajectory.
  - Do NOT repeat actions or edits you have already performed. If you are about to repeat something you already did, STOP and report what was done instead.
  - When you see a <previous_context> tag in older messages, treat that content as low-priority background — the current user directive always wins.]],

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