-- wellm/init.lua — plugin entry point
local M = {}

-- Setup 

function M.setup(opts)
  local defaults = require("wellm.config").defaults
  M.config = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Resolve API key
  if not M.config.api_key or M.config.api_key == "" then
    M.config.api_key = os.getenv(M.config.api_key_name)
  end
  if not M.config.api_key then
    vim.notify(
      "[Wellm] API key not found. Set $" .. M.config.api_key_name,
      vim.log.levels.WARN
    )
  end

  -- Auto-init .wellagent on first use if enabled
  if M.config.wellagent.enabled and M.config.wellagent.auto_init then
    -- Deferred so we don't block startup; fires when first buffer opens.
    vim.api.nvim_create_autocmd("BufReadPost", {
      once = true,
      callback = function()
        local wellagent = require("wellm.wellagent")
        wellagent.ensure_dirs()
        if M.config.wellagent.auto_orient and wellagent.needs_orient() then
          require("wellm.llm").orient()
        end
      end,
    })
  end

  if not M.config.skip_default_mappings then M._set_keymaps() end
  M._set_commands()
end

-- Keymaps 

function M._set_keymaps()
  local k   = M.config.keys
  local opt = { noremap = true, silent = true }
  local map = vim.keymap.set

  local function bind(mode, lhs, fn, desc)
    map(mode, lhs, fn, vim.tbl_extend("force", opt, { desc = desc }))
  end

  bind("v", k.replace[1],    function() require("wellm.actions").replace()            end, k.replace[3])
  bind("n", k.insert[1],     function() require("wellm.actions").insert()             end, k.insert[3])
  bind("n", k.chat[1],       function() require("wellm.ui.chat").open()               end, k.chat[3])
  bind("n", k.picker[1],     function() require("wellm.ui.picker").open()             end, k.picker[3])
  bind("n", k.history[1],    function() require("wellm.ui.history").open()            end, k.history[3])
  bind("n", k.usage[1],      function() require("wellm.ui.usage").open()              end, k.usage[3])
  bind("n", k.add_file[1],   function() require("wellm.context").add_file()           end, k.add_file[3])
  bind("n", k.add_folder[1], function() require("wellm.context").add_folder()         end, k.add_folder[3])
  bind("n", k.clear_ctx[1],  function()
    require("wellm.context").clear()
    require("wellm.state").reset_all()
  end, k.clear_ctx[3])
  bind("n", k.orient[1],     function() require("wellm.llm").orient()                 end, k.orient[3])
end

-- Commands 

function M._set_commands()
  local cmd = vim.api.nvim_create_user_command

  cmd("WellmChat",      function()   require("wellm.ui.chat").open()                      end, {})
  cmd("WellmReplace",   function()   require("wellm.actions").replace()                   end, { range = true })
  cmd("WellmInsert",    function()   require("wellm.actions").insert()                    end, {})
  cmd("WellmPicker",    function()   require("wellm.ui.picker").open()                    end, {})
  cmd("WellmHistory",   function()   require("wellm.ui.history").open()                   end, {})
  cmd("WellmUsage",     function()   require("wellm.ui.usage").open()                     end, {})
  cmd("WellmOrient",    function()   require("wellm.llm").orient()                        end, {})
  cmd("WellmAddFile",   function()   require("wellm.context").add_file()                  end, {})
  cmd("WellmAddFolder", function()   require("wellm.context").add_folder()                end, {})
  cmd("WellmClear",     function()
    require("wellm.context").clear()
    require("wellm.state").reset_all()
    vim.notify("[Wellm] Context and history cleared.")
  end, {})

  cmd("WellmSystem", function()
    local st = require("wellm.state")
    local current = st.data.system_override or M.config.prompts.coding
    vim.ui.input({ prompt = "System Prompt: ", default = current }, function(input)
      if input then
        st.data.system_override = input
        vim.notify("[Wellm] System prompt updated.")
      end
    end)
  end, {})

  cmd("WellmModel", function(args)
    if args.args and args.args ~= "" then
      M.config.model = vim.trim(args.args)
      vim.notify("[Wellm] Model set to: " .. M.config.model)
    else
      vim.notify("[Wellm] Current model: " .. M.config.model)
    end
  end, { nargs = "?" })

  cmd("WellmNewSession", function()
    require("wellm.session").auto_save()
    require("wellm.state").reset_conversation()
    require("wellm.ui.chat").refresh()
    vim.notify("[Wellm] New conversation started.")
  end, {})

  cmd("WellmDecision", function(args)
    if args.args and args.args ~= "" then
      require("wellm.wellagent").log_decision(args.args)
      vim.notify("[Wellm] Decision logged.")
    end
  end, { nargs = "+" })
end

return M
