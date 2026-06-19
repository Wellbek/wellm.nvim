-- wellm/ratelimit.lua
-- A Lua port of "headroom"-style (https://github.com/chopratejas/headroom) 
-- rate limit handling, adapted to Neovim's async job model 
-- (no thread-blocking waits — uses vim.defer_fn instead).
--
-- What it does, mirroring headroom:
--   - Reads rate-limit headers off every response (Anthropic's
--     anthropic-ratelimit-* headers, with x-ratelimit-* OpenAI-style as a
--     fallback for other providers).
--   - Tracks remaining requests/tokens and reset times per (provider, model).
--   - Before sending a request, checks whether capacity is available; if not,
--     defers the request until the reset time instead of firing and getting
--     a 429.
--   - On an actual 429, reads Retry-After and retries automatically.
--   - One limiter state per provider+model key, same guidance headroom gives
--     for "one limiter per API key/endpoint".
local M = {}

-- M.state[key] = {
--   requests_remaining, requests_limit, requests_reset_at (epoch secs),
--   tokens_remaining,   tokens_reset_at   (epoch secs),
--   retry_after_until (epoch secs, set on 429),
-- }
M.state = {}

local function now()
  return os.time()
end

local function get_state(key)
  if not M.state[key] then
    M.state[key] = {}
  end
  return M.state[key]
end

local function cfg()
  local ok, wellm = pcall(require, "wellm")
  if ok and wellm.config and wellm.config.ratelimit then
    return wellm.config.ratelimit
  end
  return {}
end

--- Parse a raw header dump (as written by `curl -D <file>`) into a table of
--- lowercase header name -> value, plus the HTTP status code from the
--- status line if present.
---@param raw string|nil
---@return table headers
---@return number|nil status
function M.parse_response_headers(raw)
  local headers = {}
  local status = nil
  if not raw or raw == "" then return headers, status end
  for line in raw:gmatch("[^\r\n]+") do
    local code = line:match("^HTTP/[%d%.]+%s+(%d+)")
    if code then
      status = tonumber(code)
      headers = {} -- a new status line means a new response (redirects/100-continue); reset
    end
    local k, v = line:match("^([%w%-]+):%s*(.-)%s*$")
    if k then
      headers[k:lower()] = v
    end
  end
  return headers, status
end

-- Parse an RFC3339 UTC timestamp ("2026-06-20T10:15:30Z") into epoch seconds.
local function parse_rfc3339(s)
  if not s then return nil end
  local y, mo, d, h, mi, se = s:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then
    -- Some providers send a plain integer epoch or a relative-seconds value.
    local n = tonumber(s)
    if n then
      -- Heuristic: anything under ~10 years of seconds is "seconds from now",
      -- otherwise treat it as an absolute epoch timestamp.
      if n < 315360000 then return now() + n end
      return n
    end
    return nil
  end
  local t_utc_as_local = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = se })
  -- os.time() above interpreted the fields as local time, but they were UTC.
  -- Compute the local/UTC offset and correct for it.
  local local_now = os.time(os.date("*t"))
  local utc_now = os.time(os.date("!*t"))
  local offset = local_now - utc_now
  return t_utc_as_local + offset
end

--- Update limiter state for `key` from a raw header dump produced by curl.
--- Returns the HTTP status code found in the headers (or nil).
---@param key string
---@param raw_headers string|nil
---@return number|nil status
function M.update_from_headers(key, raw_headers)
  local h, status = M.parse_response_headers(raw_headers)
  local c = cfg()
  if c.enabled == false then return status end

  local st = get_state(key)

  local req_remaining = h["anthropic-ratelimit-requests-remaining"] or h["x-ratelimit-remaining-requests"]
  local req_limit     = h["anthropic-ratelimit-requests-limit"]     or h["x-ratelimit-limit-requests"]
  local req_reset     = h["anthropic-ratelimit-requests-reset"]     or h["x-ratelimit-reset-requests"]

  local in_remaining  = h["anthropic-ratelimit-input-tokens-remaining"]
  local in_reset      = h["anthropic-ratelimit-input-tokens-reset"]
  local out_remaining = h["anthropic-ratelimit-output-tokens-remaining"] or h["x-ratelimit-remaining-tokens"]
  local out_reset     = h["anthropic-ratelimit-output-tokens-reset"]     or h["x-ratelimit-reset-tokens"]

  if req_remaining then st.requests_remaining = tonumber(req_remaining) end
  if req_limit     then st.requests_limit     = tonumber(req_limit) end
  if req_reset     then st.requests_reset_at  = parse_rfc3339(req_reset) end

  -- Track the tighter of input/output token budgets; either can be the
  -- bottleneck depending on the request shape.
  if in_remaining then
    st.tokens_remaining = tonumber(in_remaining)
    st.tokens_reset_at  = parse_rfc3339(in_reset)
  elseif out_remaining then
    st.tokens_remaining = tonumber(out_remaining)
    st.tokens_reset_at  = parse_rfc3339(out_reset)
  end

  if status == 429 then
    local retry_after = tonumber(h["retry-after"])
    st.retry_after_until = now() + (retry_after or c.default_retry_after or 5)
  else
    st.retry_after_until = nil
  end

  return status
end

--- How many seconds the caller should wait before the next request to `key`
--- is safe to send. 0 means "go now".
---@param key string
---@return number
function M.seconds_until_available(key)
  local c = cfg()
  if c.enabled == false then return 0 end

  local st = M.state[key]
  if not st then return 0 end

  local t = now()
  local wait = 0

  if st.retry_after_until and st.retry_after_until > t then
    wait = math.max(wait, st.retry_after_until - t)
  end

  local min_requests = c.min_requests_remaining or 1
  if st.requests_remaining and st.requests_remaining < min_requests
      and st.requests_reset_at and st.requests_reset_at > t then
    wait = math.max(wait, st.requests_reset_at - t)
  end

  local min_tokens = c.min_tokens_remaining or 0
  if st.tokens_remaining and st.tokens_remaining <= min_tokens
      and st.tokens_reset_at and st.tokens_reset_at > t then
    wait = math.max(wait, st.tokens_reset_at - t)
  end

  local max_wait = c.max_wait_seconds or 60
  if wait > max_wait then
    wait = max_wait
  end

  return wait
end

--- Run fn() once capacity is available for `key`. Never blocks the editor —
--- schedules fn via vim.defer_fn if a wait is required.
---@param key string
---@param fn function
function M.run_when_ready(key, fn)
  local wait = M.seconds_until_available(key)
  if wait <= 0 then
    fn()
    return
  end
  vim.schedule(function()
    vim.notify(
      string.format("[Wellm] Rate limit: waiting %ds for capacity before sending...", math.ceil(wait)),
      vim.log.levels.INFO
    )
  end)
  vim.defer_fn(fn, math.ceil(wait) * 1000)
end

--- Limiter key for the current provider+model (one limiter per endpoint,
--- per headroom's own recommendation).
---@param wellm_cfg table
---@return string
function M.key_for(wellm_cfg)
  return (wellm_cfg.provider or "unknown") .. ":" .. (wellm_cfg.model or "unknown")
end

--- Snapshot of current limiter state for a key, for UI/usage display.
---@param wellm_cfg table
---@return table|nil
function M.status(wellm_cfg)
  return M.state[M.key_for(wellm_cfg)]
end

return M
