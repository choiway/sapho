# Publishing Sapho on GitHub

The local `master` history contains live backend SSE responses in older commits (including encrypted reasoning and response metadata). Replacing the fixtures in a later commit does **not** remove those objects. **Never push `master`, `--all`, `--mirror`, or old tags to a public remote.**

The separate `public` branch is a fresh root commit containing only the reviewed, synthetic-fixture tree. It does not contain or descend from the local `master` commits. The old objects still exist locally; pushing *only* `public` does not send them to GitHub.

Before publishing:

1. Review the files and author information you intend to make public. Confirm the MIT copyright notice (2026 Wayne Choi) is correct. Run `make test` without logging into Codex. Never commit `.local-fixtures/`, `auth.json`, or real streams.
2. Verify `git rev-list --count public` is `1`, and `git ls-tree -r --name-only public` contains only intended files. Do not push any other branch or tag.
3. Create an **empty** GitHub repository (do not add a generated README or license). Add its URL as `origin` locally, then publish just this branch with `git push -u origin public:main`. Set `main` as the GitHub default branch. Consider enabling private vulnerability reporting, secret scanning and branch protection.

No GitHub remote is configured here; publication itself is an owner action. If any earlier history was already shared, removing it locally cannot revoke downloaded copies.
