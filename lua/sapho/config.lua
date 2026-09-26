local M = {}

M.defaults = {
  model = "gpt-5.6-sol",
  effort = "xhigh", -- low | medium | high | xhigh
  reasoning_summary = "auto", -- retained for provider compatibility; not shown in reading UI
  codex_home = nil, -- nil -> $CODEX_HOME -> ~/.codex
  curl = "curl",
  keymap = nil, -- opt-in mapping to open the chat
  ui = {
    width = 80, -- floating chat width in columns
    height = 0, -- 0: two-thirds of available editor height; otherwise rows
  },
}

local valid_efforts = { low = true, medium = true, high = true, xhigh = true }

-- `codex_home = nil` in M.defaults above means that key is absent from the
-- table (assigning nil is the same as never setting it), so it can't be
-- used to recognize "codex_home" as a known top-level key. Track the
-- known set explicitly instead.
local known_keys = { model = true, effort = true, reasoning_summary = true, codex_home = true, curl = true, keymap = true, ui = true }

local function deep_merge(base, opts)
  local result = vim.deepcopy(base)
  for k, v in pairs(opts) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

-- Warn (don't error) on keys not present in defaults, so a typo doesn't
-- silently no-op.
local function warn_unknown_nested_keys(base, opts, prefix)
  for k, v in pairs(opts) do
    if base[k] == nil then
      vim.notify(string.format("sapho: unknown config key '%s%s'", prefix, tostring(k)), vim.log.levels.WARN)
    elseif type(v) == "table" and type(base[k]) == "table" then
      warn_unknown_nested_keys(base[k], v, prefix .. tostring(k) .. ".")
    end
  end
end

local function warn_unknown_keys(opts)
  for k, v in pairs(opts) do
    if not known_keys[k] then
      vim.notify(string.format("sapho: unknown config key '%s'", tostring(k)), vim.log.levels.WARN)
    elseif type(v) == "table" and type(M.defaults[k]) == "table" then
      warn_unknown_nested_keys(M.defaults[k], v, tostring(k) .. ".")
    end
  end
end

local function validate(opts)
  vim.validate({
    model = { opts.model, "string" },
    effort = { opts.effort, "string" },
    reasoning_summary = { opts.reasoning_summary, "string" },
    codex_home = { opts.codex_home, "string", true },
    curl = { opts.curl, "string" },
    keymap = { opts.keymap, "string", true },
    ui = { opts.ui, "table" },
  })
  vim.validate({
    ["ui.width"] = { opts.ui.width, "number" },
    ["ui.height"] = { opts.ui.height, "number" },
  })
  for _, key in ipairs({ 'width', 'height' }) do
    local value = opts.ui[key]
    if value < (key == 'height' and 0 or 1) or value ~= value or value == math.huge then
      error('sapho: ui.' .. key .. ' must be ' .. (key == 'height' and 'non-negative' or 'positive') .. ' and finite')
    end
  end
  if opts.keymap == '' then error('sapho: keymap must be non-empty or nil') end
  if not valid_efforts[opts.effort] then
    error(
      string.format(
        "sapho: invalid effort '%s' (must be one of: low, medium, high, xhigh)",
        tostring(opts.effort)
      )
    )
  end
end

local current = vim.deepcopy(M.defaults)

function M.setup(opts)
  opts = opts or {}
  vim.validate({ opts = { opts, "table" } })

  warn_unknown_keys(opts)
  local merged = deep_merge(M.defaults, opts)
  validate(merged)
  current = merged
  return current
end

function M.get()
  return current
end

return M
