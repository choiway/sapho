# Sapho

Explore the code you're reading without leaving Neovim: Sapho lets you ask questions about your current buffer using your Codex CLI ChatGPT login. Sapho is an independent project; it uses an unofficial ChatGPT Codex backend endpoint, which may change without notice. It does not support API-key mode or refresh tokens itself.

## Installation

Requires Neovim 0.10+, `curl` 7.76+ and a ChatGPT-mode [Codex CLI](https://github.com/openai/codex) login. [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) is optional, used only by `:SaphoLocations`.

Install with **lazy.nvim**:

```lua
{
  'choiway/sapho',
  config = function()
    require('sapho').setup({ keymap = '<leader>sa' }) -- optional mapping in Normal and Visual modes
  end,
}
```

Or install without a plugin manager:

```sh
mkdir -p ~/.local/share/nvim/site/pack/plugins/start
git clone https://github.com/choiway/sapho.git ~/.local/share/nvim/site/pack/plugins/start/sapho
```

Then run `codex login` in your shell. In Neovim, run `:checkhealth sapho` and open a source buffer with `:Sapho`. There is **no default keymap**; manual installs can add `require('sapho').setup({ keymap = '<leader>sa' })` to `init.lua` if desired. Sapho reads `$CODEX_HOME/auth.json` (or `~/.codex/auth.json`) and does not persist conversations to disk. If the token expires, refresh it with Codex.

## Usage

### Open a chat

1. Open a source buffer and run `:Sapho` (or use your optional mapping). No Telescope picker is required.
2. Edit the question in the floating prompt; nothing is sent until you submit it.
3. Hide the chat with `q` to read code. From the same source buffer, `:Sapho` focuses it again; `:SaphoToggle` reopens it if hidden. The draft, transcript and in-flight request remain in memory.

From Visual mode, `:Sapho` or the mapping adds the selected text to an editable question **without submitting**. It preserves existing unsent drafts. A selection is pinned to that question; later tool reads see the *current* buffer. Neovim's `'<,'>` range is handled even if you delete it from the command line. Cancelling the command line discards the selection, and a later Normal-mode `:Sapho` will not reuse old marks.

### Keyboard and commands

The input box's border is muted (`Comment`) in Normal mode and highlighted (`DiagnosticOk`) in Insert mode; Replace mode uses `DiagnosticWarn`. The transcript border stays muted. Press `i` to edit and `<Esc>` to return to Normal mode.

| Where | Key | Action |
| --- | --- | --- |
| Input, Insert mode | `<CR>` / `<C-s>` | Newline / send |
| Input, Normal mode | `<CR>` | Send |
| Either Sapho window, Normal mode | `q` | Hide the chat |
| Either Sapho window, Normal or Insert mode | `<C-n>` | Start a new conversation (clear prior model context) |
| Either Sapho window | `<C-c>` | Cancel the active request |
| Input, Normal mode | `<C-w>w` | Move to the transcript |
| Transcript, Normal mode | `<C-w>W` | Return to the input |

`:SaphoNew` also starts a new conversation. It cancels any active request, clears the input and transcript buffers, and starts a fresh session, so previous turns are not sent to the model. `:SaphoCancel` and `:SaphoPause` control the active request. `:SaphoLocations` opens a Telescope picker for LSP locations; choosing one jumps from the source window. You can also call `require('sapho').ask()` to open the prompt directly.

### Transcript and context

The floating Markdown transcript and input together default to 80% of the screen height, clamped to available space (`ui.height = 0`); set `ui.height` to a row count to override it. Neovim's built-in syntax highlights common fenced code languages without Treesitter. Markdown markup stays visible. Activity indicators appear in the transcript header, with a highlighted animated spinner while a request is working, responding or reading (`SaphoSpinner` links to `DiagnosticInfo` by default); the input box has no header. Routine bracketed messages are dimmed, while failures, scope notices and location hints remain prominent.

Sapho can request bounded **read-only** tools for unsaved buffer text, diagnostics, definitions, references, document symbols, editor context and cwd-confined repository files. Tools cannot edit, run commands or navigate. Wiping the source buffer retires its in-memory conversation.

**Privacy:** Submitting sends the prompt, selected code, conversation history and tool results to the Codex backend. Repository reads may include unsaved changes; do not include secrets you want to keep private. Sapho sets `store=false`, but cannot control provider retention. It reads Codex CLI credentials without storing them and passes authorization headers to curl via stdin, not command-line arguments.

## Development

Run `make test` for offline tests (requires [plenary.nvim](https://github.com/nvim-lua/plenary.nvim); the test setup uses an installed copy or clones one into the ignored `.tests/` directory). Tests do not require a login or make backend requests. Checked-in SSE fixtures are synthetic; `scripts/capture_fixture.sh` is for manual debugging and writes real responses only to ignored `.local-fixtures/`. **Never commit live captures.** See `specs/reading-ux.md` for historical design notes and [PUBLICATION.md](PUBLICATION.md) for GitHub publication precautions.

Licensed under the [MIT License](LICENSE).
