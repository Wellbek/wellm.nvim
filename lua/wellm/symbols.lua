-- wellm/symbols.lua
-- Extract compact symbol maps (functions, classes, variables) from source files.
-- Uses tree-sitter if available, falls back to regex.

local M = {}

-- Tree-sitter queries per language (basic, extend as needed)
-- These queries are tested against Neovim's built-in parsers.
local queries = {
  lua = [[
    (function_declaration name: (identifier) @name) @func
    (assignment_statement
      left: (variable_list (identifier) @var)
      right: (function_definition) @func)
    (local_variable_declaration
      name: (identifier) @var)
    (function_call name: (dot_index_expression) @name) @call
  ]],
  python = [[
    (function_definition name: (identifier) @name) @func
    (class_definition name: (identifier) @name) @class
    (assignment left: (identifier) @var)
  ]],
  javascript = [[
    (function_declaration name: (identifier) @name) @func
    (class_declaration name: (identifier) @name) @class
    (variable_declaration (variable_declarator name: (identifier) @var))
    (method_definition name: (property_identifier) @name) @func
  ]],
  typescript = [[
    (function_declaration name: (identifier) @name) @func
    (class_declaration name: (identifier) @name) @class
    (variable_declaration (variable_declarator name: (identifier) @var))
    (method_definition name: (property_identifier) @name) @func
    (interface_declaration name: (identifier) @name) @class
  ]],
  go = [[
    (function_declaration name: (identifier) @name) @func
    (method_declaration name: (field_identifier) @name) @func
    (type_declaration (type_spec name: (identifier) @name)) @class
  ]],
  rust = [[
    (function_item name: (identifier) @name) @func
    (impl_item (method name: (identifier) @name)) @func
    (struct_item name: (identifier) @name) @class
    (enum_item name: (identifier) @name) @class
  ]],
}

-- Helper to safely parse a query (returns nil on error)
local function safe_parse_query(lang, query_str)
  local ok, parser = pcall(vim.treesitter.query.parse, lang, query_str)
  if not ok then
    return nil
  end
  return parser
end

-- Regex fallback (language‑agnostic) – expects content to be a non‑nil string
local function regex_extract(content)
  if not content or content == "" then
    return {}
  end
  local symbols = {}
  -- function name(
  for name in content:gmatch("function%s+(%w+)[%s]*%(") do
    table.insert(symbols, name .. "()")
  end
  -- def name(
  for name in content:gmatch("def%s+(%w+)[%s]*%(") do
    table.insert(symbols, name .. "()")
  end
  -- class Name
  for name in content:gmatch("class%s+(%w+)") do
    table.insert(symbols, "class " .. name)
  end
  -- local name =
  for name in content:gmatch("local%s+(%w+)%s*=") do
    table.insert(symbols, name)
  end
  -- name = (global)
  for name in content:gmatch("^(%w+)%s*=") do
    table.insert(symbols, name)
  end
  return symbols
end

--- Extract symbols from file content.
--- @param path string (for filetype detection)
--- @param content string|nil
--- @return table { symbols = string[], language = string }
function M.extract_symbols(path, content)
  if not content or content == "" then
    return { symbols = {}, language = vim.filetype.match({ filename = path }) or "unknown" }
  end

  local lang = vim.filetype.match({ filename = path }) or "lua"
  local symbols = {}
  
  -- Try tree-sitter first
  local ok, parser = pcall(vim.treesitter.get_parser, 0, lang)
  if ok and parser then
    local tree = parser:parse()[1]
    if tree then
      local query_str = queries[lang]
      if query_str then
        local query = safe_parse_query(lang, query_str)
        if query then
          for id, node in query:iter_captures(tree:root(), 0) do
            local name = vim.treesitter.get_node_text(node, 0)
            if name then
              local cap = query.captures[id]
              if cap == "func" then table.insert(symbols, name .. "()")
              elseif cap == "class" then table.insert(symbols, "class " .. name)
              elseif cap == "var" then table.insert(symbols, name)
              elseif cap == "call" then table.insert(symbols, name .. "() (call)")
              end
            end
          end
        end
      end
    end
  end
  
  -- Fallback to regex if tree‑sitter gave nothing
  if #symbols == 0 then
    symbols = regex_extract(content)
  end
  
  -- Deduplicate
  local seen = {}
  local unique = {}
  for _, s in ipairs(symbols) do
    if not seen[s] then
      seen[s] = true
      table.insert(unique, s)
    end
  end
  
  return { symbols = unique, language = lang }
end

--- Build a human‑readable outline (e.g., for injection into context).
--- @param path string
--- @param content string|nil
--- @param max_symbols number|nil (default 50)
--- @return string
function M.build_outline(path, content, max_symbols)
  if not content or content == "" then
    return "-- " .. path .. " (empty or unreadable)\n  [no symbols]"
  end
  max_symbols = max_symbols or 50
  local extracted = M.extract_symbols(path, content)
  local syms = extracted.symbols
  if #syms > max_symbols then
    syms = { table.unpack(syms, 1, max_symbols) }
    table.insert(syms, "... (+" .. (#extracted.symbols - max_symbols) .. " more)")
  end
  local outline = "-- " .. path .. " (" .. extracted.language .. ")\n"
  for _, sym in ipairs(syms) do
    outline = outline .. "  " .. sym .. "\n"
  end
  return outline
end

return M