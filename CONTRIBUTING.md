# Contributing

Thanks for helping improve `md-viewer.nvim`. The project is young, so proposals
and suggestions are as welcome as patches.

This project has been developed with significant AI assistance. Changes are
reviewed, tested, and maintained like any other contribution.

For bugs, please use the issue template and include exact reproduction steps —
a focused test is even better. Check
[docs/terminal-support.md](docs/terminal-support.md) first: several known
issues are upstream terminal defects rather than md-viewer's.

## Getting set up

The renderer is a Node.js program under `renderer/`; its dependencies are not
committed, only a lockfile pinning their exact versions. Install them with:

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
```

The environment variable and `--ignore-scripts` are security measures, not
conveniences: no browser download, no install-time scripts. `build.lua` at the
repository root runs this same command as the plugin-manager install hook, so
the two must stay in step.

You also need Neovim 0.12+, Node.js 22.12+, and an existing Chrome, Chromium,
or Edge install (browser-dependent tests skip where none is present).

## Running the tests

```sh
make test            # both suites
make test-lua        # the Lua suite alone
make test-node       # the renderer's Node suite alone
node --test tests/node/hitbox.test.js              # one Node case
stylua --check build.lua lua/ plugin/ tests/lua/   # formatting — CI checks it; not a make target
```

There is no single-case runner for the Lua suite — `tests/lua/run.lua` runs
every case, with no filter.

CI runs formatting on Ubuntu and the two suites on Ubuntu (Node 22.12.0 and
24) and macOS (Node 24), with Neovim pinned to v0.12.4 and stylua to v2.5.2 —
match those locally or expect spurious diffs.

### What the suites can't see

The headless tests prove the plumbing — protocol, staleness, sanitization,
geometry, selection semantics — but they cannot see a pixel. Whether the image
is composited where it should be, whether a highlight is visible, whether
anything flickers: that takes a real terminal. `scripts/` holds the harnesses
for exactly that gap ([scripts/README.md](scripts/README.md)); none of it runs
in CI. One of them needs no display and is worth running for any
selection or placement change:

```sh
nvim --headless -u NONE -i NONE -l scripts/overlay/live/drive.lua
```

For changes touching placement, interaction, or the overlay, work through
[scripts/manual-checklist.md](scripts/manual-checklist.md) on a real terminal
and say which one — name the OS, terminal (and version), Neovim, Node.js, and
browser you tested on. [docs/terminal-support.md](docs/terminal-support.md)
has per-terminal status.

## Conventions

- **Do not weaken a test to make a change pass.** Several tests pin arguments
  and orderings that were wrong before, and say so in their comments; if one
  of those fails, the change is what is wrong.
- **Do not delete code that appears to have no caller** without checking for a
  `KEEP_IN_MIND:` comment at the site. Some paths are dormant on the
  configurations currently validated rather than dead, and the comment says
  what would have to be true for them to run again. Removing one outright is a
  product decision — raise it first.
- **Changes that touch the security boundary are design changes.** What the
  defaults enforce is in [SECURITY.md](SECURITY.md); open an issue before a
  pull request that would cross it.

## Opening a pull request

1. Create a topic branch from `main`.
2. Keep `make test` and `stylua --check` green.
3. Keep generated dependencies, browser binaries, logs, screenshots, and local
   machine configuration out of commits.
4. Suggest a CHANGELOG.md entry for user-visible changes.

## Releasing (maintainers)

The project follows [Semantic Versioning](https://semver.org/); while the
major version is `0`, a breaking change is allowed in a MINOR bump.

1. Run both suites and `stylua --check` from a clean checkout.
2. Work through [scripts/manual-checklist.md](scripts/manual-checklist.md) on
   at least one `Supported` terminal.
3. Bump the version in `lua/md-viewer/init.lua` (`M.version`) and
   `renderer/package.json`, then regenerate the lockfile — never hand-edit it:

   ```sh
   npm install --package-lock-only --prefix renderer
   ```

4. Add the CHANGELOG section, dated the day the release is actually published.
   Keep it release notes: one bullet per user-visible change, at most one
   sentence of cause.
5. Confirm nothing generated is tracked, and that the README's install
   snippets pin the version being tagged.
6. Tag with an annotated tag and publish the release from the matching
   changelog section (it is extracted verbatim — draft first, read it, then
   publish):

   ```sh
   version=0.3.0
   tag="v$version"

   awk -v v="$version" '$0 ~ "^## \\[" v "\\]" {f=1;next} /^## \[/{f=0} f' \
     CHANGELOG.md > /tmp/notes.md
   test -s /tmp/notes.md   # empty means a malformed heading or a missing link ref

   git tag -a "$tag" -m "$tag: <summary>"
   git push origin "$tag"
   gh release create "$tag" --title "$tag" --notes-file /tmp/notes.md --draft
   gh release view "$tag" --web   # read it, then publish
   gh release edit "$tag" --draft=false
   ```

By contributing, you agree that your contribution is licensed under the MIT
License included in this repository.
