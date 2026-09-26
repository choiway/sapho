local M = {}

local function format_duration(seconds)
  if seconds < 0 then
    seconds = 0
  end
  local days = math.floor(seconds / 86400)
  seconds = seconds % 86400
  local hours = math.floor(seconds / 3600)
  seconds = seconds % 3600
  local minutes = math.floor(seconds / 60)
  if days > 0 then
    return string.format("%dd %dh", days, hours)
  elseif hours > 0 then
    return string.format("%dh %dm", hours, minutes)
  else
    return string.format("%dm", minutes)
  end
end

local function check_neovim_version()
  vim.health.start("sapho: Neovim")
  if vim.fn.has("nvim-0.10") == 1 then
    local v = vim.version()
    vim.health.ok(string.format("%d.%d.%d", v.major, v.minor, v.patch))
  else
    vim.health.error("sapho requires Neovim >= 0.10 (vim.system, vim.base64, luanil)")
  end
end

local function check_curl(curl_cmd)
  vim.health.start("sapho: curl")

  local run_ok, proc = pcall(vim.system, { curl_cmd, "--version" }, { text = true })
  if not run_ok then
    vim.health.error(string.format("`%s` not found or failed to run", curl_cmd))
    return
  end

  local result = proc:wait()
  if result.code ~= 0 then
    vim.health.error(string.format("`%s --version` exited %d", curl_cmd, result.code))
    return
  end

  local line = (result.stdout or ""):match("^(.-)\r?\n") or result.stdout or ""
  vim.health.ok(line)

  local major, minor = line:match("curl (%d+)%.(%d+)")
  major, minor = tonumber(major), tonumber(minor)
  if not major then
    vim.health.warn("could not parse curl version")
  elseif major < 7 or (major == 7 and minor < 76) then
    vim.health.warn(string.format("curl %d.%d is older than 7.76; `--fail-with-body` is unavailable", major, minor))
  end
end

local function check_codex_cli()
  vim.health.start("sapho: codex CLI")
  if vim.fn.executable("codex") == 1 then
    vim.health.ok("found on PATH")
  else
    vim.health.warn("`codex` not found on PATH (needed to log in or refresh, not at runtime)")
  end
end

local function check_auth()
  local auth = require("sapho.auth")
  vim.health.start("sapho: Codex login")

  local path = auth.path()
  if not vim.uv.fs_stat(path) then
    vim.health.error(string.format("auth.json not found at %s: run `codex login`", path))
    return
  end
  vim.health.ok(string.format("found %s", path))

  local status = auth.status()

  if status.mode == "chatgpt" then
    vim.health.ok("auth_mode = chatgpt")
  else
    vim.health.error(
      string.format("auth_mode = %s; sapho pilot needs a ChatGPT login (`codex login`)", tostring(status.mode))
    )
  end

  if status.expired then
    vim.health.error("Codex token expired: run `codex` once (or `codex login`) to refresh")
  elseif status.expires_at == nil then
    vim.health.warn("token expiry unknown (could not decode JWT)")
  else
    local remaining = status.expires_at - os.time()
    local msg = string.format("token expires in %s", format_duration(remaining))
    if remaining < 3600 then
      vim.health.warn(msg)
    else
      vim.health.ok(msg)
    end
  end

  local perm = auth.permissions(path)
  if perm ~= nil then
    if perm % 64 ~= 0 then
      vim.health.warn(string.format("auth.json permissions are %03o; expected 0600 or narrower", perm))
    else
      vim.health.ok(string.format("auth.json permissions are %03o", perm))
    end
  end
end

function M.check()
  check_neovim_version()
  check_curl(require("sapho.config").get().curl)
  check_codex_cli()
  check_auth()
end

return M
