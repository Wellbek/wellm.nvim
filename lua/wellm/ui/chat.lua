-- wellm/ui/chat.lua
-- Persistent split-right chat window.
-- Layout:
--   [history area]
--   
--   > [input line]
local M = {}

-- local state   = require("wellm.state")
-- local llm     = require("wellm.llm")
-- local session = require("wellm.session")

local SEPARATOR = string.rep("-", 60)
local INPUT_PFX = "> "

-- Buffer helpers 

local function buf_append(buf, lines)
  local lc = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, lc, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

local function buf_set(buf, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

local function scroll_bottom(win, buf)
  if win and vim.api.nvim_win_is_valid(win) then
    local lc = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(win, { lc, 0 })
  end
end

-- Render history 

local function render_all(buf, win)
  local state = require("wellm.state")
  local lines = {}

  -- Header
  table.insert(lines, " Wellm Chat  q=close  <CR>=send  <C-c>=cancel  <leader>ch=history")
  table.insert(lines, SEPARATOR)
  table.insert(lines, "")

  for _, msg in ipairs(state.data.history) do
    local role_label = (msg.role == "user") and "## YOU" or "## ASSISTANT"
    table.insert(lines, role_label)
    table.insert(lines, "")
    for _, l in ipairs(vim.split(msg.content, "\n")) do
      table.insert(lines, l)
    end
    table.insert(lines, "")
    table.insert(lines, SEPARATOR)
    table.insert(lines, "")
  end

  -- Input area
  table.insert(lines, SEPARATOR)
  table.insert(lines, INPUT_PFX)

  buf_set(buf, lines)
  -- Make input line editable
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  scroll_bottom(win, buf)
end

-- Input extraction 

local function get_input(buf)
  local lc    = vim.api.nvim_buf_line_count(buf)
  local line  = vim.api.nvim_buf_get_lines(buf, lc - 1, lc, false)[1] or ""
  return vim.trim(line:gsub("^" .. vim.pesc(INPUT_PFX), ""))
end

local function clear_input(buf)
  local lc = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, lc - 1, lc, false, { INPUT_PFX })
end

-- Submit 

local function submit(buf, win)
  local input = get_input(buf)
  if input == "" then return end

  clear_input(buf)
  -- Append user turn immediately for visual feedback
  buf_append(buf, {
    "## YOU", "", input, "", SEPARATOR, "",
    "## ASSISTANT", "", "  ⋯ thinking…", "", SEPARATOR, "",
    SEPARATOR, INPUT_PFX,
  })
  scroll_bottom(win, buf)

  local llm = require("wellm.llm")
  llm.call(input, "chat", function(response)
    if not response or response == "" then
      -- Instead of silence, show the error in the chat UI
      buf_append(buf, { 
        "## ASSISTANT", 
        "", 
        "> [!] Wellm Error: The API returned an empty response or failed to parse the prompt.", 
        "", 
        SEPARATOR, "" 
      })
    else
      render_all(buf, win)
    end
    scroll_bottom(win, buf)
  end)
end

-- Open / focus 

function M.open()
  local state = require("wellm.state")
  local session = require("wellm.session")

  -- 1. If window is already open, just focus it
  if state.data.chat_win and vim.api.nvim_win_is_valid(state.data.chat_win) then
    vim.api.nvim_set_current_win(state.data.chat_win)
    return
  end

  -- 2. Find or Create the Buffer
  local buf_name = "Wellm Chat"
  local buf = -1
  
  -- Iterate through all buffers to see if "Wellm Chat" exists anywhere
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):match(buf_name .. "$") then
      buf = b
      break
    end
  end

  -- If it doesn't exist, create it and name it
  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, buf_name)
    vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
    vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(buf, "swapfile", false)
  end

  state.data.chat_buffer = buf

  -- 3. Open the Window
  local width = math.max(60, math.floor(vim.o.columns * 0.38))
  local win = vim.api.nvim_open_win(buf, true, {
    split = "right", 
    width = width, 
    style = "minimal",
  })

  vim.api.nvim_win_set_option(win, "wrap", true)
  vim.api.nvim_win_set_option(win, "linebreak", true)
  vim.api.nvim_win_set_option(win, "number", false)
  vim.api.nvim_win_set_option(win, "signcolumn", "no")

  state.data.chat_win = win

  render_all(buf, win)

  --  Keymaps 
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true })
  end
  local function imap(lhs, fn)
    vim.keymap.set("i", lhs, fn, { buffer = buf, silent = true, nowait = true })
  end

  -- Send in normal mode (cursor on input line) or insert mode
  map("<CR>",   function() submit(buf, win) end)
  imap("<CR>",  function()
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", true
    )
    vim.schedule(function() submit(buf, win) end)
  end)

  -- Close
  map("q", function()
    vim.api.nvim_win_close(win, true)
    state.data.chat_win    = nil
    state.data.chat_buffer = nil
  end)

  -- Cancel running job
  map("<C-c>", function()
    if state.data.job_id then
      vim.fn.jobstop(state.data.job_id)
      state.data.job_id = nil
      buf_append(buf, { "[cancelled]", "" })
      vim.notify("[Wellm] Request cancelled.")
    end
  end)

  -- Jump to input line
  map("i", function()
    local lc = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(win, { lc, #INPUT_PFX })
    vim.cmd("startinsert!")
  end)

  -- Go to end (A) to type
  map("A", function()
    local lc = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(win, { lc, #INPUT_PFX })
    vim.cmd("startinsert!")
  end)

  -- New conversation
  map("<leader>cn", function()
    session.auto_save()
    require("wellm.state").reset_conversation()
    render_all(buf, win)
    vim.notify("[Wellm] New conversation started.")
  end)

  -- Clean up state on buffer delete
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once   = true,
    callback = function()
      state.data.chat_win    = nil
      state.data.chat_buffer = nil
    end,
  })

  -- Start with cursor on input line in insert mode
  local lc = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_win_set_cursor(win, { lc, #INPUT_PFX })
  vim.cmd("startinsert!")
end

--- Re-render the chat window if it's open (called after loading a session).
function M.refresh()
  if state.data.chat_buffer and vim.api.nvim_buf_is_valid(state.data.chat_buffer) then
    render_all(state.data.chat_buffer, state.data.chat_win)
  end
end

return M
