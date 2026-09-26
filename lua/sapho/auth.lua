local config = require("sapho.config")

local M = {}

local function resolve_codex_home()
  local opts = config.get()
  if opts.codex_home and opts.codex_home ~= "" then
    return opts.codex_home
  end
  local env = vim.uv.os_getenv("CODEX_HOME")
  if env and env ~= "" then
    return env
  end
  return vim.uv.os_homedir() .. "/.codex"
end

function M.path()
  return resolve_codex_home() .. "/auth.json"
end

local function read_file(path)
  local fd = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local stat = vim.uv.fs_fstat(fd)
  local data = stat and vim.uv.fs_read(fd, stat.size, 0) or nil
  vim.uv.fs_close(fd)
  return data
end

-- base64url -> exp claim; nil on any failure (never raises).
local function decode_jwt_exp(token)
  local payload_b64 = token:match("^[^.]+%.([^.]+)%.")
  if not payload_b64 then
    return nil
  end
  payload_b64 = payload_b64:gsub("-", "+"):gsub("_", "/")
  local pad = #payload_b64 % 4
  if pad == 2 then
    payload_b64 = payload_b64 .. "=="
  elseif pad == 3 then
    payload_b64 = payload_b64 .. "="
  elseif pad == 1 then
    return nil
  end

  local decode_ok, bytes = pcall(vim.base64.decode, payload_b64)
  if not decode_ok then
    return nil
  end
  local json_ok, payload = pcall(vim.json.decode, bytes, { luanil = { object = true, array = true } })
  if not json_ok or type(payload) ~= "table" then
    return nil
  end
  return payload.exp
end

-- Decodes `data` (auth.json contents) into { mode, expires_at, err }.
-- Never includes the token itself.
local function inspect(data)
  local ok, decoded = pcall(vim.json.decode, data, { luanil = { object = true, array = true } })
  if not ok or type(decoded) ~= "table" then
    return { err = "failed to parse auth.json" }
  end

  local mode = decoded.auth_mode
  local tokens = decoded.tokens
  local expires_at
  if type(tokens) == "table" and type(tokens.access_token) == "string" then
    expires_at = decode_jwt_exp(tokens.access_token)
  end

  return { decoded = decoded, mode = mode, expires_at = expires_at }
end

--- Resolved 0600-style permission bits (owner/group/other rwx), or nil if
--- the file can't be stat'd.
function M.permissions(path)
  local stat = vim.uv.fs_stat(path or M.path())
  if not stat then
    return nil
  end
  return stat.mode % 512
end

--- @return table|nil creds { access_token, account_id, expires_at, path }
--- @return string|nil err
function M.load()
  local path = M.path()
  local data = read_file(path)
  if not data then
    return nil, "not logged in: run `codex login`"
  end

  local info = inspect(data)
  if info.err then
    return nil, info.err
  end

  if info.mode ~= "chatgpt" then
    return nil, "Codex is in API-key mode; sapho pilot needs a ChatGPT login (`codex login`)"
  end

  local tokens = info.decoded.tokens
  if type(tokens) ~= "table" or tokens.access_token == nil or tokens.access_token == "" then
    return nil, "auth.json is missing tokens.access_token"
  end
  if tokens.account_id == nil or tokens.account_id == "" then
    return nil, "auth.json is missing tokens.account_id"
  end

  if info.expires_at ~= nil and info.expires_at <= os.time() + 60 then
    return nil, "Codex token expired: run `codex` once (or `codex login`) to refresh"
  end

  return {
    access_token = tokens.access_token,
    account_id = tokens.account_id,
    expires_at = info.expires_at,
    path = path,
  }
end

--- Summary safe to notify/print: never contains a token.
--- @return table { ok, mode, expires_at, expired, err }
function M.status()
  local creds, err = M.load()
  if creds then
    return { ok = true, mode = "chatgpt", expires_at = creds.expires_at, expired = false, err = nil }
  end

  local mode, expires_at, expired
  local data = read_file(M.path())
  if data then
    local info = inspect(data)
    mode = info.mode
    expires_at = info.expires_at
    if expires_at ~= nil then
      expired = expires_at <= os.time() + 60
    end
  end

  return { ok = false, mode = mode, expires_at = expires_at, expired = expired, err = err }
end

return M
