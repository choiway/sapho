# M3 — Multi-turn chat UI

**Goal:** a five-turn conversation reads well in a read-only transcript and separate multiline input window, without scroll jumps. No tool execution or persistence yet. Offline tests only; manual live validation optional.

## Contract

- `:Sapho` opens/focuses a transcript (`sapho://chat`) and input (`sapho://input`) in the current tab. Transcript is nonmodifiable, input is editable. Normal `<CR>` or insert `<C-s>` submits the input; insert `<CR>` inserts a newline. Buffer-local `<C-c>` cancels. Closing either window cancels the active request, never recreates a closed window in a callback. Reopening preserves the in-memory session while its buffers exist; wiping the transcript starts a new session.
- `session.new():input(prompt)` returns a fresh array of previous successful user/output items plus the new user message. `:commit(prompt, result)` appends the user and authoritative `result.output` without rewriting encrypted reasoning. A function call has no executor in M3: immediately append a synthetic `function_call_output` error for each `call_id`, so the next request never has dangling calls. A failed/cancelled turn does **not** enter history. `:usage()` returns latest and cumulative token counts. No persistence.
- `provider.start(input, on_event, on_done, deps?)` accepts either the M2 string prompt or an ordered Responses input array. It keeps the same fixed instructions, `store=false`, `tools=[]`, and no tool dispatch. Retry sends the same frozen input. No credentials or ciphertext in the UI.
- Transcript headings for user, assistant, reasoning, and status. Only output-text and reasoning-summary deltas render (never encrypted content or raw arguments). Fold each reasoning block closed on completion. Append with end extmarks, batching deltas at ~40ms; flush before status/completion. Preserve viewport and cursor when reading older text; follow the tail only if already following. Show latest/cumulative token usage in transcript winbar. The input buffer remains editable throughout but duplicate submissions are ignored while busy.
- Cancellation and errors keep visible partial text marked incomplete; no partial output enters session. A successful response containing function calls shows “tool execution not available yet” and still records synthetic error outputs for the next turn.

## Tests / acceptance

- `session_spec.lua`: pure history copy/isolation, ordered output/encrypted reasoning intact, synthetic tool outputs, failed turn not committed, usage.
- `provider_spec.lua`: multi-turn input shape via fake spawn; retries preserve input; M2 string requests remain valid.
- `init_spec.lua`: two windows/open/focus, multiline prompt, batched text and reasoning, folds/no ciphertext, duplicate/empty guards, scroll position, cancellation/window close, history submitted after successful turns only, winbar usage.
- `make test` without Codex login. Manual: five turns, inspect folds and scroll while a long response streams; close/cancel and reopen. Do not capture live streams. Verified five real short turns through the Neovim UI headlessly, then cancellation, reopening, and usage display; offline UI tests exercise closed folds, reading older text while streaming, and window-close cancellation. A full interactive visual review requires a human-operated TUI.

**Out of scope:** tool execution, disk persistence, approval UI, token-cost estimates, extmark-anchored edits to old blocks, and cross-tab synchronized views.
