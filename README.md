# wellm.nvim

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Neovim](https://img.shields.io/badge/Requires-Neovim%200.9%2B-green.svg)](https://neovim.io)
[![Lua](https://img.shields.io/badge/Written%20in-Lua-000080.svg)](https://www.lua.org)
[![LLM](https://img.shields.io/badge/Providers-Anthropic%20%7C%20Zhipu-orange.svg)](lua/wellm/providers/)

A fully asynchronous, streaming LLM integration for Neovim. Chat with AI, manage conversational history, build persistent project context, and let the model read and write files - all within the vim editor.

wellm.nvim uses a **function‑calling (tool) interface** for file operations, drastically reducing token usage and eliminating brittle regex parsing. It features **symbol outline injection** (replace whole files with compact lists of functions, classes, and variables), **diff‑based re‑reads** (after an edit, the model receives only what changed), and an **action‑oriented system prompt** that cuts reasoning preambles by 50%.

---

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Providers](#providers)
- [Default Keymaps](#default-keymaps)
- [Commands](#commands)
- [Chat Window](#chat-window)
- [File Picker](#file-picker)
- [Session History](#session-history)
- [Context Management](#context-management)
- [Smart Context & Summarization](#smart-context--summarization)
  - [Rolling Summary Memory](#rolling-summary-memory)
  - [Symbol Outline Injection](#symbol-outline-injection)
  - [Diff‑Based Re‑Reads](#diffbased-re-reads)
  - [Chunk‑Based File Retrieval](#chunkbased-file-retrieval)
  - [Knowledge Indexing](#knowledge-indexing)
  - [Token Budget Guard](#token-budget-guard)
- [LLM Tool Interface](#llm-tool-interface)
- [File Operations via Tools](#file-operations-via-tools)
- [Project Orientation](#project-orientation)
- [Decision Log](#decision-log)
- [Usage and Cost Tracking](#usage-and-cost-tracking)
- [The .wellagent Folder](#the-wellagent-folder)
- [Architecture](#architecture)
- [Adding a New Provider](#adding-a-new-provider)
- [Updating Pricing](#updating-pricing)
- [License](#license)

---

## Features

- **Streaming chat** - tokens appear in real time in a dedicated split‑right window.
- **AI Replace / AI Insert** - select code in visual mode and ask the LLM to replace it, or generate new code at the cursor.
- **Multi‑provider** - Anthropic (Claude) and Zhipu (GLM) out of the box; any OpenAI‑compatible API can be added.
- **Function calling (tools)** - the LLM uses native `read_file`, `edit_file`, and `edit_file_multiple` tools instead of brittle hand‑parsed markers.
- **Symbol outline injection** - when a file is added with a query, only its function/class/variable outline is injected (90% token reduction).
- **Diff‑based re‑reads** - after an edit, subsequent `read_file` calls return a unified diff instead of the full file (95% reduction).
- **Action‑oriented system prompt** - the model is told to “act, don’t narrate”, cutting output tokens by 30-50% and eliminating “wait… actually…” loops.
- **Persistent project context** - the `.wellagent/` folder stores an LLM‑generated project overview, annotated file tree, and a rolling decision log, all injected into every request automatically.
- **Project orientation** - one command generates `OVERVIEW.md` and `STRUCTURE.md` from your codebase.
- **Session history** - conversations are saved as JSON + Markdown. Browse, preview, resume, or delete past sessions from a floating UI.
- **Context file picker** - a floating checkbox tree lets you select which project files to include in the LLM’s context.
- **Token and cost tracking** - per‑model, per‑month usage with estimated cost based on provider pricing tables.
- **Smart context & summarization** - rolling summary, chunk‑based file retrieval, knowledge indexing, and a token budget guard keep context size predictable.
- **Fully async** - all API calls run through `vim.fn.jobstart`; the editor never freezes.

---

## Requirements

- Neovim 0.9 or later
- `curl` installed and available on `$PATH`
- An API key for at least one supported provider (Anthropic or Zhipu)

---

## Installation

### lazy.nvim

```lua
{
  "wellbek/wellm.nvim",
  config = function()
    require("wellm").setup({
      provider     = "anthropic",
      api_key_name = "ANTHROPIC_API_KEY",
      model        = "claude-sonnet-4-5",
      max_tokens   = 8192,
    })
  end,
}
```

### packer.nvim

```lua
use {
  "wellbek/wellm.nvim",
  config = function()
    require("wellm").setup({
      provider     = "anthropic",
      api_key_name = "ANTHROPIC_API_KEY",
      model        = "claude-sonnet-4-5",
      max_tokens   = 8192,
    })
  end,
}
```

### Manual / vim‑plug

```vim
Plug 'wellbek/wellm.nvim'
```

Then in your `init.lua`:

```lua
require("wellm").setup({
  provider     = "anthropic",
  api_key_name = "ANTHROPIC_API_KEY",
  model        = "claude-sonnet-4-5",
})
```

---

## Configuration

Call `require("wellm").setup(opts)` in your Neovim config. All options have sane defaults; you only need to override what you want to change.

```lua
require("wellm").setup({
  -- Provider and authentication
  provider     = "anthropic",          -- "anthropic" or "zhipu"
  api_key_name = "ANTHROPIC_API_KEY",  -- env var name to read the key from
  api_key      = nil,                  -- or hardcode the key (not recommended)
  model        = "claude-sonnet-4-5",  -- default model
  max_tokens   = 8192,                 -- max tokens per response

  -- File change behavior (via tools)
  -- "filechanges_off"     -- ignore all edit proposals
  -- "filechanges_confirm" -- show a dialog before applying (default)
  -- "filechanges_on"      -- apply changes automatically
  filechanges = "filechanges_confirm",

  -- Wellagent: persistent project context
  wellagent = {
    enabled          = true,
    auto_init        = true,
    auto_orient      = true,
    max_entries_before_summarize = 8,
    ignored_patterns = {
      "%.git", "node_modules", "%.wellagent", "__pycache__",
      "%.pyc", "%.class", "dist", "build", "target", "%.cache",
    },
  },

  -- Session persistence
  sessions = {
    save_automatically = true,
    max_sessions       = 100,
    summary_turns      = 6,            -- keep this many full turns + rolling summary
  },

  -- Context chunking and expiration
  context = {
    chunk_size    = 50,                -- lines per chunk (used by chunker)
    smart_top_k   = 3,                 -- top chunks to inject when query given
    item_ttl      = 1,                 -- turns before auto‑expiration
  },

  -- Token budget protection
  llm = {
    output_reserve       = 2048,       -- tokens reserved for model response
    max_tool_rounds      = 30,         -- hard cap on tool‑call loops
    duplicate_tolerance  = 5,          -- allow this many duplicate tool calls before stopping
    save_interval_chars  = 2000,       -- auto‑save session during streaming
  },

  -- Prompt templates
  prompts = {
    coding = "...",   -- system prompt for replace/insert/orient
    chat   = "...",   -- action‑oriented system prompt for chat mode
    orient = "...",   -- system prompt for project orientation
  },

  -- Keymaps (set to false or remove to disable a binding)
  keys = {
    replace    = { "<leader>cr",  mode = "v", desc = "AI Replace Selection"     },
    insert     = { "<leader>cc",  mode = "n", desc = "AI Insert at Cursor"      },
    chat       = { "<leader>ca",  mode = "n", desc = "Open AI Chat"             },
    add_file   = { "<leader>caf", mode = "n", desc = "AI: Add File to Context"  },
    add_folder = { "<leader>cad", mode = "n", desc = "AI: Add Folder to Context"},
    clear_ctx  = { "<leader>cac", mode = "n", desc = "AI: Clear Context"        },
    picker     = { "<leader>cap", mode = "n", desc = "AI: File Picker"          },
    history    = { "<leader>ch",  mode = "n", desc = "AI: Session History"      },
    usage      = { "<leader>cu",  mode = "n", desc = "AI: Usage and Cost"       },
    orient     = { "<leader>co",  mode = "n", desc = "AI: Orient Project"       },
  },

  skip_default_mappings = false,
})
```

### API Key Resolution

The plugin resolves your API key in the following order:

1. `api_key` field in setup (if set directly)
2. Environment variable named by `api_key_name` (default: `ANTHROPIC_API_KEY`)
3. If neither is found, a warning is shown on startup

For Zhipu, change the config accordingly:

```lua
require("wellm").setup({
  provider     = "zhipu",
  api_key_name = "ZHIPU_API_KEY",
  model        = "glm-4.7-flashx",
})
```

---

## Providers

wellm.nvim ships with two providers. They share the same interface so you can switch freely.

| Provider   | Default Model          | API                                            |
|------------|------------------------|------------------------------------------------|
| `anthropic`| `claude-sonnet-4-5`    | `api.anthropic.com/v1/messages`                |
| `zhipu`    | `glm-4.7-flashx`       | `open.bigmodel.cn/api/paas/v4/chat/completions`|

Both providers support streaming and native function calling. The provider is selected at setup time but can be changed at runtime by modifying `require("wellm").config.provider`.

See [Adding a New Provider](#adding-a-new-provider) for instructions on integrating additional LLM backends.

---

## Default Keymaps

| Key             | Mode | Action                              |
|-----------------|------|-------------------------------------|
| `<leader>ca`    | n    | Open chat window                    |
| `<leader>cr`    | v    | Replace selection with AI           |
| `<leader>cc`    | n    | Insert AI output at cursor          |
| `<leader>cap`   | n    | Open file picker (checkbox tree)    |
| `<leader>ch`    | n    | Open session history browser        |
| `<leader>cu`    | n    | Show monthly usage and cost         |
| `<leader>co`    | n    | Re‑orient project                   |
| `<leader>caf`   | n    | Add current file to context         |
| `<leader>cad`   | n    | Add folder to context               |
| `<leader>cac`   | n    | Clear context and history           |

---

## Commands

| Command                      | Description                                     |
|------------------------------|-------------------------------------------------|
| `:WellmChat`                 | Open the chat window                            |
| `:WellmReplace`              | Replace visual selection (range command)        |
| `:WellmInsert`               | Insert AI output at cursor                      |
| `:WellmPicker`               | Open file picker                                |
| `:WellmHistory`              | Browse session history                          |
| `:WellmUsage`                | Show monthly usage and cost                     |
| `:WellmOrient`               | Re‑generate OVERVIEW.md and STRUCTURE.md        |
| `:WellmAddFile`              | Add current file to context                     |
| `:WellmAddFolder`            | Add folder to context                           |
| `:WellmClear`                | Clear all context and history                   |
| `:WellmSystem`               | Edit the system prompt for this session         |
| `:WellmModel [name]`         | Switch model mid‑session (no arg = show current)|
| `:WellmNewSession`           | Save current session, start a fresh one         |
| `:WellmFilechanges`          | Cycle file‑changes mode: off / confirm / on     |
| `:WellmDecision <text>`      | Manually append an entry to DECISIONS.md        |

---

## Chat Window

The chat window opens as a vertical split on the right. Conversation history is rendered as Markdown with `## YOU` and `## ASSISTANT` headings. The input line at the bottom is always editable.

| Key           | Action                                   |
|---------------|------------------------------------------|
| `<CR>`        | Send message (works in normal + insert)  |
| `i` / `A`     | Jump to input line in insert mode        |
| `q`           | Close the chat window                    |
| `<C-c>`       | Cancel the running request               |
| `<leader>cn`  | New conversation (saves current first)   |

Streaming responses are rendered token‑by‑token. If the LLM calls tools (e.g., `read_file`, `edit_file`), the UI shows a spinner and the tool results are processed automatically; after each tool round the conversation continues.

---

## File Picker

A floating window with a checkbox‑annotated file tree. Select the files you want included in the LLM’s context for the current conversation.

| Key       | Action                                     |
|-----------|--------------------------------------------|
| `<Space>` | Toggle file; on a directory, toggle all children |
| `a`       | Select all files                           |
| `n`       | Deselect all files                         |
| `<CR>`    | Confirm selection and load into context    |
| `q`/`Esc` | Cancel and close                           |

Files already in context are pre‑selected when the picker opens. Binary files, hidden files, and common noise directories (`.git`, `node_modules`, etc.) are automatically excluded.

---

## Session History

The history browser is a dual‑pane floating window: a session list on the left and a Markdown preview on the right.

| Key       | Action                              |
|-----------|-------------------------------------|
| `j`/`k`   | Navigate between sessions           |
| `<CR>`    | Load session and continue in chat   |
| `d`       | Delete session (with confirmation)  |
| `q`/`Esc` | Close the browser                   |

Sessions are stored as JSON (full state) and Markdown (human‑readable preview) under `.wellagent/sessions/`, indexed in `.wellagent/index.json`. The maximum number of stored sessions is configurable via `sessions.max_sessions` (default: 100).

---

## Context Management

Context files are injected into every LLM request alongside the user’s message. This lets you give the model specific code to work with without copying and pasting.

- **Add current file**: `<leader>caf` or `:WellmAddFile`
- **Add a folder**: `<leader>cad` or `:WellmAddFolder`
- **Pick files visually**: `<leader>cap` or `:WellmPicker`
- **Clear everything**: `<leader>cac` or `:WellmClear`

Files are stored by absolute path and de‑duplicated. Binary files, lock files, minified assets, and similar noise are automatically skipped.

When a file is added **with a query** (e.g., via the smart picker or automatically from the LLM’s need), the plugin injects only a **symbol outline** instead of the full content - a compact list of function names, classes, and top‑level variables. This reduces token usage by 70-90%.

---

## Smart Context & Summarization

Long conversations and large file injections can quickly fill the model’s context window. wellm.nvim implements five complementary mechanisms to keep context size small, predictable, and efficient.

### Rolling Summary Memory

Instead of sending the full conversation history every turn, the plugin maintains a compact **rolling summary**. After each assistant response, a cheap LLM call condenses the latest exchange into the existing summary. Only the last `summary_turns` (default 6) full turns are kept verbatim; older turns are replaced by the summary.

For a 20‑turn conversation (~15,000 tokens), this reduces token usage to ~800 tokens (summary) + 3 × ~1,000 tokens (recent turns) = **~3,800 tokens - a 75% reduction**.

### Symbol Outline Injection

When a file is added to context **with a query** (e.g., the user asks a specific question or the LLM requests a file by name), the plugin extracts a symbol outline instead of injecting the whole file. The outline includes:

- Function/method names with parentheses (`parse_config()`, `get_user()`)
- Class names prefixed with `class `
- Top‑level variable names
- Module/namespace identifiers

The extraction uses tree‑sitter (with a regex fallback) and is cached per file. For a 500‑line file (~4,000 tokens), an outline is typically **200‑400 tokens - a 90% reduction**. The LLM can still request the full content later (by calling `read_file` with `outline=false`) when it needs implementation details.

### Diff‑Based Re‑Reads

After an edit (via `edit_file` or `edit_file_multiple`), the LLM often wants to verify the change. Instead of returning the entire file on the next `read_file`, the plugin returns a **unified diff** showing only what changed, plus three lines of context. This reduces the token cost of a verification read from ~4,000 tokens to **~200 tokens - a 95% reduction**.

The diff is generated using Neovim’s `vim.diff` (or a fallback) and is presented in standard `git diff` format.

### Chunk‑Based File Retrieval

Files are split into chunks of `context.chunk_size` lines (default 50). When a file is added with a query, each chunk is scored by keyword overlap with the query (using the first line of the chunk as the signature). Only the top `context.smart_top_k` chunks (default 3) are injected.

Example: 500‑line file → 10 chunks. With a query that matches 3 chunks → `3 × 50 × 4 tokens/line = 600 tokens` instead of 2,000 - a **70% reduction**.

Chunks are cached with file mtime, and a TTL (`item_ttl`, default 1 turn) automatically expires them.

### Knowledge Indexing

The `.wellagent/context/KNOWLEDGE.md` file is stored with category headings (`## Category: <name>`). On each save, the plugin keeps an in‑memory map of categories, entry counts, and first lines. When loading knowledge with a query, it scans only the first line of each entry and returns at most 5 top‑scoring entries. Without a query, it returns only category headers and existing summaries.

A 30‑entry knowledge file (~3,000 tokens) → index scan of 30 lines (~300 tokens) + 3 relevant entries (~500 tokens) = **800 tokens - a 73% reduction**.

If a category exceeds `max_entries_before_summarize` (default 8), the plugin calls the LLM to condense older entries into a summary paragraph, keeping the file bounded.

### Token Budget Guard

Before every LLM call, wellm.nvim estimates the token count of the incoming request using a heuristic: `tokens ≈ bytes / 3.5 + 5 × num_messages`. It then checks:

```
estimated_input_tokens + llm.output_reserve <= context_window
```

If the estimate exceeds the model’s context window (default 200,000 tokens, covering all supported models), it trims the oldest message pair and retries once. This prevents API errors caused by oversized context.

---

## Token Savings Summary

| Mechanism | Before | After | Reduction |
|-----------|--------|-------|-----------|
| Rolling summary (20‑turn chat) | ~15,000 tokens | ~3,800 tokens | **75%** |
| Symbol outline injection (500 lines) | ~4,000 tokens | ~400 tokens | **90%** |
| Diff‑based re‑read (after edit) | ~4,000 tokens | ~200 tokens | **95%** |
| Chunk‑based file (500 lines) | ~2,000 tokens | ~600 tokens | **70%** |
| Knowledge index (30 entries) | ~3,000 tokens | ~800 tokens | **73%** |
| **Combined effect (typical session)** | ~20,000 tokens | ~5,000 tokens | **75%** |

Additionally, the action‑oriented system prompt reduces **output tokens** by 30-50%, cutting both cost and latency.

---

## LLM Tool Interface

wellm.nvim uses **function calling (tools)** instead of parsing ad‑hoc markers. The LLM is given three native tools:

| Tool | Description |
|------|-------------|
| `read_file(path, outline?)` | Read a file. If `outline=true`, returns only the symbol outline (cheaper). If `outline=false` (default) and the file has changed since last read, returns a unified diff instead of the full content. |
| `edit_file(path, search, replace)` | Replace the first occurrence of `search` with `replace`. After a successful edit, the session marks the file as dirty, and a snapshot is stored for future diff generation. |
| `edit_file_multiple(edits)` | Apply a list of search/replace edits in order, each on the result of the previous one. Useful for multiple changes to the same or different files. |

The tool definitions are provider‑agnostic - the plugin translates them to Anthropic’s or OpenAI’s function‑calling schema automatically.

The LLM is instructed to:

- Use `read_file` with `outline=true` first to discover what a file contains.
- Only request the full content (or the diff, after an edit) when necessary.
- Act immediately - no “Let me think” preambles.

This eliminates brittle regex parsing and gives the LLM a clean, token‑efficient interface.

---

## File Operations via Tools

All file modifications are performed through the `edit_file` and `edit_file_multiple` tools. The plugin handles path resolution (relative to the project root), backup snapshots, and buffer updates.

Three modes control how edits are applied:

| Mode                    | Behavior                                       |
|-------------------------|-------------------------------------------------|
| `filechanges_off`       | The tools are still called, but the edit is rejected with a message. |
| `filechanges_confirm`   | A dialog lists the proposed edit; user must approve. |
| `filechanges_on`        | Edits are applied automatically.                |

Cycle between modes with `:WellmFilechanges` or `<leader>cf` (if mapped). The default is `filechanges_confirm`.

Safety constraints:
- The `search` string must match exactly (including indentation) for the edit to succeed.
- Paths containing `..` are rejected.
- After an edit, any open buffer for that file is reloaded (`:checktime`).

---

## Project Orientation

Running `:WellmOrient` (or `<leader>co`) sends your project’s file tree to the LLM and asks it to generate two documents:

- **OVERVIEW.md** - a concise summary of what the project does, its languages, frameworks, architectural patterns, and key entry points.
- **STRUCTURE.md** - the annotated file tree with comments on significant files and directories.

These are stored in `.wellagent/context/` and automatically prepended to the system prompt on every subsequent LLM call. This means the model always has high‑level project knowledge without you having to re‑explain it.

If `wellagent.auto_orient` is `true` (the default), orientation runs automatically on first buffer open when no OVERVIEW.md exists.

---

## Decision Log

The LLM is instructed to emit `[DECISION: one‑line summary]` lines after significant changes. wellm.nvim automatically extracts these from responses and appends them to `.wellagent/context/DECISIONS.md` with a timestamp.

You can also manually log decisions:

```vim
:WellmDecision Migrated auth module from JWT to session tokens
```

The decision log is included in the system context, giving the LLM a rolling memory of architectural choices and trade‑offs across sessions.

---

## Usage and Cost Tracking

wellm.nvim records token usage per model per calendar month in `.wellagent/usage.json`. The `:WellmUsage` command (or `<leader>cu`) opens a floating window showing:

- A per‑model breakdown of input tokens, output tokens, and estimated cost
- Monthly totals
- All months with recorded data

Costs are estimated from the pricing table in `config.lua`. See [Updating Pricing](#updating-pricing) for how to keep rates current.

---

## The .wellagent Folder

wellm.nvim stores all project‑specific data under `.wellagent/` at your project root. This folder is created automatically when `wellagent.auto_init` is enabled.

```
.wellagent/
  context/
    OVERVIEW.md      - LLM‑generated project summary
    STRUCTURE.md     - annotated file tree
    DECISIONS.md     - rolling decision log
    KNOWLEDGE.md     - categorised, indexed knowledge entries
  sessions/
    2026-06-10T21-11-42.json    - full session state (JSON)
    2026-06-10T21-11-42.md      - human‑readable preview
    index.json       - session index for fast listing
  usage.json         - monthly token/cost ledger
  .gitignore         - prevents sessions from bloating the repo by default
```

The `.gitignore` is auto‑generated with sessions commented out so you can opt in to committing them if desired.

Project root is detected by searching upward for common markers: `.git`, `package.json`, `Cargo.toml`, `go.mod`, `pyproject.toml`, `setup.py`, `Makefile`, or an existing `.wellagent/` directory. Falls back to `getcwd()`.

---

## Architecture

```
lua/wellm/
  init.lua          - Plugin entry point: setup(), keymaps, user commands
  config.lua        - Default configuration and model pricing table
  state.lua         - Single mutable state table (history, context, UI refs)
  llm.lua           - Core API call logic, tool handling, streaming, orient
  actions.lua       - User‑facing actions: replace selection, insert at cursor
  context.lua       - Add/remove/clear context files; outline injection; chunking; TTL
  wellagent.lua     - .wellagent/ folder management, tree generation, knowledge indexing
  session.lua       - Session save/load/list; rolling summary; file snapshots for diffs
  usage.lua         - Token and cost tracking per model per month
  symbols.lua       - Tree‑sitter / regex symbol extraction (outline generation)
  diff.lua          - Unified diff generation (uses vim.diff or fallback)
  tools.lua         - Tool definitions and execution (read_file, edit_file, edit_file_multiple)
  providers/
    init.lua        - Provider registry and interface
    anthropic.lua   - Anthropic Messages API (streaming + tools)
    zhipu.lua       - Zhipu OpenAI‑compatible API (streaming + tools)
  ui/
    chat.lua        - Split‑right chat window with live streaming
    picker.lua      - Floating checkbox file‑tree picker
    history.lua     - Dual‑pane session history browser with preview
    usage.lua       - Monthly usage and cost visualization
    spinner.lua     - Non‑blocking loading spinner
```

### Data Flow

1. User triggers an action (keymap, command, or chat input).
2. `llm.lua` assembles the payload:
   - System prompt (with `.wellagent` context + rolling summary + user intent)
   - Message list (recent turns + summary)
   - Current user message with context files (outline‑injected where possible)
3. Token budget guard estimates size; trims oldest turns if needed.
4. The request is sent via `vim.fn.jobstart` (curl) to the selected provider, with tool definitions.
5. Streaming responses are rendered token‑by‑token in the chat UI.
6. If the LLM calls a tool (`read_file`, `edit_file`, `edit_file_multiple`):
   - The tool is executed (with user confirmation if in `confirm` mode).
   - The result is appended to the conversation.
   - The loop repeats (up to `max_tool_rounds`, default 30).
7. Token usage is recorded in `.wellagent/usage.json`.
8. The session is auto‑saved (JSON + Markdown) and the rolling summary is updated.
9. Any `[DECISION: ...]` lines are logged to `DECISIONS.md`.

---

## Adding a New Provider

Each provider is a Lua module that implements the following interface:

```lua
-- lua/wellm/providers/myprovider.lua
local M = {}

-- Build a buffered (non‑streaming) request table.
-- Returns: { url, headers, body }
function M.build_request(cfg, messages, system_prompt, tool_defs)
  return {
    url     = "https://api.example.com/v1/chat",
    headers = {
      "-H", "Authorization: Bearer " .. cfg.api_key,
      "-H", "content-type: application/json",
    },
    body = vim.fn.json_encode({
      model      = cfg.model,
      messages   = messages,
      tools      = tool_defs,   -- optional
      tool_choice = "auto",
      max_tokens = cfg.max_tokens,
    }),
  }
end

-- Build a streaming request (same as above but with stream = true).
function M.build_stream_request(cfg, messages, system_prompt, tool_defs)
  local req  = M.build_request(cfg, messages, system_prompt, tool_defs)
  local body = vim.fn.json_decode(req.body)
  body.stream = true
  req.body    = vim.fn.json_encode(body)
  return req
end

-- Parse one SSE line from the provider’s event stream.
-- Returns: delta_text (string|nil), tool_calls_fragments (table|nil),
--          usage (table|nil), is_done (boolean)
function M.parse_stream_line(line)
  -- Parse provider‑specific SSE format
  -- Return the text delta, any tool call fragments, usage data, and whether the stream is finished
end

-- Parse a buffered (non‑streaming) response.
-- Returns: content (string|nil), tool_calls (table|nil), usage (table|nil), error (string|nil)
function M.parse_response(decoded)
  -- Extract the assistant’s text, tool calls, usage data, and any error
end

return M
```

Then register it in `lua/wellm/providers/init.lua`:

```lua
local registry = {
  anthropic   = "wellm.providers.anthropic",
  zhipu       = "wellm.providers.zhipu",
  myprovider  = "wellm.providers.myprovider",
}
```

If you only implement `build_request` and `parse_response` (no streaming), wellm.nvim will gracefully fall back to buffered mode.

---

## Updating Pricing

Token costs are estimated from the `pricing` table in `lua/wellm/config.lua`. Edit it to reflect current rates:

```lua
M.pricing = {
  -- Anthropic Claude
  ["claude-sonnet-4-5"] = { input = 3.0, output = 15.0 },  -- USD per million tokens
  ["claude-haiku-4-5"]  = { input = 1.0, output = 5.0  },

  -- Zhipu GLM
  ["glm-4.7-flashx"]    = { input = 0.07, output = 0.4 },
  ["glm-4.5-air"]       = { input = 0.2,  output = 1.1 },

  -- Free tiers
  ["glm-4.7-flash"]     = { input = 0.0,  output = 0.0 },
}
```

The usage display includes a note that prices are estimates based on the configured rates.

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).

---

_Last updated: 2026-06-10_