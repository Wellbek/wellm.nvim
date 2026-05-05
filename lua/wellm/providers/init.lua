-- wellm/providers/init.lua — routes to the correct provider module
local M = {}

local registry = {
  anthropic = "wellm.providers.anthropic",
  zhipu     = "wellm.providers.zhipu",
}

function M.get(name)
  local mod = registry[name]
  if not mod then
    error("[Wellm] Unknown provider: " .. tostring(name))
  end
  return require(mod)
end

return M
