# Contributing

Thanks for helping improve `md-viewer.nvim`. The project is young, so proposals
and suggestions are as welcome as patches.

For bugs, include a focused test and exact reproduction steps. Check
[docs/terminal-support.md](docs/terminal-support.md) first — several known
issues are upstream terminal defects rather than md-viewer's.

## Pull requests

1. Create a topic branch from `main`.
2. Install dependencies ([docs/development.md](docs/development.md)), then keep
   all three suites green. `make test` runs the two test suites; `stylua` is not
   a `make` target and CI checks it separately:

   ```sh
   stylua --check lua/ plugin/ tests/lua/
   make test
   ```

   Nothing under `scripts/` runs in CI — those are the harnesses that need a
   real browser or a real terminal window, and they are how a terminal gets
   qualified.
3. Keep generated dependencies, browser binaries, logs, screenshots, and local
   machine configuration out of commits.
4. For graphical changes, name the OS, terminal (and version), Neovim, Node.js,
   and browser versions you tested on. See the manual verification checklist in
   [docs/development.md](docs/development.md) for what to check, and
   [docs/terminal-support.md](docs/terminal-support.md) for per-terminal status.
5. Provide a suggested CHANGELOG.md entry.

By contributing, you agree that your contribution is licensed under the MIT
License included in this repository.
