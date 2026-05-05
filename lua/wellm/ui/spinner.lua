local M = {}

local frames = { "|", "/", "-", "\\" }
local interval = 150

local buf = nil
local win = nil
local timer = nil
local frame_idx = 1
local status_text = ""

local function create_window()
  if win and vim.api.nvim_win_is_valid(win) then return end

  buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")

  local label = " " .. frames[frame_idx] .. " " .. status_text .. " "
  local width = math.max(#label + 2, 20)
  local height = 1
  local row = vim.o.lines - height - 4
  local col = vim.o.columns - width - 2

  win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "single",
    focusable = false,
    zindex = 50,
  })
  vim.api.nvim_win_set_option(win, "winhl", "Normal:Comment,FloatBorder:Comment")
end

local function update()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local label = " " .. frames[frame_idx] .. " " .. status_text .. " "

  -- resize if text length changed
  local new_w = math.max(#label + 2, 20)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_width(win, new_w)
    vim.api.nvim_win_set_config(win, {
      relative = "editor",
      row = vim.o.lines - 5,
      col = vim.o.columns - new_w - 2,
    })
  end

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { label })
  frame_idx = (frame_idx % #frames) + 1
end

function M.start(msg)
  if timer then M.stop() end
  status_text = msg or "LLM thinking..."
  frame_idx = 1
  create_window()
  update()
  timer = vim.loop.new_timer()
  timer:start(interval, interval, vim.schedule_wrap(update))
end

function M.stop(final_msg)
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
    win = nil
  end
  buf = nil
  frame_idx = 1
  if final_msg then
    vim.notify(final_msg, vim.log.levels.INFO)
  end
end

function M.is_active()
  return timer ~= nil
end

-- update label mid-flight (e.g. "reading files...")
function M.set_status(msg)
  status_text = msg or status_text
end

return M