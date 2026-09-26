# M0 — Skeleton

**Goal:** a loadable plugin with no behavior beyond opening a split, resolving
credentials from the Codex CLI login, and reporting health.

**Done when:** `lazy.nvim` loads it on a clean config with no errors,
`:Sapho` opens an empty split, and `:checkhealth sapho` reports curl and
Codex login status correctly.

---

## 0. Provider decision (pilot)

The pilot targets **OpenAI via the Codex CLI's ChatGPT login only**. There is
no Anthropic access and no API-key path. This replaces §3 "Protocol contract"
of `PLAN.md`:

- Credentials: `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`),
  written by `codex login`, `auth_mode = "chatgpt"`.
- Wire protocol: OpenAI **Responses API** streaming, served by the Codex
  backend that the Codex CLI itself uses. This endpoint is **not a public
  API**. It's undocumented and can change without notice. Treat breakage as
  expected, and keep all endpoint/header knowledge in one module (M2's
  `provider.lua`).
- Default model `gpt-5.6-sol`, reasoning effort `xhigh`.

### Token handling: read-only for the pilot

sapho **reads** `auth.json` and never writes it. Reason: refresh tokens are
single-use and rotate. If sapho refreshed without writing back, the Codex CLI
would be logged out. If it did write back, a concurrent `codex` process could
race it and one of them would be logged out anyway.

Consequence: when the access token is expired, sapho tells you to re-auth
(run `codex`, or `codex login`) instead of refreshing itself. Revisit after
the pilot. Doing this properly needs an atomic write-back plus a lock.

---

## 1. Files

```
plugin/sapho.lua        -- command registration only; no require() at load
lua/sapho/init.lua      -- setup(), open(), command dispatch
lua/sapho/config.lua    -- defaults, merge, validation
lua/sapho/auth.lua      -- Codex auth.json reader + JWT expiry
lua/sapho/health.lua    -- :checkhealth sapho
tests/minimal_init.lua  -- headless test bootstrap
tests/config_spec.lua
tests/auth_spec.lua
tests/init_spec.lua
tests/fixtures/auth/    -- fake auth.json files (fabricated tokens, never real)
Makefile                -- `make test`
.gitignore
```

Repo setup: `git init`, `.gitignore` with `.tests/` and
`tests/fixtures/*.tmp`.

---

## 2. `plugin/sapho.lua`

- Guard: `if vim.g.loaded_sapho then return end; vim.g.loaded_sapho = 1`.
- Registers `:Sapho` via `nvim_create_user_command`. The body lazily does
  `require("sapho").open()`, so startup cost is ~zero.
- Does **not** call `setup()`. Plugin works with defaults if the user never
  calls it.

## 3. `lua/sapho/config.lua`

```lua
M.defaults = {
  model       = "gpt-5.6-sol",
  effort      = "xhigh",               -- low | medium | high | xhigh
  reasoning_summary = "auto",          -- summaries render as folded "thinking"
  codex_home  = nil,                   -- nil -> $CODEX_HOME -> ~/.codex
  curl        = "curl",
  ui = {
    split = "vertical",                -- "vertical" | "horizontal"
    width = 80,
  },
}

function M.setup(opts)   -- deep-merge + validate; returns options
function M.get()
```

Validation: `vim.validate` on types. `effort` must be one of the listed
values, and anything else raises an error. Unknown keys produce a
`vim.notify` WARN (typo guard), not an error.

No `max_tokens`. Output length is left to the backend's default for the pilot.
Revisit in M2 if the backend accepts `max_output_tokens`.

## 4. `lua/sapho/auth.lua`

```lua
M.path()           -- resolved auth.json path
M.load()           -- -> creds | nil, err
-- creds = { access_token, account_id, expires_at (unix secs|nil), path }
M.status()         -- -> { ok, mode, expires_at, expired, err } ; no secrets
```

`load()`:

1. Resolve the path: `config.codex_home` → `$CODEX_HOME` → `~/.codex`, plus `/auth.json`.
2. Read the file with `vim.uv.fs_*` (sync is fine; it's tiny). Missing file → `nil,
   "not logged in: run `codex login`"`.
3. `vim.json.decode(..., { luanil = { object = true, array = true } })`.
4. `auth_mode ~= "chatgpt"` → `nil, "Codex is in API-key mode; sapho pilot
   needs a ChatGPT login (`codex login`)"`.
5. Require non-empty `tokens.access_token` and `tokens.account_id`.
6. `expires_at`: decode the access token's JWT payload (base64url → pad →
   `vim.base64.decode` → json) and read `exp`. On any decode failure,
   `expires_at = nil` (unknown, not fatal).
7. Expired (`exp <= now + 60`) → `nil, "Codex token expired: run `codex` once
   (or `codex login`) to refresh"`.

Hygiene:

- Tokens are never logged, never shown via `vim.notify`, and never
  included in error messages or `status()`.
- The file is re-read on every `load()` (no caching), so a refresh done by
  `codex` in another terminal is picked up immediately.
- If `auth.json` is group- or world-readable, emit a warning via health (not an error).

## 5. `lua/sapho/init.lua`

```lua
M.setup(opts)   -- config.setup(opts)
M.open()        -- open or focus the sapho window
```

`open()`:

- If a sapho window is visible in the current tabpage, focus it.
- Otherwise create (or reuse) a scratch buffer: `buftype=nofile`,
  `bufhidden=hide`, `swapfile=false`, `filetype=sapho`, name `sapho://chat`,
  and open it in a split per `ui.split` / `ui.width`.
- This is the future transcript buffer. The input buffer (two-buffer design,
  decided) arrives in M3.

## 6. `lua/sapho/health.lua`

`vim.health.start/ok/warn/error`. No network calls, so health is instant and free.

| Check | ok | error/warn |
|---|---|---|
| Neovim ≥ 0.10 | version | error (`vim.system`, `vim.base64`, `luanil` required) |
| `curl` executable | first line of `curl --version` | error |
| curl ≥ 7.76 (`--fail-with-body`) | version | warn |
| `codex` on PATH | found | warn only; needed to log in or refresh, not at runtime |
| auth.json present | path | error: run `codex login` |
| auth mode | `chatgpt` | error if `apikey` or missing |
| token expiry | "expires in 3d 4h" | error if expired; warn if < 1h or unknown |
| file permissions | `0600` | warn if wider |

## 7. Test harness

`tests/minimal_init.lua`:

- `vim.opt.rtp:prepend(".")`
- Plenary: `$PLENARY_DIR`, else `stdpath("data") .. "/lazy/plenary.nvim"`,
  else clone into `.tests/plenary`.
- `vim.opt.rtp:prepend(plenary)`; `vim.cmd("runtime plugin/plenary.vim")`.
- `vim.o.swapfile = false`.

`Makefile`:

```make
test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
	  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua', sequential = true}"
```

## 8. Tests

`tests/config_spec.lua`:

- defaults when `setup()` is never called
- deep merge keeps untouched nested defaults
- invalid `effort` → error; unknown key → WARN, no error

`tests/auth_spec.lua` uses fixture files under `tests/fixtures/auth/`
containing **fabricated** JWTs. They're built in the spec from a known
payload, so they don't depend on the wall clock.

- valid chatgpt auth → creds with the right `account_id` and `expires_at`
- missing file / `auth_mode = "apikey"` / missing `account_id` → specific messages
- expired `exp` → expired error
- malformed JWT → `expires_at = nil`, still loads
- resolution order: `config.codex_home` > `$CODEX_HOME` > `~/.codex`
- no error message or `status()` output contains the token string (assert
  with `string.find(msg, token, 1, true) == nil`)

`tests/init_spec.lua` (smoke):

- `open()` creates exactly one sapho window. A second call focuses it.
- buffer options as specified

## 9. Manual acceptance

- Run `! codex login` first. The current `auth.json` was last refreshed
  2026-04-07 and is certainly expired.
- Clean config (`NVIM_APPNAME=sapho-clean`), lazy spec `{ dir = "~/source/sapho" }`
  → no errors in `:Lazy` or `:messages`.
- `:Sapho` opens the split.
- `:checkhealth sapho` all green. After temporarily pointing
  `codex_home` at an empty dir, it shows the login error.

## Out of scope

Keymaps, input buffer, any network activity, token refresh, session state.
