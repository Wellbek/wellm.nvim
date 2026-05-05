-- wellm/actions.lua  — replace selection, insert at cursor
local M = {}

local llm = require("wellm.llm")

-- Visual replace 

function M.replace()
  -- Exit visual mode so marks '<,'> are finalised
  local mode = vim.api.nvim_get_mode().mode
  if mode:find("[vVx\22]") then
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", true
    )
  end

  vim.schedule(function()
    local sm = vim.fn.getpos("'<")
    local em = vim.fn.getpos("'>")
    local s_row, s_col = sm[2] - 1, sm[3] - 1
    local e_row, e_col = em[2] - 1, em[3]

    -- Clamp end col to line length
    local last_line = vim.api.nvim_buf_get_lines(0, e_row, e_row + 1, false)[1] or ""
    if e_col > #last_line then e_col = #last_line end

    local selection = ""
    if s_row >= 0 and not (s_row == e_row and s_col == e_col) then
      local sel_lines = vim.api.nvim_buf_get_text(0, s_row, s_col, e_row, e_col, {})
      selection = table.concat(sel_lines, "\n")
    else
      -- Fallback: whole file
      selection = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      s_row, s_col = 0, 0
      local lc = vim.api.nvim_buf_line_count(0) - 1
      local ll = vim.api.nvim_buf_get_lines(0, lc, lc + 1, false)[1] or ""
      e_row, e_col = lc, #ll
    end

    vim.ui.input({ prompt = "AI Replace: " }, function(input)
      if not input or input == "" then return end
      vim.notify("[Wellm] Replacing...", vim.log.levels.INFO)

      llm.call(input, "replace", function(response)
        if not response or response == "" then return end
        vim.schedule(function()
          local new_lines = vim.split(response, "\n", { plain = true })
          local ok, err = pcall(vim.api.nvim_buf_set_text, 0, s_row, s_col, e_row, e_col, new_lines)
          if ok then
            vim.notify("[Wellm] Applied.", vim.log.levels.INFO)
          else
            vim.notify("[Wellm] Error: " .. tostring(err), vim.log.levels.ERROR)
          end
        end)
      end, selection)
    end)
  end)
end

-- Insert at cursor 

function M.insert()
  local file_content = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")

  vim.ui.input({ prompt = "AI Insert: " }, function(input)
    if not input or input == "" then return end
    vim.notify("[Wellm] Generating...", vim.log.levels.INFO)

    llm.call(input, "insert", function(response)
      vim.schedule(function()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local lines = vim.split(response, "\n", { plain = true })
        vim.api.nvim_buf_set_lines(0, row, row, false, lines)
        vim.notify("[Wellm] Inserted.", vim.log.levels.INFO)
      end)
    end, file_content)
  end)
end

return M
