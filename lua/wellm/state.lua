-- wellm/state.lua — single source of truth for runtime state
local M = {}

M.data = {
  history            = {},    -- [{role="user"|"assistant", content="..."}]
  context_files      = {},    -- { [abs_path] = content_string }
  system_override    = nil,   -- string | nil
  chat_buffer        = nil,   -- buf id
  chat_win           = nil,   -- win id
  job_id             = nil,   -- running curl job
  current_session_id = nil,   -- string
  project_root       = nil,   -- detected root dir
  wellagent_root     = nil,   -- project_root/.wellagent
}

function M.reset_conversation()
  M.data.history         = {}
  M.data.system_override = nil
  M.data.current_session_id = nil
end

function M.reset_context()
  M.data.context_files = {}
end

function M.reset_all()
  M.reset_conversation()
  M.reset_context()
end

return M
