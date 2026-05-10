-- wellm/wellagent.lua
-- Manages the .wellagent project folder:
--   .wellagent/
--     config.json
--     context/OVERVIEW.md   — LLM-written project summary
--     context/STRUCTURE.md  — annotated file tree
--     context/DECISIONS.md  — rolling log of changes
--     sessions/<id>.md      — conversation history
--     index.json            — session index
--     usage.json            — token/cost ledger
local M = {}

local state = require("wellm.state")

-- Root detection 

local ROOT_MARKERS = {
  ".git", "package.json", "Cargo.toml", "go.mod", "pyproject.toml",
  "setup.py", "Makefile", ".wellagent",
}

local function find_project_root()
  local path = vim.fn.expand("%:p:h")
  if path == "" then path = vim.fn.getcwd() end

  for _ = 1, 12 do
    for _, marker in ipairs(ROOT_MARKERS) do
      local full = path .. "/" .. marker
      if vim.fn.filereadable(full) == 1 or vim.fn.isdirectory(full) == 1 then
        return path
      end
    end
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent == path then break end
    path = parent
  end

  return vim.fn.getcwd()
end

function M.get_root()
  if state.data.wellagent_root then
    return state.data.wellagent_root
  end
  local proj = find_project_root()
  state.data.project_root  = proj
  state.data.wellagent_root = proj .. "/.wellagent"
  return state.data.wellagent_root
end

function M.get_project_root()
  M.get_root() -- ensure populated
  return state.data.project_root
end

-- Directory helpers

function M.ensure_dirs()
  local root = M.get_root()
  for _, d in ipairs({ root, root .. "/context", root .. "/sessions" }) do
    vim.fn.mkdir(d, "p")
  end
  -- .gitignore so sessions don't bloat the repo by default
  local gi = root .. "/.gitignore"
  if vim.fn.filereadable(gi) == 0 then
    local f = io.open(gi, "w")
    if f then
      f:write("# Uncomment to exclude session history from git\n# sessions/\n")
      f:close()
    end
  end
end

-- Context file I/O 

function M.read_context(name)
  local path = M.get_root() .. "/context/" .. name
  if vim.fn.filereadable(path) == 1 then
    return table.concat(vim.fn.readfile(path), "\n")
  end
  return nil
end

function M.write_context(name, content)
  M.ensure_dirs()
  local path = M.get_root() .. "/context/" .. name
  local f = io.open(path, "w")
  if f then f:write(content); f:close(); return true end
  return false
end

function M.needs_orient()
  return M.read_context("OVERVIEW.md") == nil
end

-- File tree generation 

function M.generate_tree(root_path, ignored, depth, prefix)
  depth   = depth  or 0
  prefix  = prefix or ""
  ignored = ignored or {}
  if depth > 4 then return "" end

  local handle = vim.loop.fs_scandir(root_path)
  if not handle then return "" end

  local entries = {}
  while true do
    local name, ftype = vim.loop.fs_scandir_next(handle)
    if not name then break end
    local skip = false
    for _, pat in ipairs(ignored) do
      if name:match(pat) then skip = true; break end
    end
    if not skip then
      table.insert(entries, { name = name, type = ftype })
    end
  end

  table.sort(entries, function(a, b)
    if a.type ~= b.type then return a.type == "directory" end
    return a.name < b.name
  end)

  local lines = {}
  for i, e in ipairs(entries) do
    local last      = (i == #entries)
    local connector = last and "└ " or "├ "
    local child_pfx = prefix .. (last and "    " or "│   ")
    table.insert(lines, prefix .. connector .. e.name)
    if e.type == "directory" then
      local sub = M.generate_tree(root_path .. "/" .. e.name, ignored, depth + 1, child_pfx)
      if sub ~= "" then table.insert(lines, sub) end
    end
  end

  return table.concat(lines, "\n")
end

-- System context assembly
-- Called by llm.lua to prepend project context to every request.

function M.build_system_context()
  local parts = {}

  local overview   = M.read_context("OVERVIEW.md")
  local structure  = M.read_context("STRUCTURE.md")
  local decisions  = M.read_context("DECISIONS.md")

  if overview   then table.insert(parts, "### Project Overview\n"              .. overview)   end
  if structure  then table.insert(parts, "### Project Structure\n"             .. structure)  end
  if decisions  then table.insert(parts, "### Architecture Decisions & Log\n"  .. decisions)  end

  if #parts == 0 then return nil end
  return "# Wellm Project Context\n\n" .. table.concat(parts, "\n\n---\n\n")
end

-- DECISIONS log

function M.log_decision(text)
  M.ensure_dirs()
  local path = M.get_root() .. "/context/DECISIONS.md"
  local f = io.open(path, "a")
  if f then
    f:write(string.format("\n### %s\n%s\n", os.date("%Y-%m-%d %H:%M"), text))
    f:close()
  end
end

-- Scan LLM response for [DECISION] markers and auto-log them
function M.extract_decisions(response_text)
  -- Strip code fences first
  local text = response_text:gsub("```.-```", "")
  for line in text:gmatch("[^\n]+") do
    -- Must be the only thing on the line (with optional trailing whitespace)
    local decision = line:match("^%s*%[DECISION:%s*(.+)%]%s*$")
      or line:match("^%s*%[DECISION%]%s*(.+)%]%s*$")
    if decision then
      decision = vim.trim(decision)
      if decision ~= "" and decision:len() > 5 then
        M.log_decision("LLM", decision)
      end
    end
  end
end

-- Knowledge indexing (categorized markdown)
function M.save_knowledge(text, category)
  M.ensure_dirs()
  category = category or "General"
  local path = M.get_root() .. "/context/KNOWLEDGE.md"
  local f = io.open(path, "a")
  if f then
    f:write(string.format("\n## Category: %s\n%s\n", category, text))
    f:close()
    -- Auto-summarize if category exceeds limit
    local max = (require("wellm").config.wellagent and require("wellm").config.wellagent.max_entries_before_summarize) or 8
    local entries = M.get_category_entries(category)
    if #entries > max then
      M.summarize_category(category, entries)
    end
  end
end

function M.get_category_entries(category)
  local path = M.get_root() .. "/context/KNOWLEDGE.md"
  if vim.fn.filereadable(path) == 0 then return {} end
  local content = table.concat(vim.fn.readfile(path), "\n")
  local entries = {}
  local in_cat = false
  for line in content:gmatch("[^\n]+") do
    local cat_match = line:match("^## Category: (.+)")
    if cat_match then
      in_cat = (cat_match == category)
    elseif in_cat and line:match("^%s*%-") then
      table.insert(entries, line)
    end
  end
  return entries
end

function M.summarize_category(category, entries)
  if not entries or #entries <= 3 then return end
  local llm = require("wellm.llm")
  local prompt = string.format("Summarize these knowledge entries about '%s' into a single concise paragraph (max 200 tokens):\n%s", category, table.concat(entries, "\n"))
  llm.raw_call({{role="user", content=prompt}}, "You are a summarizer.", function(summary, _, err)
    if summary and not err then
      -- Replace old entries with summary
      local path = M.get_root() .. "/context/KNOWLEDGE.md"
      local f = io.open(path, "r")
      local old = f and f:read("*a") or ""
      if f then f:close() end
      local new_content = old:gsub("(## Category: " .. category .. "\n).-(\n## Category:|$)", "%1- **Summary:** " .. summary .. "\n%2")
      local fw = io.open(path, "w")
      if fw then fw:write(new_content); fw:close() end
    end
  end)
end

function M.load_knowledge_relevant(query)
  local path = M.get_root() .. "/context/KNOWLEDGE.md"
  if vim.fn.filereadable(path) == 0 then return "" end
  local content = table.concat(vim.fn.readfile(path), "\n")
  if not query or query == "" then
    -- return only category headers and summaries
    local lines = {}
    for line in content:gmatch("[^\n]+") do
      if line:match("^## Category:") or line:match("%- %*%*Summary:%*%*") then
        table.insert(lines, line)
      end
    end
    return table.concat(lines, "\n")
  end
  -- score paragraphs by query keywords
  local scored = {}
  for para in content:gmatch("[^\n]+") do
    local score = 0
    for word in query:gmatch("%w+") do
      if para:lower():match(word:lower()) then
        score = score + 1
      end
    end
    if score > 0 then
      table.insert(scored, {text=para, score=score})
    end
  end
  table.sort(scored, function(a,b) return a.score > b.score end)
  local top = {}
  for i=1, math.min(5, #scored) do
    table.insert(top, scored[i].text)
  end
  return table.concat(top, "\n")
end

return M
