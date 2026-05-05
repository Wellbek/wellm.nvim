-- wellm/ui/usage.lua
-- Floating window showing monthly token usage and estimated cost.
local M = {}

local usage_mod = require("wellm.usage")

local function fmt_tok(n)
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.1fk", n / 1e3) end
  return tostring(n)
end

function M.open()
  local months = usage_mod.months()
  if #months == 0 then
    vim.notify("[Wellm] No usage data yet.", vim.log.levels.INFO)
    return
  end

  -- Build display lines for all months
  local lines = { "# Wellm Usage & Estimated Cost", "" }

  for _, month in ipairs(months) do
    local s = usage_mod.summary(month)
    table.insert(lines, string.format("## %s   (total: $%.4f)", s.month, s.total_cost))
    table.insert(lines, string.format(
      "%-38s  %10s  %10s  %10s",
      "Model", "In tokens", "Out tokens", "Cost (USD)"
    ))
    table.insert(lines, string.rep("─", 74))
    for _, m in ipairs(s.models) do
      table.insert(lines, string.format(
        "%-38s  %10s  %10s  $%9.4f",
        m.model, fmt_tok(m.input_tok), fmt_tok(m.output_tok), m.cost_usd
      ))
    end
    table.insert(lines, string.rep("─", 74))
    table.insert(lines, string.format(
      "%-38s  %10s  %10s  $%9.4f",
      "TOTAL",
      fmt_tok(s.total_in),
      fmt_tok(s.total_out),
      s.total_cost
    ))
    table.insert(lines, "")
  end

  table.insert(lines, "")
  table.insert(lines, "> Prices are estimates based on providers' officially published rates.")
  table.insert(lines, "> Update wellm/usage.lua:pricing{} to reflect current pricing.")
  table.insert(lines, "")
  table.insert(lines, "  q / <Esc> = close")

  -- Window
  local w = math.min(82, vim.o.columns - 4)
  local h = math.min(#lines + 2, vim.o.lines - 6)
  local r = math.floor((vim.o.lines   - h) / 2)
  local c = math.floor((vim.o.columns - w) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = r, col = c,
    width = w, height = h,
    style = "minimal", border = "rounded",
    title = " Wellm Usage ", title_pos = "center",
  })
  vim.api.nvim_win_set_option(win, "wrap", false)

  local function close()
    pcall(vim.api.nvim_win_close, win, true)
  end
  vim.keymap.set("n", "q",     close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })
end

return M
