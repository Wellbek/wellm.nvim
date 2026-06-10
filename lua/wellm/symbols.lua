-- wellm/symbols.lua
-- Extract compact symbol maps (functions, classes, variables) from source files.
-- Uses tree-sitter if available, falls back to regex.

local M = {}

-- Tree-sitter queries per language (basic, extend as needed)
local queries = {
  lua = [[
    (function_declaration name: (identifier) @name) @func
    (local_function name: (identifier) @name) @func
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

-- Regex fallback (language‑agnostic)
local function regex_extract(content)
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
  -- module.exports = { ... } -> not captured well, but fine
  return symbols
end

--- Extract symbols from file content.
--- @param path string (for filetype detection)
--- @param content string
--- @return table { symbols = string[], language = string }
function M.extract_symbols(path, content)
  local lang = vim.filetype.match({ filename = path }) or "lua"
  local symbols = {}
  
  -- Try tree-sitter first
  local parser = vim.treesitter.get_parser(0, lang)
  if parser and parser:parse() then
    local tree = parser:parse()[1]
    if tree then
      local query_str = queries[lang]
      if query_str then
        local query = vim.treesitter.query.parse(lang, query_str)
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
  
  -- Fallback to regex
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
--- @param content string
--- @param max_symbols number|nil (default 50)
--- @return string
function M.build_outline(path, content, max_symbols)
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