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

-- Model-specific context windows (tokens).  Used by build_payload to truncate
-- messages before they exceed the model's limit.
M.context_windows = {
  -- Claude
  ["claude-opus-4-7"]   = 200000,
  ["claude-opus-4-6"]   = 200000,
  ["claude-opus-4-5"]   = 200000,
  ["claude-sonnet-4-6"] = 200000,
  ["claude-sonnet-4-5"] = 200000,
  ["claude-haiku-4-5"]  = 200000,
  ["claude-haiku-3-5"]  = 200000,
  ["claude-haiku-3"]    = 200000,
  -- GLM (context windows; note: max_tokens ≠ context_window)
  -- glm-5.2 supports up to 128k OUTPUT but has a 1M token context window.
  -- glm-5/5.1/5-turbo have 128k context.
  -- glm-4.x models have 128k context.
  ["glm-5.2"]           = 1000000,
  ["glm-5.1"]           = 128000,
  ["glm-5"]             = 128000,
  ["glm-5-turbo"]       = 128000,
  ["glm-4.7"]           = 128000,
  ["glm-4.7-flashx"]    = 128000,
  ["glm-4.6"]           = 128000,
  ["glm-4.5"]           = 128000,
  ["glm-4.5-x"]         = 128000,
  ["glm-4.5-air"]       = 128000,
  ["glm-4.5-airx"]      = 128000,
  ["glm-4.32b"]         = 128000,
  ["glm-4.7-flash"]     = 128000,
  ["glm-4.5-flash"]     = 128000,
}

-- Default context window when model is not in M.context_windows.
-- Set conservatively (128k) to avoid exceeding limits on unknown models.
M.default_context_window = 128000

M.defaults = {
  provider     = "anthropic",
  api_key_name = "ANTHROPIC_API_KEY",
  api_key      = nil,
  model        = "claude-sonnet-4-5",
  max_tokens   = 8192,
  context_window = nil,  -- auto-detected from M.context_windows[model]; fallback 128000
  -- output_reserve is validated at runtime to always be >= max_tokens
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
    output_reserve       = 8192,   -- must be >= max_tokens to prevent overflow
    context_safety_margin = 0.15,  -- reserve 15% of context window as safety buffer
    max_tool_rounds      = 30,     -- hard cap on tool call loops per request
    duplicate_tolerance  = 10,     -- allow this many duplicate tool calls before stopping
    save_interval_chars  = 2000,   -- auto-save session every N characters during streaming
    summary_model        = nil,    -- model for rolling summaries (nil = auto: cheapest available)
    budget_packing       = true,   -- use token-budget-aware packing instead of fixed turn window
  },

  prompts = {
    coding = [[You are performing a direct code transformation.

    Use edit_file immediately.

    Do not explain changes.
    Do not provide code fences.
    Do not provide analysis.

    When creating files:
    use edit_file with the full content.

    After successful modification output:

    [DONE]

    Nothing else.]],

    chat = [[
      You are a software implementation agent working inside Neovim.

      Your primary goal is to produce completed code changes.

      Success is measured by:
      - files modified
      - bugs fixed
      - features implemented

      NOT by:
      - explanations
      - planning
      - code reviews
      - architectural discussions

      DEFAULT BEHAVIOR

      If enough information exists to implement a change:

      DO NOT:
      - explain the plan
      - discuss alternatives
      - ask for permission
      - summarize code
      - restate the request

      DO:
      - locate target files
      - edit files
      - validate
      - stop

      IMPLEMENTATION RULES

      Maximum reconnaissance before first edit: 5 tool calls.

      After at most 5 reads:
      - make an edit
      OR
      - explain exactly what information is missing

      Never continue exploring indefinitely.

      If a file has already been read during the current task:
      do not read it again unless:
      - an edit failed
      - another tool modified it

      Never reread unchanged files.

      WORKFLOW

      1. Identify target file(s)
      2. Read minimum code required
      3. Edit immediately
      4. Validate if possible
      5. Stop

      TASK COMPLETION

      A task is complete when:
      - requested changes are written
      - files are saved
      - validation ran OR cannot be run

      Immediately terminate afterwards.

      Do not continue looking for improvements.
      Do not perform unrelated refactors.

      USER OVERRIDES

      If the user says:
      - implement it
      - just do it
      - stop explaining
      - function calls only

      Then reasoning text is forbidden.

      The next response must begin with a tool call.

      OUTPUT RULES

      Before completion:
      - tool calls only

      After completion:
      output only:

      [DONE]

      or

      [DONE: short summary]

      Never describe future actions.
      Never narrate what you are about to do.
    ]],

    orient = [[Analyse this software project and produce two markdown sections.

## OVERVIEW
  Summary (800 words max):
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
