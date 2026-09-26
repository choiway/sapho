# GitHub publication precautions

The published `main` branch began at a clean root commit (`84abca2`), with synthetic SSE fixtures. It does **not** descend from the old local `master` branch. The old `master` history contains live backend responses, including encrypted reasoning and response metadata; replacing the fixtures in a later commit did not remove those objects.

**Never push the local `master` branch, old tags, `--all` or `--mirror` to a public remote.** Push only `main` (`git push origin main`). A fresh clone of the GitHub repository does not include the old local history. If older commits were already shared elsewhere, deleting a local branch cannot revoke downloaded copies.

Before future releases:

- Review new files and commits for secrets, real SSE captures and unwanted author information. Never commit `.local-fixtures/` or Codex `auth.json`.
- Run `make test` without a login; CI runs the same tests. Confirm the MIT copyright notice is correct.
- Consider GitHub private vulnerability reporting, secret scanning and branch protection.
