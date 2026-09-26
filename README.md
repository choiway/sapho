# Sapho

Read code beside your editor: a reading-first Neovim plugin for asking questions about the current source buffer with a Codex CLI ChatGPT login. Sapho is an independent project; it uses an unofficial ChatGPT Codex backend endpoint, which may change without notice. It does not support API-key mode or refresh tokens itself.

## Requirements

- Neovim 0.10+ and `curl` 7.76+ (for `--fail-with-body`)
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for the `:SaphoLocations` picker only
- A ChatGPT-mode Codex CLI login: run `codex login` before submitting a request. If the token expires, refresh it with Codex; Sapho only reads `$CODEX_HOME/auth.json` (or `~/.codex/auth.json`).

Add this repository using your plugin manager, then optionally configure a mapping:

```lua
require('sapho').setup({
  keymap = '<leader>sa', -- optional; normal and visual modes
})
```

There is no default keymap. Run `:checkhealth sapho` to check local dependencies and login status. Sapho does not persist conversations to disk.

## Usage

From a source buffer, `:Sapho` opens the floating chat directly, without Telescope. Use the optional mapping from Normal mode for the same behavior. From Visual mode, `:Sapho` or the mapping opens the chat with the selected text in an editable prompt. Neovim initially inserts the `'<,'>` range; Sapho remembers the visual invocation even if you remove it. Cancelling the command line discards the selection. A plain `:Sapho` after leaving Visual mode does not reuse old marks.

Sapho opens a floating Markdown transcript and multiline prompt over the code (by default two-thirds of the available editor height; set `ui.height` to a number of rows to override, or `0` for automatic sizing). It uses Neovim's built-in Markdown syntax for common fenced languages (`lua`, `python`, `js`, `tsx`, and more), without requiring Treesitter. An isolated `sapho-markdown` filetype prevents external Markdown highlighters from overriding code colors. Markdown markup remains visible. Insert `<CR>` adds a newline; `<C-s>` sends; Normal `<CR>` sends; `<C-c>` cancels the active request. Press Normal `q` in either Sapho window or run `:SaphoToggle` to hide the chat; from the source buffer, `:SaphoToggle` reopens it. Both floating windows show a working/reading/responding indicator while a request is active, plus a completion or cancellation state; it updates when you reopen the chat. Routine bracketed activity lines in the transcript use a subdued `Comment` color; failures, scope notices and location hints remain prominent. Hiding preserves the draft, transcript, and in-flight request, so you can keep reading code while the answer streams. `:Sapho` also reopens it directly. `:SaphoNew` starts over, `:SaphoLocations` lets you jump to an LSP location from the source window, and `:SaphoCancel` / `:SaphoPause` control the active request. `require('sapho').ask()` opens the prompt directly without a picker. Selecting text never submits it automatically; existing unsent drafts are preserved.

The model can request bounded read-only Neovim tools for the current unsaved buffer, diagnostics, definitions, references, document symbols, editor context, and cwd-confined repository files. Tools cannot apply edits, execute commands, or navigate. Wiping the source buffer retires its in-memory conversation. A selected excerpt is pinned to the question; later tool reads use the **current** buffer text.

**Privacy:** Prompts, selected code, conversation history, and tool results are sent to the Codex backend when you submit. Repository reads can include unsaved changes. Keep secrets out of prompts and source buffers you do not want sent to the provider. Sapho sets `store=false` on requests, but cannot control the provider's retention policy. It does not log in or store credentials; it reads the Codex CLI auth file and sends authorization headers via curl's stdin, not command-line arguments.

## Development

Run `make test` for offline tests (requires [plenary.nvim](https://github.com/nvim-lua/plenary.nvim); the test setup uses an installed copy or clones one into the ignored `.tests/` directory). Tests do not require a login or make backend requests. Checked-in SSE fixtures are synthetic; `scripts/capture_fixture.sh` is for manual debugging and writes real responses only to ignored `.local-fixtures/`. **Never commit live captures.** See `specs/reading-ux.md` for historical design notes and [PUBLICATION.md](PUBLICATION.md) for safe GitHub publishing from the clean `public` branch (not the local historical `master`).

Licensed under the [MIT License](LICENSE).
