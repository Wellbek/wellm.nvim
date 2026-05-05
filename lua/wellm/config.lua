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
  ["glm-5-1"]           = { input = 1.4,   output = 4.4  },
  ["glm-5"]             = { input = 1.0,   output = 3.2  },
  ["glm-5-turbo"]       = { input = 1.2,   output = 4.0  },
  ["glm-4-7"]           = { input = 0.6,   output = 2.2  },
  ["glm-4-7-flashx"]    = { input = 0.07,  output = 0.4  },
  ["glm-4-6"]           = { input = 0.6,   output = 2.2  },
  ["glm-4-5"]           = { input = 0.6,   output = 2.2  },
  ["glm-4-5-x"]         = { input = 2.2,   output = 8.9  },
  ["glm-4-5-air"]       = { input = 0.2,   output = 1.1  },
  ["glm-4-5-airx"]      = { input = 1.1,   output = 4.5  },
  ["glm-4-32b"]         = { input = 0.1,   output = 0.1  },

  -- Free tiers (treated as zero cost)
  ["glm-4-7-flash"]     = { input = 0.0,   output = 0.0  },
  ["glm-4-5-flash"]     = { input = 0.0,   output = 0.0  },
}

M.defaults = {
  provider     = "anthropic",
  api_key_name = "ANTHROPIC_API_KEY",
  api_key      = nil,
  model        = "claude-sonnet-4-5",
  max_tokens   = 8192,

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
    coding = [[You are an expert Senior Software Engineer integrated into Neovim via the Wellm plugin.

BEHAVIOUR:
- For Replace/Insert actions: output ONLY the code, no markdown fences, no explanations.
- For Chat/Explain: use Markdown, be thorough, include examples.
- When you need to read a file to answer properly, output exactly: [READ: path/to/file]
- Use the Project Context (OVERVIEW, STRUCTURE, DECISIONS) to avoid re-reading files you already understand.
- Append a one-line summary of significant changes to DECISIONS when relevant, prefixed with [DECISION].

Prioritise: correctness → readability → existing project conventions.

COMMENT STYLE:
- Write comments like an experienced developer, not a tutorial.
- Keep comments short and practical, not explanatory essays.
- Avoid stating the obvious (e.g., "increment i").
- Prefer inline comments over block sections.
- Use plain sentences, no formatting, no headings.
- No emojis, no unicode symbols, ASCII only.
- Do not use separators like ====, ----, or decorative blocks.
- Never use labels like "Main Logic", "Step 1", etc.
- Comments should feel like they were written quickly during development.

FORBIDDEN IN CODE OUTPUT:
- No emojis or unicode symbols (only standard ASCII characters)
- No arrows like →, ⇒ (use -> or => if needed)
- No section headers (e.g., "# ==== Something ====")
- No verbose block comments explaining entire functions
- No "Here we..." / "This function..." / "Your approach ..." style explanations
]],

    chat = [[You are a helpful AI coding assistant inside Neovim (Wellm plugin).
You have access to project context and selected files.
Be concise. Use Markdown. Show code examples when useful.
When you need to read a specific file to answer, output: [READ: path/to/file]]],

    orient = [[Analyse this software project and produce two markdown sections.

## OVERVIEW
Concise summary (200 words max):
- What the project does
- Main language(s) and frameworks
- Key architectural patterns
- Important entry points / commands

## STRUCTURE
Copy the file tree below and annotate each significant file/directory with a short comment (≤8 words) after a `#`.
Skip lock files and generated directories.

Output ONLY the two sections above, valid markdown, nothing else.]],
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
