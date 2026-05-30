-- wellm/ui/chat.lua
-- Persistent split-right chat window with live streaming output.
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

-- Insert lines before the trailing SEPARATOR + input line that render_all
-- always places at the end, so file-ops summaries appear inside the
-- conversation area rather than below the prompt.
local function append_before_input(buf, text)
  local lc         = vim.api.nvim_buf_line_count(buf)
  local insert_at  = lc - 2   -- 0-indexed; last 2 lines are SEPARATOR + INPUT_PFX
  local new_lines  = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(buf, insert_at, insert_at, false, new_lines)
  -- intentionally left modifiable, render_all already set it true and the
  -- input line must remain editable
end

-- Render history 

local function render_all(buf, win)
  local state = require("wellm.state")
  local lines = {}

  -- Header
  table.insert(lines, " Wellm Chat  q=close  <CR>=send  <C-c>=cancel  <C-j>=newline  <leader>ch=history")
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

--- Find the 1-indexed line number of the last SEPARATOR line in the buffer.
--- Everything below it is the user input area.
local function find_input_start(buf)
  local lc = vim.api.nvim_buf_line_count(buf)
  for i = lc, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ""
    if line == SEPARATOR then
      return i + 1  -- 1-indexed: first line of input area
    end
  end
  return lc  -- fallback: just the last line
end

local function get_input(buf)
  local lc         = vim.api.nvim_buf_line_count(buf)
  local start_line = find_input_start(buf)
  local lines      = vim.api.nvim_buf_get_lines(buf, start_line - 1, lc, false)

  if #lines == 0 then return "" end

  -- Strip INPUT_PFX prefix from the first line
  lines[1] = lines[1]:gsub("^" .. vim.pesc(INPUT_PFX), "")

  -- Join all lines and trim leading/trailing whitespace
  return vim.trim(table.concat(lines, "\n"))
end

local function clear_input(buf)
  local lc         = vim.api.nvim_buf_line_count(buf)
  local start_line = find_input_start(buf)
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  -- Replace everything from the first input line to end with just INPUT_PFX
  vim.api.nvim_buf_set_lines(buf, start_line - 1, lc, false, { INPUT_PFX })
end

-- Streaming submit 
-- 
-- Strategy:
--   1. Append the user turn + "## ASSISTANT\n\n" header to the buffer.
--   2. Record `stream_start` (1-indexed) — the line where streaming text begins.
--   3. on_delta: accumulate deltas; replace [stream_start .. end] with the
--      split lines of the accumulated text.  This handles mid-token newlines
--      correctly without ever shifting the header lines.
--   4. callback (done): call render_all for a canonical final render that
--      includes proper separators, then re-focus the input line.

local function submit(buf, win)
  local input = get_input(buf)
  if input == "" then return end

  clear_input(buf)

  -- Append the user turn and the assistant header synchronously so the user
  -- gets immediate visual feedback before the first token arrives.
  vim.api.nvim_buf_set_option(buf, "modifiable", true)
  local lc = vim.api.nvim_buf_line_count(buf)
  local user_lines = vim.split(input, "\n", { plain = true })
  local header_lines = { "## YOU", "" }
  for _, l in ipairs(user_lines) do
    table.insert(header_lines, l)
  end
  vim.list_extend(header_lines, { "", SEPARATOR, "", "## ASSISTANT", "" })
  vim.api.nvim_buf_set_lines(buf, lc, -1, false, header_lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  scroll_bottom(win, buf)
  vim.cmd('redraw')

  -- stream_start is the 1-indexed line where streamed text will be written.
  -- Right now it's the empty line we just appended after "## ASSISTANT".
  local stream_start  = vim.api.nvim_buf_line_count(buf)
  local streamed_text = ""

  --- Replace everything from stream_start to the current end of the buffer
  --- with `text` (split on newlines).  Safe to call from any schedule context.
  local function write_stream_region(text)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local new_lines = vim.split(text, "\n", { plain = true })
    local cur_count = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_option(buf, "modifiable", true)
    -- stream_start is 1-indexed; nvim_buf_set_lines uses 0-indexed start/end
    vim.api.nvim_buf_set_lines(buf, stream_start - 1, cur_count, false, new_lines)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    scroll_bottom(win, buf)
    vim.cmd('redraw')  -- Force immediate screen update so streaming is visible
  end

  --- Called by raw_stream for every text chunk.
  --- No vim.schedule here: on_delta is already invoked from a vim.schedule
  --- context inside raw_stream, so we can update the buffer directly.
  local function on_delta(delta)
    streamed_text = streamed_text .. delta
    write_stream_region(streamed_text)
  end

  local llm = require("wellm.llm")
  local context = require("wellm.context")   -- added to refresh cache after edits

  llm.call_stream(input, "chat", on_delta, function(response)
    vim.schedule(function()
      if not response or response == "" then
        -- Show an inline error without blowing up the buffer layout
        write_stream_region("> [!] Error: the API returned an empty response.")
        -- Append the input line so the user can keep chatting
        if vim.api.nvim_buf_is_valid(buf) then
          buf_append(buf, { "", SEPARATOR, INPUT_PFX })
        end
      else
        -- Final canonical render (adds separators, resets input line, etc.)
        render_all(buf, win)

        -- Process any file operations the LLM emitted using the unified editor
        local cfg          = require("wellm").config
        local mode         = cfg.filechanges or "filechanges_confirm"
        local editor       = require("wellm.editor")
        local wellagent    = require("wellm.wellagent")
        local project_root = wellagent.get_project_root()

        -- Helper to refresh context after successful edits
        local function refresh_context_for_path(path)
          local full_path = project_root .. "/" .. path
          if vim.fn.filereadable(full_path) == 1 then
            local lines = vim.fn.readfile(full_path)
            local content = table.concat(lines, "\n")
            context.inject_raw(full_path, content)
          end
        end

        -- Use editor.process_response which handles parsing, grouping, and applying
        if mode ~= "filechanges_off" then
          -- Parse edits to see if any exist
          local edits = editor.parse_edits(response)
          if #edits > 0 then
            if mode == "filechanges_on" then
              -- Apply directly
              local results = editor.process_response(response, project_root)
              local ok_paths = {}
              for _, r in ipairs(results) do
                if r.ok then
                  table.insert(ok_paths, r.path)
                  refresh_context_for_path(r.path)
                end
              end
              if #ok_paths > 0 then
                append_before_input(buf, "\nFile changes:\n  + " .. table.concat(ok_paths, "\n  + "))
              elseif #results > 0 then
                append_before_input(buf, "\nFile changes: none applied (errors)")
              end
            elseif mode == "filechanges_confirm" then
              -- Build a simple summary of affected files
              local files = {}
              for _, edit in ipairs(edits) do
                files[edit.path] = true
              end
              local file_list = {}
              for path in pairs(files) do
                table.insert(file_list, path)
              end
              local msg = "Wellm: Apply file edits?\n"
              for _, path in ipairs(file_list) do
                msg = msg .. "  • " .. path .. "\n"
              end
              vim.schedule(function()
                local choice = vim.fn.confirm(msg, "&Yes\n&No", 1)
                if choice == 1 then
                  local results = editor.process_response(response, project_root)
                  local ok_paths = {}
                  for _, r in ipairs(results) do
                    if r.ok then
                      table.insert(ok_paths, r.path)
                      refresh_context_for_path(r.path)
                    end
                  end
                  if #ok_paths > 0 then
                    append_before_input(buf, "\nFile changes:\n  + " .. table.concat(ok_paths, "\n  + "))
                  else
                    append_before_input(buf, "\nFile changes: none applied (errors)")
                  end
                  vim.cmd.checktime()
                else
                  append_before_input(buf, "\nFile changes cancelled by user.")
                end
                scroll_bottom(win, buf)
                vim.cmd('redraw')
                if vim.api.nvim_win_is_valid(win) then
                  local final_lc = vim.api.nvim_buf_line_count(buf)
                  vim.api.nvim_win_set_cursor(win, { final_lc, #INPUT_PFX })
                  vim.cmd("startinsert!")
                end
              end)
              return  -- skip the later scroll & focus (done inside confirm)
            end
          end
        end
      end

      scroll_bottom(win, buf)
      vim.cmd('redraw')

      -- Return focus to the input line in insert mode
      if vim.api.nvim_win_is_valid(win) then
        local final_lc = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_win_set_cursor(win, { final_lc, #INPUT_PFX })
        vim.cmd("startinsert!")
      end
    end)
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

  -- 2. Find or create the buffer
  local buf_name = "Wellm Chat"
  local buf      = -1

  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b):match(buf_name .. "$") then
      buf = b
      break
    end
  end

  if buf == -1 then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, buf_name)
    vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
    vim.api.nvim_buf_set_option(buf, "buftype",  "nofile")
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

  vim.api.nvim_win_set_option(win, "wrap",       true)
  vim.api.nvim_win_set_option(win, "linebreak",  true)
  vim.api.nvim_win_set_option(win, "number",     false)
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

  -- Insert a newline in the input area without submitting
  imap("<C-j>", function()
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", true
    )
  end)
  map("<C-j>", function()
    local lc = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_win_set_cursor(win, { lc, 0 })
    vim.cmd("startinsert!")
    vim.schedule(function()
      vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", true
      )
    end)
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
  local state = require("wellm.state")
  if state.data.chat_buffer and vim.api.nvim_buf_is_valid(state.data.chat_buffer) then
    render_all(state.data.chat_buffer, state.data.chat_win)
  end
end

return M