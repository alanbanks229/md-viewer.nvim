# Development

## Repository layout

- `lua/md-viewer/`: Neovim configuration, sessions, lifecycle, synchronization,
  placement, health checks, and renderer-process control
- `lua/md-viewer/backends/`: `vim.ui.img`, raw Kitty protocol, and text-cell
  display backends
- `plugin/md-viewer.lua`: runtime entry point and default highlights
- `renderer/src/`: persistent Node.js renderer, Markdown pipeline, browser
  lifecycle, protocol, source maps, and security policy
- `renderer/assets/`: bundled preview themes and syntax colors
- `tests/lua/`: headless Neovim tests
- `tests/node/`: renderer, protocol, browser, and security tests
- `tests/fixtures/`: Markdown documents the suites and the manual checklist use
- `scripts/overlay/`: harnesses that need a real browser or a real terminal
  window; see `scripts/README.md`
- `docs/`: architecture, security, troubleshooting, and release testing

## Bootstrap

Install only the locked JavaScript dependencies. The environment variable and
`--ignore-scripts` flag deliberately prevent Playwright or dependency lifecycle
scripts from downloading a browser or running install-time code.

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
```

This command may contact the configured npm registry. Runtime preview rendering
does not require npm network access.

## Automated tests

```sh
stylua --check lua/ plugin/ tests/lua/
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
```

The browser suites require an existing Chrome or Chromium installation. No test
downloads a Playwright-managed browser. Run `git diff --check` and scan the
repository for absolute paths, credentials, local profiles, logs, generated
PNGs, and `node_modules` before publishing.

## Interactive graphics testing

Headless tests cannot inspect terminal pixels, click accuracy, or flicker.
Run Neovim directly in a real terminal (iTerm2, Kitty, WezTerm, Ghostty, or
Warp — see [manual-testing.md](manual-testing.md) for what has and has not
actually been validated on each) with Kitty graphics enabled, without a
multiplexer, and work through that document's scenario matrix. Record all of
the following with a bug report:

- OS, terminal name and version, Neovim, Node.js, and Chrome/Chromium versions
- selected backend and `:MdViewerHealth` output (and `:MdViewerDebug` for
  anything involving selection, search, or placement)
- whether tmux, screen, Zellij, or another terminal multiplexer was present
  (none of these are supported — confirm the bug reproduces without one
  before filing it as a graphics bug)
- relevant statusline, winbar, split, and floating-window configuration
- minimal Markdown and configuration needed to reproduce the behavior

Three harnesses under `scripts/overlay/` cover what the headless suites cannot:
an end-to-end drag regression against a real browser, a pixel-asserting geometry
rig, and an overlay stress rig. See [../scripts/README.md](../scripts/README.md)
for what each proves and when to run it.

## Release checklist

1. Run the Lua and Node.js suites from a clean checkout.
2. Work through the checklist in [manual-testing.md](manual-testing.md) on at
   least one real terminal.
3. Confirm `renderer/package.json`, `renderer/package-lock.json`,
   `lua/md-viewer/init.lua`, and `CHANGELOG.md` agree on the release version.
4. Confirm no browser binary, `node_modules`, log, screenshot, or local profile
   is tracked.
5. Review dependency licenses and security advisories.
6. Tag the tested commit with an annotated `v<version>` tag.
7. Publish release notes from the matching changelog entry.

## Design constraints

Preserve these boundaries unless a proposal explicitly revisits them:

- renderer transport remains child-process stdin/stdout, with no listening port
- runtime browser networking remains blocked by default
- Playwright uses an existing browser and does not manage browser downloads
- raw image cleanup targets only plugin-owned image and placement IDs
- local image access remains canonicalized and confined to a document root
- the graphical preview remains a read-only raster surface; editing belongs to
  the source buffer
