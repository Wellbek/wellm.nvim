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
  filechanges = "filechanges_confirm", -- "filechanges_off" | "filechanges_confirm" | "filechanges_on"

  wellagent = {
    enabled          = true,
    auto_init        = true,   -- create .wellagent on first use
    auto_orient      = true,   -- generate OVERVIEW/STRUCTURE if missing
    ignored_patterns = {
      "%.git", "node_modules", "%.wellagent", "__pycache__",
      "%.pyc", "%.class", "dist", "build", "target", "%.cache",
    },
  },

  sessions = {
    save_automatically = true,
    max_sessions       = 100,
  },

  prompts = {
    coding = [[You are an expert software engineer in Neovim (Wellm plugin).

  OUTPUT RULES:
  - Replace/Insert: raw code only, no markdown fences, no explanations.
  - Chat/Explain: Markdown, thorough, with examples.
  - After significant changes, add a line: [DECISION: one-line summary]

  FILE ACCESS:
  If you need to read a project file before answering, put the request on its own line:
  [READ: lua/wellm/llm.lua]
  Use the Repo Map and Project Structure to find real paths. Only request files that exist.
  The marker must be the only thing on that line. Never embed it in prose, code blocks, or examples.

  STYLE:
  - Comments: brief, practical, inline. No headings, no decorative lines, no tutorials.
  - ASCII only. No emojis, no unicode arrows (use -> or =>), no section separators.
  - Prioritise: correctness -> readability -> project conventions.]],

    chat = [=[You are a helpful AI coding assistant inside Neovim.

  FILE ACCESS:
  If you need to read a project file, put the request on its own separate line:
  [READ: lua/wellm/init.lua]
  Use the Repo Map and Project Structure sections to find real paths.
  Only request files that exist. The marker must be alone on its own line.

  After significant changes, add a line: [DECISION: one-line summary]]=],

    orient = [[Analyse this software project and produce two markdown sections.

## OVERVIEW
  Concise summary (200 words max):
  - What the project does
  - Main language(s) and frameworks
  - Key architectural patterns
  - Important entry points / commands

## STRUCTURE
  Copy the file tree below and annotate each significant file/directory with a comment (after a #).
  Skip lock files and generated directories.

  Output ONLY the two sections above, valid markdown, nothing else.]],

  fileops = [[When you need to create or modify files, output each file using this exact format:

<wellm_file path="relative/path/to/file.ext">
complete file content here
</wellm_file>

Rules:
- You may include multiple <wellm_file> blocks in your response.
- Always provide the COMPLETE file content, not partial diffs.
- Use relative paths from the project root.
- File deletion is NOT supported — never attempt to delete files.
- You can mix explanatory text with <wellm_file> blocks freely.]],
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
