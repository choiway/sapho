# M5a — Turn-level review (supersedes M5's default)

Default `edit_review = 'end'`: Sapho applies each valid edit directly to a loaded, named, modifiable, unsaved buffer inside the working directory. It never writes the buffer. Every edit must carry the `changedtick` obtained from `buffer_read` or `editor_context`; if the buffer changed since that read, the call returns a stale error, without applying. All M5 range, encoding, size, auth, cwd, undo and session checkpoint guards still apply. A response may contain only one `buffer_edit` call.

After the turn completes **or fails/cancels after applying edits**, show a single, close-only turn diff between each touched buffer's pre-turn snapshot and its current unsaved content. `n` cycles touched buffers and `q` closes the diff; `:SaphoDiff` reopens it, `:SaphoDiffNext` advances. Closing the diff does not discard or undo changes. If the user has changed the buffer since the last agent edit, label the diff accordingly. `:write` and undo remain the user's responsibility.

For questions about the repository when the current buffer is unnamed or unrelated, `repo_list` and `repo_read` provide bounded read-only access to source files inside the working directory. An open buffer's unsaved text takes precedence over disk. Private paths and out-of-directory targets remain unavailable.

Opt in to M5's per-edit pause with `require('sapho').setup({ edit_review = 'each' })`. Per-edit Accept/Reject/Revise/Cancel and pause/cancel controls are retained in that mode. No automatic disk writes, Git operations, shell commands or auto-accept of a pending review.
