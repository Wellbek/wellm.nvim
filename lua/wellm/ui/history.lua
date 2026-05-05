-- wellm/ui/history.lua
-- Floating session history browser.
-- Keys:  j/k=navigate  <CR>=load & continue  d=delete  q/<Esc>=close
local M = {}

local session = require("wellm.session")
local state   = require("wellm.state")

function M.open()
  local entries = session.list()

  if #entries == 0 then
    vim.notify("[Wellm] No sessions found.", vim.log.levels.INFO)
    return
  end

  -- Layout 
  local total_w  = math.min(140, vim.o.columns - 4)
  local total_h  = math.min(30,  vim.o.lines   - 6)
  local list_w   = math.floor(total_w * 0.4)
  local prev_w   = total_w - list_w - 1
  local top_row  = math.floor((vim.o.lines   - total_h) / 2)
  local top_col  = math.floor((vim.o.columns - total_w) / 2)

  -- List buffer
  local lbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(lbuf, "bufhidden", "wipe")
  local lwin = vim.api.nvim_open_win(lbuf, true, {
    relative = "editor",
    row = top_row, col = top_col,
    width = list_w, height = total_h,
    style = "minimal", border = "rounded",
    title = " Sessions ", title_pos = "center",
  })

  -- Preview buffer
  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(pbuf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(pbuf, "filetype", "markdown")
  local pwin = vim.api.nvim_open_win(pbuf, false, {
    relative = "editor",
    row = top_row, col = top_col + list_w + 1,
    width = prev_w, height = total_h,
    style = "minimal", border = "rounded",
    title = " Preview (<CR>=load & continue  d=delete) ", title_pos = "center",
  })
  vim.api.nvim_win_set_option(pwin, "wrap", true)

  --  Render list 
  local function render_list()
    local lines = {}
    for _, e in ipairs(entries) do
      table.insert(lines, string.format("%-20s  %s", e.date, e.title:sub(1, list_w - 24)))
    end
    vim.api.nvim_buf_set_option(lbuf, "modifiable", true)
    vim.api.nvim_buf_set_lines(lbuf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(lbuf, "modifiable", false)
  end

  -- Render preview 
  local function render_preview(idx)
    local e = entries[idx]
    if not e then return end
    local hist = session.load(e.id)
    local lines = {
      "# " .. e.title,
      "> " .. e.date .. "  |  " .. e.message_count .. " messages",
      "",
    }
    if hist then
      for _, msg in ipairs(hist) do
        table.insert(lines, "## " .. msg.role:upper())
        for _, l in ipairs(vim.split(msg.content:sub(1, 800), "\n")) do
          table.insert(lines, l)
        end
        table.insert(lines, "")
      end
    end
    vim.api.nvim_buf_set_option(pbuf, "modifiable", true)
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(pbuf, "modifiable", false)
  end

  render_list()
  render_preview(1)

  -- Close helper 
  local function close()
    pcall(vim.api.nvim_win_close, pwin, true)
    pcall(vim.api.nvim_win_close, lwin, true)
  end

  -- Keymaps 
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = lbuf, silent = true, nowait = true })
  end

  -- Update preview on cursor move
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = lbuf,
    callback = function()
      local idx = vim.api.nvim_win_get_cursor(lwin)[1]
      render_preview(idx)
    end,
  })

  -- Load and continue
  map("<CR>", function()
    local idx  = vim.api.nvim_win_get_cursor(lwin)[1]
    local e    = entries[idx]
    if not e then return end
    local hist = session.load(e.id)
    if not hist then
      vim.notify("[Wellm] Could not load session.", vim.log.levels.WARN)
      return
    end
    close()
    state.data.history            = hist
    state.data.current_session_id = e.id
    require("wellm.ui.chat").open()
    vim.notify(string.format("[Wellm] Resumed: %s", e.title:sub(1, 60)))
  end)

  -- Delete session
  map("d", function()
    local idx = vim.api.nvim_win_get_cursor(lwin)[1]
    local e   = entries[idx]
    if not e then return end
    vim.ui.input({ prompt = "Delete session '" .. e.title:sub(1, 40) .. "'? (y/N) " }, function(input)
      if input and input:lower() == "y" then
        os.remove(e.file)
        table.remove(entries, idx)
        if #entries == 0 then
          close()
          vim.notify("[Wellm] All sessions deleted.")
          return
        end
        render_list()
        local new_idx = math.min(idx, #entries)
        vim.api.nvim_win_set_cursor(lwin, { new_idx, 0 })
        render_preview(new_idx)
        vim.notify("[Wellm] Session deleted.")
      end
    end)
  end)

  map("q",     close)
  map("<Esc>", close)
end

return M
