local auth = require("sapho.auth")
local config = require("sapho.config")

-- Fabricated JWTs, built here from a known payload so the "valid" and
-- "expired" cases never depend on the wall clock at the moment the fixture
-- was written -- only on os.time() when the test runs.
local function b64url(str)
  local out = vim.base64.encode(str)
  out = out:gsub("+", "-"):gsub("/", "_"):gsub("=+$", "")
  return out
end

local function fake_jwt(payload)
  local header = b64url(vim.json.encode({ alg = "none", typ = "JWT" }))
  local body = b64url(vim.json.encode(payload))
  return header .. "." .. body .. ".fake-signature"
end

local FIXTURES_DIR = vim.fn.getcwd() .. "/tests/fixtures/auth"
local created_dirs = {}
local scratch_seq = 0

-- Fixtures live under tests/fixtures/auth/ as the spec's file layout
-- requires, but each case's auth.json is generated fresh per test run
-- (hence the .tmp suffix, gitignored) rather than committed, since the
-- valid/expired cases need an `exp` relative to os.time() right now.
local function scratch_dir()
  scratch_seq = scratch_seq + 1
  local dir = string.format("%s/case-%d-%d.tmp", FIXTURES_DIR, vim.uv.getpid(), scratch_seq)
  vim.fn.mkdir(dir, "p")
  table.insert(created_dirs, dir)
  return dir
end

local function write_auth(dir, tbl)
  local path = dir .. "/auth.json"
  local file = assert(io.open(path, "w"))
  file:write(vim.json.encode(tbl))
  file:close()
  return path
end

describe("sapho.auth", function()
  after_each(function()
    config.setup({})
    vim.uv.os_unsetenv("CODEX_HOME")
    for _, dir in ipairs(created_dirs) do
      vim.fn.delete(dir, "rf")
    end
    created_dirs = {}
  end)

  it("loads valid chatgpt creds with the right account_id and expires_at", function()
    local dir = scratch_dir()
    local exp = os.time() + 3600
    local token = fake_jwt({ exp = exp })
    write_auth(dir, {
      auth_mode = "chatgpt",
      tokens = { access_token = token, account_id = "acct_123" },
    })
    config.setup({ codex_home = dir })

    local creds, err = auth.load()
    assert.is_nil(err)
    assert.are.equal(token, creds.access_token)
    assert.are.equal("acct_123", creds.account_id)
    assert.are.equal(exp, creds.expires_at)
    assert.are.equal(dir .. "/auth.json", creds.path)
  end)

  it("reports 'not logged in' when auth.json is missing", function()
    local dir = scratch_dir()
    config.setup({ codex_home = dir })

    local creds, err = auth.load()
    assert.is_nil(creds)
    assert.matches("not logged in", err)
  end)

  it("rejects API-key mode", function()
    local dir = scratch_dir()
    write_auth(dir, {
      auth_mode = "apikey",
      tokens = { access_token = "irrelevant", account_id = "irrelevant" },
    })
    config.setup({ codex_home = dir })

    local creds, err = auth.load()
    assert.is_nil(creds)
    assert.matches("API%-key mode", err)
  end)

  it("reports a missing account_id", function()
    local dir = scratch_dir()
    write_auth(dir, {
      auth_mode = "chatgpt",
      tokens = { access_token = "some-fabricated-token" },
    })
    config.setup({ codex_home = dir })

    local creds, err = auth.load()
    assert.is_nil(creds)
    assert.matches("account_id", err)
  end)

  it("reports an expired token", function()
    local dir = scratch_dir()
    local token = fake_jwt({ exp = os.time() - 3600 })
    write_auth(dir, {
      auth_mode = "chatgpt",
      tokens = { access_token = token, account_id = "acct_1" },
    })
    config.setup({ codex_home = dir })

    local creds, err = auth.load()
    assert.is_nil(creds)
    assert.matches("expired", err)
  end)

  it("still loads with a malformed JWT, leaving expires_at nil", function()
    local dir = scratch_dir()
    write_auth(dir, {
      auth_mode = "chatgpt",
      tokens = { access_token = "not-a-real-jwt", account_id = "acct_1" },
    })
    config.setup({ codex_home = dir })

    local creds, err = auth.load()
    assert.is_nil(err)
    assert.is_nil(creds.expires_at)
  end)

  it("resolves codex_home as config > $CODEX_HOME > ~/.codex", function()
    local config_dir = scratch_dir()
    local env_dir = scratch_dir()
    local home_dir = scratch_dir()
    local home_codex_dir = home_dir .. "/.codex"
    vim.fn.mkdir(home_codex_dir, "p")

    write_auth(config_dir, {
      auth_mode = "chatgpt",
      tokens = { access_token = "t", account_id = "from_config" },
    })
    write_auth(env_dir, {
      auth_mode = "chatgpt",
      tokens = { access_token = "t", account_id = "from_env" },
    })
    write_auth(home_codex_dir, {
      auth_mode = "chatgpt",
      tokens = { access_token = "t", account_id = "from_home" },
    })

    vim.uv.os_setenv("CODEX_HOME", env_dir)

    config.setup({ codex_home = config_dir })
    local creds = auth.load()
    assert.are.equal("from_config", creds.account_id)

    config.setup({})
    creds = auth.load()
    assert.are.equal("from_env", creds.account_id)

    vim.uv.os_unsetenv("CODEX_HOME")
    local original_homedir = vim.uv.os_homedir
    vim.uv.os_homedir = function()
      return home_dir
    end
    local ok, home_creds = pcall(auth.load)
    vim.uv.os_homedir = original_homedir

    assert.is_true(ok)
    assert.are.equal("from_home", home_creds.account_id)
  end)

  it("never leaks the token in an error message or status()", function()
    local dir = scratch_dir()
    local token = fake_jwt({ exp = os.time() - 3600 })
    write_auth(dir, {
      auth_mode = "chatgpt",
      tokens = { access_token = token, account_id = "acct_1" },
    })
    config.setup({ codex_home = dir })

    local creds, err = auth.load()
    assert.is_nil(creds)
    assert.is_nil(string.find(err, token, 1, true))

    local status = auth.status()
    local encoded = vim.json.encode(status)
    assert.is_nil(string.find(encoded, token, 1, true))
  end)
end)
