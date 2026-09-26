# Sapho — an in-process Neovim coding agent

> *"It is by will alone I set my mind in motion."*

A coding agent that lives inside Neovim as a Lua plugin. Not a terminal
wrapper, not an RPC client — in-process, with the full Neovim API as its
tool surface.

---

## 1. Thesis

A CLI coding agent in your repo has to grep, guess, and re-read. An agent
running *inside* the editor has a live semantic index (LSP), a concrete
syntax tree (treesitter), the diagnostic state of every open buffer, and an
undo tree it can participate in.

**The differentiator is the tool surface, not the chat window.** The chat
buffer is ~400 lines of Lua and every plugin in this space already has one.
The interesting work is exposing Neovim's knowledge of the codebase as
tools the model can call, and making edits reversible through the editor's
own mechanisms rather than a bolted-on revert system.

### Goals

- Pure Lua, zero external runtime. Installable with `lazy.nvim`, no
  companion binary, no `pip install`, no node_modules.
- LSP / treesitter / diagnostics as first-class tools.
- Every agent turn is exactly one `u` away from reverted.
- Streaming that doesn't stutter the UI.

### Non-goals (v1)

- Multi-provider abstraction. The pilot uses one provider: OpenAI's
  Responses API through the Codex CLI's ChatGPT login. No Anthropic access,
  no API-key path. Generalize later, if ever.
- Inline ghost-text completion. That is `sidekick.nvim`'s job and it is a
  different product.
- Subagents, background tasks, MCP client. Revisit after the core loop is
  boring.

### Prior art to read before writing code

`olimorris/codecompanion.nvim` (cleanest chat-buffer implementation),
`folke/sidekick.nvim` (inline UX), `yetone/avante.nvim` (diff review flow),
`coder/claudecode.nvim` (protocol handling), `openai/codex` (the
authoritative source for the Codex backend's endpoint, headers and request
shape; read its request builder rather than guessing).

---

## 2. Architecture

Single-threaded, libuv event loop, coroutine-based control flow.

```
 user keypress
      |
 ui/input.lua  -- prompt buffer, <CR> submits
      |
 agent.lua     -- coroutine: the tool loop
      |         |
      |         +-- tools/*.lua  (LSP, treesitter, buffer, shell)
      |
 provider.lua  -- builds Responses request, spawns curl (auth.lua for creds)
      |
 sse.lua       -- byte chunks -> typed events
      |
 ui/chat.lua   -- extmark-anchored streaming render
```

`agent.lua` runs inside a coroutine so the loop reads linearly:

```lua
local resp    = provider.stream(session:messages())   -- yields
local results = tools.run_all(resp.tool_uses)         -- yields
session:append(results)
```

Everything async yields through `async.await`. Without this the code becomes
six levels of nested callbacks by milestone 4.

### Module layout

```
lua/sapho/
  init.lua        -- setup(), user commands, keymaps, health check
  config.lua      -- defaults + user overrides
  auth.lua        -- read-only Codex auth.json reader, token expiry
  async.lua       -- await / schedule wrappers        <- build first
  sse.lua         -- SSE chunk reassembly + event typing
  provider.lua    -- Responses API: request build, curl spawn, event -> item
  session.lua     -- message history, persistence, token accounting
  agent.lua       -- the tool loop
  tools/
    init.lua      -- ordered registry, schema export, dispatch
    lsp.lua       -- definition, references, symbols, diagnostics, rename
    treesitter.lua-- node at cursor, enclosing scope, structural queries
    buffer.lua    -- read, edit, list, diff
    shell.lua     -- gated command execution
    quickfix.lua  -- publish findings to the quickfix list
  ui/
    chat.lua      -- transcript buffer, streaming render, folds
    input.lua     -- prompt buffer
    diff.lua      -- accept / reject hunks
    approve.lua   -- permission prompts
  health.lua      -- :checkhealth sapho
plugin/sapho.lua  -- command registration only
tests/            -- plenary busted specs
```

---

## 3. Protocol contract

OpenAI **Responses API**, streaming, through the Codex backend that the
Codex CLI uses, authenticated with the Codex CLI's ChatGPT login. This
endpoint is **not a public API**: it is undocumented and may change without
notice. All endpoint and header knowledge lives in `provider.lua`, taken
from the `openai/codex` source (record the commit it was read from).

```lua
{
  model        = "gpt-5.6-sol",
  stream       = true,
  store        = false,                  -- no server state; resend full input
  instructions = SYSTEM,                 -- byte-stable, see §7
  reasoning    = { effort = "xhigh", summary = "auto" },
  include      = { "reasoning.encrypted_content" },
  tools        = tools.schemas(),        -- ORDERED array, see §7
  input        = session:items(),
  -- exact required fields/headers: verify against openai/codex at M2
}
```

### Credentials

`auth.lua` reads `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`),
written by `codex login`. It requires `auth_mode = "chatgpt"` and uses
`tokens.access_token` and `tokens.account_id`. It reads token expiry from the
JWT `exp` claim.

**Read-only for the pilot.** Refresh tokens can only be used once and are
replaced on every refresh. If sapho refreshed without writing the new token
back, the `codex` CLI would be logged out. If it did write back, it would
race any running `codex` process. On expiry, or on a 401 that persists after
re-reading the file once, sapho tells the user to run `codex` or
`codex login`.

### SSE events to handle

| Event | Action |
|---|---|
| `response.created` | turn start, reset item accumulator |
| `response.output_item.added` | open item by `output_index` (`message` / `reasoning` / `function_call`) |
| `response.output_text.delta` | render |
| `response.reasoning_summary_text.delta` | render into a closed fold |
| `response.function_call_arguments.delta` | concat arguments (for display only) |
| `response.output_item.done` | **authoritative** final item: full `arguments`, `encrypted_content` |
| `response.completed` | final `usage`, resume the agent coroutine |
| `response.incomplete` | truncated: surface, run **no** tool calls from it |
| `response.failed` / `error` | surface, abort turn cleanly |
| anything else | ignore (pass-through in `sse.lua`) |

### Loop termination

The response contains `function_call` items → execute them, append the
results, request again. No function calls → turn over. Guard with a
max-iteration cap.

Rules that are easy to get wrong:

- **Echo reasoning items back unchanged**, `encrypted_content` included. With
  `store = false`, this is the only way reasoning carries over between
  requests.
- **Answer every `call_id` in the next request.** Each result is its own
  `function_call_output` item, and all of a turn's results go in the same
  request. Cancellation leaves some calls unanswered, so the session adds
  synthetic error outputs for them before the next request.
- **Append-only history.** Append the output items exactly as received.
  Never rewrite earlier items; that breaks the cache prefix.

---

## 4. Milestones

Each milestone ends in something demonstrable. No milestone depends on a
later one being designed correctly.

### M0 — Skeleton
Loadable plugin, `:Sapho` opens an empty split, `auth.lua` reads the Codex
login from `auth.json`. `:checkhealth sapho` verifies curl, the login mode,
token expiry and file permissions, with no network call.
Spec: `specs/M0-skeleton.md`.
**Done when:** `lazy.nvim` loads it with no errors on a clean config.

### M1 — Async + SSE
`async.lua` and `sse.lua`, with tests. `sse.lua` is pure data
transformation and should be tested against captured fixture bytes split at
adversarial boundaries (mid-UTF-8, mid-`data:` line, mid-JSON).
Fixtures are captured from the real Codex backend.
**Done when:** fixture replay produces the correct event sequence for every
chunk split. Spec: `specs/M1-async-sse.md`.

### M2 — Streaming round-trip
`provider.lua` spawns curl, `sse.lua` parses, text lands in the buffer.
No tools, no history, one-shot. Handles `--fail-with-body` error bodies,
401 (re-read `auth.json` once, then tell the user to re-auth) and 429
(show the usage-limit message verbatim, back off).
**Done when:** typing a prompt streams a visible answer, and `<C-c>` cancels
it cleanly. Spec: `specs/M2-streaming-roundtrip.md`.

### M3 — Chat UI
Transcript buffer (read-only) + input buffer. Extmark-anchored appends,
timer-batched flush (~40ms), reasoning summaries in closed folds, token
usage line in the winbar (plan usage is not metered in dollars). `session.lua` holds multi-turn history.
**Done when:** a five-turn conversation reads well and the buffer doesn't
scroll-jump while streaming. Spec: `specs/M3-chat-ui.md`.

### M4 — Read-only tools
Registry + dispatch + three tools: `buffer_read`, `lsp_diagnostics`,
`lsp_definition`. No approval — reads are free. Spec: `specs/M4-read-only-tools.md`.
**Done when:** "what's the type error in this file and where is that
function defined" is answered without a single grep.

### M5 — Interactive edits
Stage `buffer_edit` proposals in a diff before applying them. Pause at each
function-sized checkpoint so the user can inspect callers/definitions in
Neovim, accept/reject/revise, and steer the next change. Guard accepted edits
with `changedtick`; never overwrite intervening user work. Spec:
`specs/M5-interactive-edits.md`.
**Done when:** a two-function refactor can be redirected mid-turn without a
surprise large diff. With no intervening user writes/undos, one `u` per
touched buffer reverts the agent's accepted edits; never merge user edits into
that undo group.

### M6 — Shell + permissions
`shell.lua` behind the tiered approval model (§6). Approval decisions
persist per-session.
**Done when:** the agent can run the test suite and iterate on failures.

### M7 — Durability
Session persistence to `stdpath('state')`, prompt-cache verification,
context compaction when history grows past the window.
**Done when:** `usage.input_tokens_details.cached_tokens` is non-zero on
every turn after the first, and a 100-turn session still works.

---

## 5. Tool surface

The reason this project exists. Prioritized by how much better they are
than the CLI-agent equivalent.

| Tool | Backed by | Beats |
|---|---|---|
| `lsp_diagnostics` | `vim.diagnostic.get()` | running the type checker |
| `lsp_definition` / `lsp_references` | `vim.lsp.buf_request_all` | grep + guessing |
| `lsp_document_symbols` / `workspace_symbols` | LSP | `find` + regex |
| `lsp_rename` | LSP rename | N sed commands and a prayer |
| `ts_enclosing_scope` | treesitter | line-range heuristics |
| `buffer_read` | open buffers | reading stale on-disk content |
| `buffer_edit` | `apply_text_edits` + `undojoin` | opaque file writes |
| `editor_context` | selection, marks, layout, fugitive state | nothing — unavailable to a CLI agent |
| `quickfix_publish` | `setqflist` | findings printed into scrollback |

`editor_context` is the sleeper. "The thing I'm looking at" is free
information in-editor and unobtainable outside it.

---

## 6. Permission model

In-process means no sandbox. The agent's tools run with the editor's full
authority, so the approval layer is a correctness feature.

**Tiered:**

| Tier | Tools | Gate |
|---|---|---|
| Free | all reads, all LSP queries, treesitter | none |
| Reviewed | `buffer_edit` in a loaded buffer inside cwd | staged diff + explicit accept/reject/revise (M5 default) |
| Confirmed | writes outside cwd, `shell` | `vim.ui.select` prompt |

Reads-are-free is what makes the LSP surface feel fast enough to be worth
having. Gate reads and the agent feels slower than grep, which defeats the
premise.

Review-before-apply is the M5 default: the user can navigate real source
buffers while the agent is paused. Optimistic auto-apply may become an opt-in
mode after the guarded review path is reliable. Neovim undo remains a
backstop, not a substitute for steering; do not join agent and user edits
into the same undo entry.

---

## 7. Known traps

Collected in advance because each of these fails *silently*.

**`pairs()` order breaks prompt caching.** Caching is automatic, keyed on
an exact prefix of `instructions`, `tools` and `input`. Building the tools
array by iterating a hash table yields a different order per process, and
you lose caching with no error. Keep the registry an ordered array or sort
by name before encoding. Keep `instructions` byte-stable (no timestamps) and
history append-only. Verify with `usage.input_tokens_details.cached_tokens`.

**`vim.json.encode({})` emits `[]`, not `{}`.** An empty `properties` or
empty tool input serializes as a JSON array and fails schema validation
confusingly. Use `vim.empty_dict()`.

**`vim.json.decode` returns `vim.NIL` for JSON `null`**, which is truthy in
Lua.

**`vim.system` callbacks run in a fast event context.** No buffer API calls
from them — everything that renders goes through `vim.schedule()`.

**curl stdout chunks are not line-aligned.** `sse.lua` needs a carry buffer.
Test with adversarial splits.

**Tokens in argv are world-readable** via `/proc`. Use `curl -K -` and pass
the `Authorization` (and account) headers on stdin instead of `-H`. Because
stdin then carries the config, the body goes via `--data-binary @<tempfile>`
from `vim.fn.tempname()` (a private directory), deleted after the request.

**Codex refresh tokens rotate.** Each refresh token can be used once, and a
refresh invalidates the old one. Refreshing from sapho without writing back
logs out the `codex` CLI. The pilot reads `auth.json` only and never
refreshes.

**The Codex backend is not a public API.** Request shape, headers and event
names can change without notice. Keep all of it in `provider.lua`, and treat
the captured fixtures as the source of truth for event shapes.

**`response.incomplete` means truncated output.** A `function_call` item in a
truncated response may have partial `arguments`. Never run it.

**`undojoin` throws** if the previous change was itself an undo. Wrap in
`pcall`. It also silently merges *the user's* edits into the agent's undo
step if they typed between two agent edits. Record `changedtick` after each
agent edit, and only join when it is unchanged.

**Per-token buffer writes melt the CPU.** Accumulate, flush on a
`vim.uv.new_timer()`.

**Line-number anchors drift.** Anchor the streaming write position with an
extmark so user edits above the cursor don't corrupt it.

---

## 8. Testing

`plenary.nvim` busted specs, run headless:

```
make test
```

`sse.lua` and `session.lua` are pure and should be thoroughly tested.
`provider.lua` gets a fake-curl injection point that replays the captured
fixtures, so the suite never touches the network or the user's login. UI modules get smoke tests
only — assert buffer contents after a scripted event sequence, don't try to
test rendering.

---

## 9. Open questions

1. ~~**One buffer or two?**~~ **Decided: two.** A read-only transcript plus
   a separate input buffer, for full vim editing on the prompt.
2. **Where does context selection live?** Explicit (`:SaphoAdd` on a
   selection) or implicit (agent calls `editor_context`)? Probably both,
   but the default matters.
3. **Compaction strategy.** Whether the Codex backend offers server-side
   compaction, or sapho summarizes locally. Defer to M7.
4. **Does `shell` belong at all?** If LSP + treesitter + edits cover the
   work, `shell` is the tool that turns a safe plugin into an unsafe one.
   Reconsider at M6 rather than assuming.
5. **Token refresh.** Should sapho refresh expired tokens itself? Doing it
   safely needs an atomic write-back to `auth.json` and a lock shared with
   the `codex` CLI. Revisit after the pilot.
6. **API-key fallback.** Should an `OPENAI_API_KEY` against the public
   Responses API be a supported fallback if the Codex endpoint changes?
   Out of scope for the pilot.
