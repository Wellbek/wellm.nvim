-- wellm/ui/picker.lua
-- Floating window checkbox file-tree.
-- Keys:  j/k  move │  <Space>  toggle │  a  select all │  n  select none
--        <CR>  confirm │  q/<Esc>  cancel
local M = {}

local ctx = require("wellm.context")

local CHECK_ON  = "[✓]"
local CHECK_OFF = "[ ]"

-- Tree builder 

local SKIP = {
  "%.git$", "node_modules$", "%.wellagent$", "__pycache__$",
  "dist$", "build$", "target$", ".DS_Store",
}

local BIN_EXTS = {
  png=1,jpg=1,jpeg=1,gif=1,ico=1,svg=1,woff=1,woff2=1,ttf=1,eot=1,
  zip=1,tar=1,gz=1,["7z"]=1,rar=1,pdf=1,mp3=1,mp4=1,mov=1,avi=1,
}

local function is_skipped(name)
  for _, p in ipairs(SKIP) do if name:match(p) then return true end end
  if name:match("^%.") then return true end
  local ext = name:match("%.([^.]+)$")
  if ext and BIN_EXTS[ext:lower()] then return true end
  return false
end

local function scan(dir, depth, entries, indent)
  depth  = depth  or 0
  indent = indent or ""
  if depth > 5 then return end

  local h = vim.loop.fs_scandir(dir)
  if not h then return end

  local items = {}
  while true do
    local name, ft = vim.loop.fs_scandir_next(h)
    if not name then break end
    if not is_skipped(name) then
      table.insert(items, { name = name, type = ft, path = dir .. "/" .. name })
    end
  end
  table.sort(items, function(a, b)
    if a.type ~= b.type then return a.type == "directory" end
    return a.name < b.name
  end)

  for _, item in ipairs(items) do
    table.insert(entries, {
      path   = item.path,
      name   = item.name,
      ftype  = item.type,
      indent = indent,
      selected = false,
      is_dir = item.type == "directory",
    })
    if item.type == "directory" then
      scan(item.path, depth + 1, entries, indent .. "  ")
    end
  end
end

-- Floating window 

function M.open(dir)
  dir = dir or require("wellm.wellagent").get_project_root()

  -- Build entry list
  local entries = {}
  scan(dir, 0, entries, "")

  if #entries == 0 then
    vim.notify("[Wellm] No files found in " .. dir, vim.log.levels.WARN)
    return
  end

  -- Pre-select files already in context
  local current_ctx = ctx.list()
  local ctx_set = {}
  for _, p in ipairs(current_ctx) do ctx_set[p] = true end
  for _, e in ipairs(entries) do
    if not e.is_dir and ctx_set[e.path] then e.selected = true end
  end

  -- Window dimensions
  local max_w  = math.min(80, vim.o.columns - 4)
  local max_h  = math.min(#entries + 4, vim.o.lines - 6)
  local row    = math.floor((vim.o.lines   - max_h) / 2)
  local col    = math.floor((vim.o.columns - max_w) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row, col = col,
    width = max_w, height = max_h,
    style = "minimal",
    border = "rounded",
    title = " Wellm File Picker  <Space>=toggle  a=all  n=none  <CR>=confirm ",
    title_pos = "center",
  })

  --  Render 
  local function render()
    local lines = {}
    for i, e in ipairs(entries) do
      local check = ""
      if not e.is_dir then
        check = (e.selected and CHECK_ON or CHECK_OFF) .. " "
      else
        check = "    "   -- indent dirs without checkbox
      end
      local icon = e.is_dir and "▸ " or "  "
      lines[i] = e.indent .. check .. icon .. e.name
    end
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
  end

  render()

  --  Helpers 
  local function current_entry()
    local row_i = vim.api.nvim_win_get_cursor(win)[1]
    return entries[row_i]
  end

  local function toggle()
    local e = current_entry()
    if e and not e.is_dir then
      e.selected = not e.selected
      render()
      -- Move cursor down after toggle
      local lc = #entries
      local cur = vim.api.nvim_win_get_cursor(win)[1]
      if cur < lc then
        vim.api.nvim_win_set_cursor(win, { cur + 1, 0 })
      end
    elseif e and e.is_dir then
      -- Toggle all children
      local prefix = e.path
      local new_val = nil
      for _, child in ipairs(entries) do
        if not child.is_dir and child.path:sub(1, #prefix) == prefix then
          if new_val == nil then new_val = not child.selected end
          child.selected = new_val
        end
      end
      render()
    end
  end

  local function select_all()
    for _, e in ipairs(entries) do if not e.is_dir then e.selected = true end end
    render()
  end

  local function select_none()
    for _, e in ipairs(entries) do e.selected = false end
    render()
  end

  local function confirm()
    vim.api.nvim_win_close(win, true)
    ctx.clear()
    local count = 0
    for _, e in ipairs(entries) do
      if not e.is_dir and e.selected then
        ctx.add_file(e.path)
        count = count + 1
      end
    end
    vim.notify(string.format("[Wellm] %d file(s) added to context.", count))
  end

  local function close()
    vim.api.nvim_win_close(win, true)
  end

  -- Keymaps 
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
  end

  map("<Space>", toggle)
  map("a",       select_all)
  map("n",       select_none)
  map("<CR>",    confirm)
  map("q",       close)
  map("<Esc>",   close)

  -- Highlight selected lines
  local ns = vim.api.nvim_create_namespace("wellm_picker")
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      for i, e in ipairs(entries) do
        if e.selected then
          vim.api.nvim_buf_add_highlight(buf, ns, "DiffAdd", i - 1, 0, -1)
        end
      end
    end,
  })
end

return M
