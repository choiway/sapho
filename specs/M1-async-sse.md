# M1 — Async + SSE

**Goal:** the two pure foundations everything else builds on: a coroutine
`await` layer and an SSE parser that turns arbitrary byte chunks into typed
OpenAI **Responses API** stream events.

**Done when:** fixture replay produces the identical event sequence for
**every** single-cut split of each fixture, byte-at-a-time feeding, and a
seeded sample of multi-cut splits, and the async specs pass.

No network or UI work. `provider.lua` (M2) is the first consumer.

---

## 1. Files

```
lua/sapho/async.lua
lua/sapho/sse.lua
tests/async_spec.lua
tests/sse_spec.lua
tests/fixtures/sse/
  text_only.sse           -- plain text answer
  reasoning_tool.sse      -- reasoning summary + encrypted reasoning + function_call
  multibyte.sse           -- text deltas with CJK, emoji, combining chars
  crlf.sse                -- text_only with CRLF line endings (derived)
  failed_midstream.sse    -- some deltas then response.failed (hand-edited)
scripts/capture_fixture.sh
```

---

## 2. `async.lua`

The provider change doesn't affect this module.

### API

```lua
async.run(fn, on_done?)     -- start fn in a new coroutine; returns task
async.await(fn, ...)        -- call fn(..., cb); yield until cb; return cb's args
async.wrap(fn, argc)        -- callback-style fn -> function usable inside run()
async.schedule()            -- await vim.schedule; leaves fast-event context
async.sleep(ms)             -- await a uv timer
```

`task = { co, cancel = fun(), done = bool }`. `cancel()` sets a flag. The
next `await` resume raises `"sapho: cancelled"`, which `run` reports as
`on_done(nil, "cancelled")`, not as an error. This is the hook for M2's `<C-c>`.

### Semantics (each one is a test)

1. **Sync callback.** If `fn` calls `cb` before returning, `await` returns
   without yielding. We track `done` before yielding, so there's no
   resume-before-yield bug.
2. **Async callback.** `await` yields, and `cb` resumes.
3. **Fast-event safety.** If `cb` fires while `vim.in_fast_event()` is true,
   which is every `vim.system`/`uv` callback, resumption goes through
   `vim.schedule`. Code after `await` may always touch the buffer API.
4. **Double callback.** Later calls are ignored (with a warning when `vim.g.sapho_debug` is set).
5. **nil-safe varargs.** Arguments and results use `{ n = select("#", ...), ... }`
   packing, so `cb(nil, err)` returns both.
6. **Errors.** A task error gets a `debug.traceback(co, err)` and is delivered
   to `on_done(nil, err)`, or `vim.notify(ERROR)` if there's no `on_done`.
   It never escapes into a libuv callback.
7. **await outside a coroutine** raises a clear error.
8. **Nested run** starts an independent task and doesn't join implicitly.

No promises or `all()` yet. `async.all` arrives with parallel tool execution in M4.

---

## 3. `sse.lua`

### Layer 1: line-level SSE parser (provider-neutral)

```lua
local p = sse.parser(on_frame)   -- on_frame({ event = string|nil, data = string })
p:feed(chunk)                    -- any bytes, any size, including ""
p:finish()                       -- flush a trailing frame lacking a blank line
p:buffered()                     -- carry bytes (diagnostics/tests)
```

- Carry buffer holds bytes after the last `\n`. We split on `\n` only, and
  that ASCII byte never occurs inside a UTF-8 multibyte sequence. So
  mid-codepoint splits are safe by construction.
- Strip one trailing `\r` per line (CRLF). A `\r\n` pair split across chunks
  works because `\r` stays in the carry until `\n` arrives.
- Lone-`\r` line endings are not supported (documented in the code).
- `field:value`, with one leading space after the colon stripped. `event` sets
  the name, and `data` lines are joined with `\n`. `:` lines are comments.
  Unknown fields (`id`, `retry`) are ignored.
- Blank line dispatches the frame if it has data. The event name is reset after each dispatch.
- No per-byte work: one concat per `feed`, and a `string.find` loop with a start index.

### Layer 2: typed Responses API events

```lua
local d = sse.decoder(on_event)  -- on_event(ev)
d:feed(chunk); d:finish()
```

For each frame:

- `data == "[DONE]"` → `on_event({ type = "done" })`. The Responses stream
  normally ends at `response.completed` without this sentinel, but it's
  cheap to tolerate.
- `vim.json.decode(data, { luanil = { object = true, array = true } })`, so
  JSON `null` becomes Lua `nil` in exactly one place.
- Decode failure → `{ type = "parse_error", raw = data, err = msg }`. It's
  emitted rather than raised, so the provider can abort cleanly.
- Type = JSON `type`. If the SSE `event:` name is present and differs from it →
  `parse_error`.
- Events pass through as decoded tables. **No accumulation in M1**, since
  building output items is M2's job. But the decoder validates the
  required fields of the types M2 depends on:

| type | required fields | M2 use |
|---|---|---|
| `response.created` | `response.id` | turn start |
| `response.output_item.added` | `output_index`, `item.type` | open item (message / reasoning / function_call) |
| `response.output_text.delta` | `output_index`, `delta` | render text |
| `response.reasoning_summary_text.delta` | `output_index`, `delta` | render folded "thinking" |
| `response.function_call_arguments.delta` | `output_index`, `delta` | accumulate args |
| `response.output_item.done` | `output_index`, `item.type` | **authoritative** final item (full args, `encrypted_content`) |
| `response.completed` | `response.status`, `response.usage` | end turn, usage |
| `response.incomplete` | `response.incomplete_details` | truncated output: never run its tool calls |
| `response.failed` | `response.error` | surface, abort |
| `error` | `message` | surface, abort |

Every other type (`response.in_progress`, `*.done` text events,
`content_part.*`, `reasoning_summary_part.*`, future ones) is passed through
unchanged and never dropped. Validation failure → `parse_error` with the
missing field named.

`sequence_number` is left in place, and tests assert it's strictly
increasing within each fixture. That doubles as a check that nothing was
dropped or duplicated.

> The exact field names above follow the public Responses API streaming
> reference. The Codex backend is expected to emit the same shapes. The
> captured fixtures are the source of truth: if they disagree, update this
> table and the validator to match the fixtures.

---

## 4. Fixtures

### Capture: `scripts/capture_fixture.sh`

A real stream is the only way to get true reasoning summaries,
`encrypted_content`, and function-call argument deltas. The script:

- Requires a fresh Codex login (`codex login`), and aborts with that hint if
  `auth.json` is missing or expired.
- Reads the token and account id with `jq` and passes the auth headers
  to curl on **stdin** via `curl -K -`, never argv (`/proc` is world-readable).
  The request body goes in a `mktemp` file (mode 0600) via
  `--data-binary @file`, removed on exit via `trap`.
- Endpoint, required headers, and body fields (`store: false`, `stream:
  true`, `instructions`, `include: ["reasoning.encrypted_content"]`, tool
  shape) are taken from the **`openai/codex` open-source repo**. Read the
  request builder there before writing the script, and record the commit
  hash in a comment. Don't guess them.
- One request per fixture, at `effort = "low"` to keep usage small. It counts
  against the ChatGPT plan's Codex usage, not dollars.
  - `text_only`: "Reply with exactly: hello world"
  - `reasoning_tool`: one dummy function tool `get_weather(city: string)`, a
    prompt that requires calling it, `reasoning.summary = "auto"`, and
    effort `medium` so a summary is actually produced
  - `multibyte`: "Reply with exactly: 日本語 🎉 é — ok" (with the é typed as e + a combining accent)
- Writes response bytes only (`-o`, no `-i`/`-v`), so fixtures contain no
  headers or tokens.

Derived fixtures:

- `crlf.sse`: `sed 's/$/\r/' text_only.sse`
- `failed_midstream.sse`: `text_only.sse` truncated after the second
  `output_text.delta`, with a hand-written `response.failed` frame appended.
  The backend can't be made to fail on demand.

**Pre-commit check:** `grep -E 'eyJ|Bearer|account' tests/fixtures/sse/*`
must return nothing. `encrypted_content` is opaque, model-generated
ciphertext rather than a credential, so it's fine to commit, but check that
the grep doesn't match it.

---

## 5. Tests

### `tests/async_spec.lua`

- One `it` per semantic in §2 (1–8).
- `wrap` round-trip with a real `vim.system({"echo","hi"})`. Assert
  `vim.in_fast_event()` is false after the await.
- `cancel()` mid-`sleep` → `on_done(nil, "cancelled")`, and code after the await never runs.
- Wait for completion via `vim.wait(1000, function() return task.done end)`.

### `tests/sse_spec.lua`

**Oracle:** feed each fixture whole and record the events. Every split
variant must `assert.same` that list.

1. **Every single cut:** `i = 0..#bytes`, feed `sub(1,i)` then `sub(i+1)`.
2. **Byte-at-a-time.**
3. **Seeded multi-cut:** `math.randomseed(42)`, 200 iterations, 2–20 cuts.
4. **Named adversarial cuts** (explicit, so failures read clearly):
   - inside a UTF-8 multibyte sequence (lead bytes ≥ 0xC0 in `multibyte.sse`)
   - inside the `data:` prefix
   - between `\r` and `\n` in `crlf.sse`
   - inside the JSON string of a `function_call_arguments.delta`
   - exactly on the blank line between frames
5. **Oracle content checks**, so the oracle itself is known to be right:
   - `text_only`: concatenated `output_text.delta` == "hello world"; last
     event `response.completed` with `status == "completed"`
   - `reasoning_tool`: ≥ 1 `reasoning_summary_text.delta`. A `reasoning`
     `output_item.done` has non-empty `encrypted_content`. Concatenated
     `function_call_arguments.delta` == the `function_call` item's
     `arguments` in its `output_item.done`, and it decodes to `{ city = <string> }`.
   - `multibyte`: reconstructed text contains the exact multibyte string
   - `failed_midstream`: last event is `response.failed`
   - all: `sequence_number` strictly increasing
6. **Parser unit cases** (inline strings): comments, multi-line `data`,
   `event` with no data, no trailing blank line + `finish()`, `feed("")`,
   unknown fields.
7. **Decoder cases:** invalid JSON → `parse_error`. `null` → `nil`. Event
   name/type mismatch → `parse_error`. Missing required field →
   `parse_error` naming it. Unknown type → passed through. `[DONE]` → `done`.

---

## 6. Order of work

1. `async.lua` + specs.
2. `sse.lua` Layer 1 + parser unit cases (inline strings, no fixtures needed).
3. `codex login`, then read the `openai/codex` request builder, then write
   and run `capture_fixture.sh`.
4. Layer 2 + fixture/split specs. Reconcile the §3 table with the captured shapes.
5. `make test` green → M1 done.

## 7. Carried into M2

These points came out of the plan review and the provider switch. They're
recorded here but not built in M1:

- **Echo reasoning:** `store: false` means no server-side state. Every
  request resends the full input, including prior `reasoning` items with
  `encrypted_content` (requested via `include`), and `function_call` /
  `function_call_output` items. This replaces the Anthropic "echo thinking
  blocks with signature" rule.
- **Parallel tool results:** each result is its own `function_call_output`
  input item keyed by `call_id`. The Anthropic rule "single user message"
  doesn't apply, but all results for a turn must still be sent in the same
  request, and every `call_id` must be answered.
- **Cancellation** leaves unanswered `call_id`s. The session must add
  synthetic error outputs for them before the next request.
- **Truncation:** `response.incomplete` means no tool call from that
  response runs.
- **Caching:** automatic prefix caching. Keep `instructions` and `tools`
  byte-stable (the ordered registry from the `pairs()` trap still applies),
  send a stable `prompt_cache_key` per session if the backend accepts it, and
  verify via `usage.input_tokens_details.cached_tokens`. This replaces
  `cache_read_input_tokens` in PLAN.md's M7 criterion.
- **Errors:** `--fail-with-body`. A 401 re-reads `auth.json` once (codex may
  have refreshed it), then tells you to re-auth. 429 gets backoff, surfacing
  any usage-limit message from the body verbatim.
- **Transport:** credentials on stdin via `-K -`, body via `--data-binary @tempfile`.
- **Tools:** Responses function-tool shape (`{ type = "function", name,
  description, parameters, strict }`). The `vim.empty_dict()` trap still
  applies to empty `properties`. Validate the decoded `arguments` before
  dispatch.
