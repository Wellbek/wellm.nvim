local M = {}

local function fnv1a(str)
  local hash = 2166136261
  for i = 1, #str do
    hash = bit.bxor(hash, string.byte(str, i))
    hash = bit.band(hash * 16777619, 0xFFFFFFFF)
  end
  return string.format("%08x", hash)
end

---@param str string
---@return string
function M.hash_string(str)
  if not str then return "" end
  return fnv1a(str)
end

---@param path string Absolute file path
---@return string|nil hash
---@return string|nil content
function M.hash_file(path)
  local f = io.open(path, "r")
  if not f then return nil, nil end
  local content = f:read("*a")
  f:close()
  if not content then return nil, nil end
  return fnv1a(content), content
end

return M