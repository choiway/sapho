# M2 — Streaming round-trip

**Goal:** from `:Sapho`, submit one prompt and watch a real Codex Responses API answer appear in the Neovim buffer. `<C-c>` cancels the active request. No tools, multi-turn history, persistence, or polished chat UI.

**Done when:** a prompt submitted in Neovim streams a visible answer using the ChatGPT Codex login; cancellation, HTTP/stream errors and cleanup are correct; fake-transport tests pass offline; `make test` is green.

## 1. Starting point and boundaries

- M0 supplies `:Sapho`, `auth.load()`, and the `sapho://chat` scratch buffer.
- M1 supplies `async.run/await` and `sse.decoder()`, plus real captured fixtures. Those fixtures were captured with `gpt-5.5`; the **current default** and new live requests use `gpt-5.6-sol`. Keep the older fixtures as regression inputs; do not silently rewrite them.
- This is **one-shot**: each submission sends only that prompt. Earlier visible text is *not* sent again. M3 builds the separate read-only transcript + editable input buffer and `session.lua` for multi-turn history.
- This milestone consumes ChatGPT-plan Codex usage only for manual live acceptance. All automated tests use fake transport and fabricated credentials.

## 2. Files

```
lua/sapho/provider.lua       -- request, curl transport, event/item assembly, errors
lua/sapho/init.lua           -- minimal one-line prompt and streaming/cancel wiring
plugin/sapho.lua             -- only if a command change is needed
tests/provider_spec.lua      -- fake transport: request/stream/error/cancel assertions
tests/init_spec.lua          -- UI smoke test with injected provider
```

Avoid creating `agent.lua`, `session.lua`, `ui/chat.lua`, `ui/input.lua`, or tool modules in M2. Keep transport injected at the provider boundary, not by replacing `vim.system` globally in tests.

## 3. Protocol: verify before coding

Before implementing, re-read `openai/codex`'s current `codex-rs/core/src/client.rs` request builder, `codex-rs/codex-api/src/endpoint/responses.rs`, and auth/header setup. Record the inspected commit hash in `provider.lua`. The backend is private and may have changed since fixture capture (capture script recorded `e72da2b53805894878023d01949a25a082e0a5cb`). `gpt-5.4` and `gpt-5.3-codex` were rejected for this account; `gpt-5.6-sol` appears in its model list. Confirm it with a **single** manual live request; if rejected, report the exact backend error rather than silently switching models.

Initial one-shot body (match the verified builder; reject fields the backend does not accept):

```lua
{
  model = config.get().model,             -- default gpt-5.6-sol
  instructions = SYSTEM,                  -- fixed, byte-stable string
  input = { { role = "user", content = prompt } },
  stream = true,
  store = false,
  reasoning = { effort = config.get().effort, summary = config.get().reasoning_summary },
  include = { "reasoning.encrypted_content" },
  tools = {},                             -- empty array, no tool dispatch in M2
  tool_choice = "auto",                   -- only if required/accepted with no tools
}
```

The verified endpoint is `https://chatgpt.com/backend-api/codex/responses` (POST, SSE). Headers include `Authorization: Bearer <access_token>`, `chatgpt-account-id: <account_id>`, `Content-Type: application/json`, and `Accept: text/event-stream`; add other required headers only after checking the builder. `auth.load()` is read-only: **never refresh or write** `auth.json`.

## 4. Provider contract and transport

Design a small API, e.g. `provider.start(prompt, on_event, on_done, deps?) -> handle`:

- `on_event(ev)` is called **on the Neovim main loop** for typed events (especially text deltas). No buffer API in curl/libuv callbacks.
- `on_done(result, err)` is called **once**, on the main loop, with `result = { id, output, usage }` on a complete response; `on_done(nil, "cancelled")` on cancellation; or a sanitized actionable error. Return `handle.cancel()` (idempotent). Document any final API changes in this spec when implementing.
- Collect authoritative `response.output_item.done` items in `output_index` order for M3, with `encrypted_content` untouched; track deltas only for rendering, **not** as final output. Do not execute or submit function calls. If an unexpected tool call arrives, show a clear “tool execution not available yet” message rather than pretending to have finished a tool loop. No history or next request.
- `response.created` records `response.id`; `response.completed` supplies usage and is success **only if** status is `completed`. `response.incomplete` (no tool execution), `response.failed`, `error`, and `parse_error` abort with readable messages. Unknown events pass through without failure. A lone `[DONE]` without `response.completed` is not success.
- Always wait for both stdout EOF and process exit before finalizing. Feed chunks in order, call decoder `finish()` once at EOF, then resolve based on terminal event **and** curl exit code. Never report success just because curl exited 0 or a `response.completed` frame appeared before a later transport failure.

Use `vim.system` with stdout/stderr streaming callbacks and `--no-buffer --silent --show-error --fail-with-body`. Pass a quoted curl config containing auth headers via **stdin** (`curl -K -`), never token/account in argv, error text, or notifications. Generate the JSON body in a private temporary directory (0700, with 0600 file), pass only its path in `--data-binary @<path>`, and remove it on **all** exits (success, HTTP error, parse error, cancel, spawn error). The request prompt must not appear on argv either. Do not use `-i`/`-v` or include response headers in the SSE decoder. Set an explicit timeout (and no curl retry flags); `config.curl` is the executable.

A `vim.system` callback runs in a fast event: queue stdout chunks and schedule one drain that calls `decoder:feed()` and `on_event()`. Gate finalization on stdout EOF and process exit so the final scheduled chunks are drained before `finish()`. Buffer stderr and non-SSE HTTP response bodies with a size bound for diagnostics, but never log a raw header/config or traceback containing credentials. Injection point: a fake spawn function accepting argv/options and invoking the same stdout/stderr/exit callbacks; return a fake process supporting `kill`. Unit tests inspect the argv (no token/prompt), stdin config (proper escaping), and body-file permissions/content **only during** the fake process's lifetime. Do not consult real auth or network in unit tests.

### Cancellation and retry rules

- `<C-c>` calls `handle.cancel()`: mark the `async.run` task cancelled, terminate curl, suppress subsequent deltas, resolve `on_done(nil, "cancelled")` once, and clean files after process exit. Protect the fast-event callbacks from errors and late events. Multiple cancels and cancel-after-done are no-ops. Cancellation during backoff must also stop promptly.
- HTTP **401**: re-read `auth.json` exactly once; if access token changed, retry **once** with new credentials and a new process; otherwise tell the user to run `codex login`. Never print either token. A second 401 always asks for re-auth.
- HTTP **429**: surface the server's usage-limit message verbatim (only the error message field, not an unfiltered body). Back off with a bounded, cancellable delay; at most one retry if the response signals a transient rate limit. A plan/usage exhaustion error should not be retried. Document the chosen delay/decision in tests; no unbounded loops.
- Other non-2xx, signal termination, missing terminal event, malformed SSE, and partial/incomplete output fail visibly rather than being treated as a valid answer. It is acceptable to keep text already streamed on screen, clearly marked as incomplete.

## 5. Temporary input/rendering (replaced in M3)

Keep `:Sapho` opening the current scratch split. Add an obvious single-line prompt at the bottom (`> `), normal-mode `<CR>` submits its contents, and insert-mode `<CR>` submits after leaving insert mode; empty/whitespace prompts do nothing. Use a buffer-local `<C-c>` mapping in normal and insert mode to cancel, **not** global mappings. During a request, reject duplicate submissions; show the prompt and stream only `response.output_text.delta` into the same buffer. Do not render raw `encrypted_content`, reasoning ciphertext, HTTP JSON, or tokens. Display completion/error/cancel status and restore an editable prompt for the next independent one-shot request.

Document the temporary editing limitations (one line, no conversation context). Never call buffer APIs in fast-event callbacks; schedule/batch small updates to avoid one `nvim_buf_set_lines` per byte. If the buffer/window closes mid-request, cancel and clean up without re-creating it. M3 owns the extmark-anchored transcript, read-only buffer, real input buffer, folds, and robust scroll behavior.

## 6. Tests

`tests/provider_spec.lua` with fake spawn + fake auth (no real creds or network):

1. Request body equals expected Responses shape for `gpt-5.6-sol`, contains no tools/history; `store=false`, `stream=true`, encrypted reasoning requested; curl argv contains neither fabricated token/account nor prompt; stdin config and body file permissions are correct; files are removed afterward.
2. Replay `text_only`, `multibyte`, `reasoning_tool` with arbitrary chunk boundaries; `on_event` deltas in order, `on_done` once, complete `output_item.done` items ordered (including encrypted reasoning), usage captured; code runs outside fast-event context. Reasoning tool is collected but **never executed**.
3. `failed_midstream`, decoder parse_error, incomplete, missing `response.completed`, HTTP 4xx/5xx with body, stderr, nonzero exit, spawn failure, and stdout EOF/exit arriving in either order: never succeed; no stuck tasks.
4. 401 unchanged token → re-auth hint; 401 changed token → one retry; second 401 → stop. 429 transient → bounded backoff and at most one retry; quota error → verbatim message without retry. Inject delay to keep tests instantaneous.
5. Cancel before first byte, midstream, during 429 backoff, twice, and after done: process terminated when appropriate, one completion callback, no late rendering, all temp files removed.

`tests/init_spec.lua`: fake provider for prompt submission, visible incremental text, duplicate/empty prompt guard, `<C-c>` cancellation, window close cleanup. Keep setup and existing open/focus behavior working.

Run `make test` without Codex login. For manual acceptance only: log in via `codex login`, open `:Sapho`, enter “Reply with exactly: hello world”, press `<CR>` and observe incremental text; repeat with a long answer and cancel with `<C-c>`. Inspect `:messages` for credential leaks. Do **not** record new live streams or tokens in test logs.

## 7. Work order / exit criteria

1. Verify current Codex source request/header shape and one live `gpt-5.6-sol` request (minimal usage).
2. Build offline fake transport and provider request/stream lifecycle with tests; implement cancellation, HTTP handling, EOF/exit coordination, and cleanup.
3. Wire temporary buffer input/render and smoke-test it.
4. Manual live round-trip and cancellation; `make test` green.

**Implementation notes (M2):** `provider.start(prompt, on_event, on_done, deps?)` returns `{ cancel = function }`; `deps` may inject `spawn(argv, opts, exit_cb)`, `load()` and `delay(ms, cb)` (returning a timer cancellation function). No `async.run` task is created: the provider's own cancelled state gates scheduled drains, callbacks and retries. A 429 retries once after a cancellable 1000 ms delay only when the JSON error has `type=rate_limit_error` or `code=rate_limit_exceeded/rate_limit_error`; quota errors do not retry. The temporary UI edits only a single `> ` line and does not send previous answers. The current upstream request shape was checked at `e72da2b53805894878023d01949a25a082e0a5cb`; one manual live `gpt-5.6-sol` response returned “hello world”, and a second long-answer request cancelled successfully. No live streams were recorded.

**Carry to M3:** replace the temporary input/output UI with two buffers, session history (echo authoritative reasoning/function-call items, including `encrypted_content`, with `store=false`), extmarks/batched rendering, and token usage display. A one-shot M2 response is not a conversation, even if older text stays visible in the buffer.
