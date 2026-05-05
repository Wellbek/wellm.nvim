-- wellm/usage.lua
-- Tracks tokens + estimated cost per model per calendar month.
-- Data lives in .wellagent/usage.json (per-project).
local M = {}

local function usage_path()
  return require("wellm.wellagent").get_root() .. "/usage.json"
end

local function load()
  local p = usage_path()
  if vim.fn.filereadable(p) == 0 then return {} end
  local ok, d = pcall(vim.fn.json_decode, table.concat(vim.fn.readfile(p), "\n"))
  return ok and d or {}
end

local function save(data)
  require("wellm.wellagent").ensure_dirs()
  local f = io.open(usage_path(), "w")
  if f then f:write(vim.fn.json_encode(data)); f:close() end
end

-- Public API 

function M.record(model, input_tok, output_tok)
  if not model or (input_tok == 0 and output_tok == 0) then return end
  local month = os.date("%Y-%m")
  local data  = load()
  data[month] = data[month] or {}
  data[month][model] = data[month][model] or { input = 0, output = 0 }
  data[month][model].input  = data[month][model].input  + (input_tok  or 0)
  data[month][model].output = data[month][model].output + (output_tok or 0)
  save(data)
end

function M.cost_for(model, input_tok, output_tok)
  local pricing = require("wellm.config").pricing
  local p = pricing[model]
  if not p then return 0 end
  return (input_tok / 1e6) * p.input + (output_tok / 1e6) * p.output
end

--- Return a summary table for a given month (default: current).
function M.summary(month)
  month    = month or os.date("%Y-%m")
  local d  = load()
  local md = d[month] or {}

  local models      = {}
  local total_cost  = 0
  local total_in    = 0
  local total_out   = 0

  for model, tok in pairs(md) do
    local cost = M.cost_for(model, tok.input, tok.output)
    table.insert(models, {
      model      = model,
      input_tok  = tok.input,
      output_tok = tok.output,
      cost_usd   = cost,
    })
    total_cost = total_cost + cost
    total_in   = total_in   + tok.input
    total_out  = total_out  + tok.output
  end

  table.sort(models, function(a, b) return a.cost_usd > b.cost_usd end)

  return {
    month      = month,
    models     = models,
    total_cost = total_cost,
    total_in   = total_in,
    total_out  = total_out,
  }
end

--- Return a list of months that have data.
function M.months()
  local d = load()
  local ms = vim.tbl_keys(d)
  table.sort(ms, function(a, b) return a > b end)
  return ms
end

return M
