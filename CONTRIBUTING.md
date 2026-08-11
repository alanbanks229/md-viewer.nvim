# Contributing

Thanks for helping improve `md-viewer.nvim`.

This project is in the early stages so please feel free to suggest improvements and proposals you have to improve this plugin!

Regarding bugs you might notice (and there will be some), include a focused test and please be specific in how to repro. Also please be aware of known issues for your terminal.

## Pull requests

1. Create a topic branch from `main`.
2. Install dependencies ([docs/development.md](docs/development.md)), then keep
   all three suites green:

   ```sh
   stylua --check lua/ plugin/ tests/lua/
   NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
   npm test --prefix renderer
   ```

   Nothing under `scripts/` runs in CI — those are the harnesses that need a real
   browser or a real terminal window, and they are how a terminal gets qualified.
3. Keep generated dependencies, browser binaries, logs, screenshots, and local
   machine configuration out of commits.
4. For graphical changes, name the OS, terminal (and version), Neovim, Node.js,
   and browser versions you tested on. See the manual verification checklist in
   [docs/development.md](docs/development.md) for what to check, and
   [docs/terminal-support.md](docs/terminal-support.md) for per-terminal status.
5. Provide a suggested CHANGELOG.md message.

By contributing, you agree that your contribution is licensed under the MIT
License included in this repository.
