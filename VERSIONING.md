# Versioning and Releases

A plain-language guide to how `md-viewer.nvim` is versioned, when to cut a
new tag, and the exact commands to do it. If `docs/development.md`'s
"Release checklist" is the terse checklist, this is the explanation and the
worked examples behind it.

---

## The short version

- Version numbers look like `vMAJOR.MINOR.PATCH`, e.g. `v0.2.0`.
- We're pre-1.0 (`0.x.x`), which by convention means "still stabilizing —
  anything might still change." Don't feel obligated to reach `1.0.0` on any
  particular schedule; get there when the project is actually done changing
  shape, not before.
- Day to day: bump **PATCH** for a fix, **MINOR** for a new feature or a
  behavior change, and don't worry about **MAJOR** at all until `1.0.0`.
- A release is: bump the version in the files that record it, update
  `CHANGELOG.md`, commit, tag, push, publish a GitHub release. All the exact
  commands are in [Step-by-step release workflow](#step-by-step-release-workflow).

---

## How version numbers work (plain language)

This project follows [Semantic Versioning](https://semver.org/) — "SemVer" —
already stated at the top of `CHANGELOG.md`. A version number has three
parts: `MAJOR.MINOR.PATCH`.

| Part | Bump it when... | Example |
|---|---|---|
| **PATCH** (third number) | You fixed a bug and nothing about how people use the plugin changed. | `v0.2.0` → `v0.2.1` |
| **MINOR** (second number) | You added something new (a feature, a config option, a supported terminal) without breaking existing configs. | `v0.2.1` → `v0.3.0` |
| **MAJOR** (first number) | You made a breaking change — something that requires people to edit their config or expect different behavior. | `v0.9.0` → `v1.0.0` |

Whenever you bump a number, every number **to its right resets to zero**.
`v0.2.7` with a new feature becomes `v0.3.0`, not `v0.2.8` or `v0.3.7`.

### The special pre-1.0 rule

Semantic Versioning has one important carve-out: **while the major version is
`0`, all bets are off** — a `0.x` release is allowed to make breaking changes
in a MINOR bump, because the whole `0.x` line is understood to be
pre-stability. That's exactly this project's situation right now: Part 1
changed how `image.backend = "kitty_raw"` fails on unknown terminals
(a real behavior change), and it went out as part of the `v0.2.0` MINOR
bump, not a MAJOR one — that's correct, not a shortcut.

Once this project ships `v1.0.0`, that carve-out goes away, and a breaking
change afterward genuinely requires a MAJOR bump (`v1.4.0` → `v2.0.0`). This
is one good reason not to rush to `1.0.0`: it's a promise that the config
surface and behavior have settled down.

### Pre-release suffixes: `-beta`, `-rc.1`, etc.

A version can carry a suffix after a hyphen — `v0.2.0-beta`,
`v0.3.0-rc.1`. These sort **before** the plain version
(`v0.2.0-beta` < `v0.2.0`) and signal "this exists so people can try it, but
it isn't the real tag yet."

Use a pre-release suffix when:

- You want feedback on a specific commit before committing to a version
  number publicly (`v0.3.0-rc.1` — "release candidate 1 for what will become
  v0.3.0").
- The whole project is early enough that every release is provisional — this
  is why `v0.1.0-beta` (the current published tag) has the suffix at all.

You do **not** need a suffix just because you're a little unsure — `0.x`
already communicates "this can still change." Reserve `-beta`/`-rc.N` for
"I specifically want this exact commit tested before it becomes the real
tag."

---

## Decision guide: which number do I bump?

Concrete examples from this project's own history and roadmap:

| Change | Bump | Why |
|---|---|---|
| Fixed `:MdViewerHealth` crashing on multi-line values (`b2ceaf9`) | PATCH | Pure bugfix, no behavior anyone relied on changed. |
| Fixed the command-line making the preview disappear (`8ad0623`) | PATCH | Bugfix — the old behavior was never the intended design. |
| Raised the default preview font size, added a text-fallback notice (`0be91a6`) | MINOR | New, visible behavior (a UI notice that didn't exist before), even though nothing breaks. |
| De-iTerm2'd the Kitty backend; added profile-driven z-index/geometry (Part 2) | MINOR | New capability (works on more terminals) plus one real, documented behavior change (forcing `kitty_raw` can now fail honestly instead of always "succeeding"). Allowed in a MINOR bump only because we're pre-`1.0`. |
| Added click-to-source, text selection, search (Parts 3–6, future) | MINOR each | New features, additive. |
| Renamed `image.raw_zindex` to something else, or changed its default meaning in a way existing configs would silently misbehave under | MINOR now / MAJOR after 1.0 | This is exactly the kind of change the pre-1.0 carve-out exists for. |
| Removed a Neovim version we used to support | MINOR now / MAJOR after 1.0 | Same reasoning. |

When genuinely unsure between PATCH and MINOR: **if a user would notice
something different (new option, new message, new supported terminal),
call it MINOR.** If they'd only notice that something broken now works,
call it PATCH.

---

## This project's actual roadmap

The phased implementation plan in `prompts/README.md` already commits to
specific version checkpoints — this isn't hypothetical, it's the plan:

| Tag | What it means | Status |
|---|---|---|
| `v0.1.0-beta` | First public release: iTerm2-only raw Kitty preview. | Shipped. |
| `v0.2.0` | Parts 1–2 done: works on any Kitty-graphics terminal without hand-tuned config, honest capability reporting. No interaction changes. | Ready to tag — see the worked example below. |
| `v0.3.0` | Part 7 done: click-to-source, selection, search, hardened and documented, real compatibility matrix. | Not started. |
| `v1.0.0` | Whenever you decide the config surface and behavior have stopped needing to change, and you're confident enough to promise that in writing. | No target date — this is a judgment call, not a checklist item. |

Nothing forces `v1.0.0` to happen right after `v0.3.0`, or ever on a
schedule. Plenty of stable, widely-used Neovim plugins never leave `0.x`.
Move to `1.0.0` when *you* want to make the "this won't casually break your
config anymore" promise — not before.

---

## Step-by-step release workflow

This assumes the standard flow already in use here: work happens on a topic
branch (e.g. `feat/cross-platform-markdown-preview`), gets merged to `main`,
and `main` is what gets tagged.

### 1. Pre-flight (every release, no exceptions)

Run the checks from `docs/development.md`:

```sh
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
stylua --check lua/ plugin/ tests/lua/
```

For anything touching graphics, also work through
`docs/manual-testing.md` on a real terminal — headless tests can't see
pixels.

### 2. Decide the version number

Use the [decision guide](#decision-guide-which-number-do-i-bump) above.

### 3. Update the three places the version string lives

```sh
# lua/md-viewer/init.lua      -> M.version = "0.2.0"
# renderer/package.json       -> "version": "0.2.0"
# renderer/package-lock.json  -> regenerate, don't hand-edit
```

Regenerate the lockfile after editing `package.json` so they stay
consistent:

```sh
# Run from the root directory
npm install --package-lock-only --prefix renderer
```

### 4. Update `CHANGELOG.md`

Add a new section at the top, above any previous entries, following the
existing style:

```markdown
## [0.2.0] - 2026-08-06

### Added
- Portable Kitty backend: works on any terminal advertising Kitty graphics,
  not just iTerm2.
- Cell-metric calibration reporting (`env` / `estimated` tiers).

### Fixed
- The command line no longer hides the preview while it's open.
```

And add the link reference at the bottom, next to the existing one:

```markdown
[0.2.0]: https://github.com/alanbanks229/md-viewer.nvim/releases/tag/v0.2.0
```

### 5. Commit the version bump

```sh
git add lua/md-viewer/init.lua renderer/package.json renderer/package-lock.json CHANGELOG.md
git commit -m "chore: release v0.2.0"
```

### 6. Merge to `main` (if releasing from a topic branch)

```sh
git checkout main
git pull origin main
git merge --no-ff feat/cross-platform-markdown-preview
```

(Or, more commonly, open a PR and merge it through GitHub instead of merging
locally — either is fine, `main` just needs to end up with the commit.)

### 7. Tag it

Use an **annotated** tag (`-a`), not a lightweight one — it carries a
message and a timestamp, which `git describe` and GitHub both use.

```sh
git tag -a v0.2.0 -m "v0.2.0: portable Kitty backend, honest capability reporting"
```

### 8. Push the branch and the tag

```sh
git push origin main
git push origin v0.2.0
```

### 9. Publish the GitHub release

```sh
gh release create v0.2.0 \
  --title "v0.2.0" \
  --notes-file <(sed -n '/## \[0.2.0\]/,/## \[/p' CHANGELOG.md | sed '$d')
```

- The Sed Command in a nutshell:
  - `sed -n '/## \[0.2.0\]/,/## \[/p'` prints every line from the `## [0.2.0]` header
  down through the next `## [ version ]` (inclusive on both ends).
  - `sed '$d'` deletes that last line — aka the next section's header `## [0.1.0-beta]...` so the release notes and the changelog never drift apart. If that one-liner feels fragile, just copy the section into `--notes` by hand.

### 10. If it was a pre-release tag

Add `--prerelease` to the `gh release create` command, and skip step 6
(pre-releases usually don't need to land on `main` first) if you're
releasing an in-progress branch for testing:

```sh
gh release create v0.3.0-rc.1 --title "v0.3.0-rc.1" --prerelease --notes "Release candidate for v0.3.0, testing needed on Kitty/Ghostty/Warp."
```

---

## Sample workflows

### A. Cutting the next real release (the situation you're in right now)

You're on `feat/cross-platform-markdown-preview`, Parts 1–2 plus two
follow-up fixes are done and tested on real terminals. This is a MINOR
bump (new capability, one documented behavior change, allowed pre-1.0):

```sh
git checkout feat/cross-platform-markdown-preview
# ... steps 3-5 above: bump versions, update CHANGELOG, commit ...
git push origin feat/cross-platform-markdown-preview
gh pr create --title "Cross-platform preview: v0.2.0" --body "Parts 1-2 of the cross-platform plan, plus two real-terminal fixes. See CHANGELOG.md."
# after merging the PR on GitHub:
git checkout main && git pull origin main
git tag -a v0.2.0 -m "v0.2.0: portable Kitty backend, honest capability reporting, larger default font, command-line visibility fix"
git push origin v0.2.0
gh release create v0.2.0 --title "v0.2.0" --notes-file <(sed -n '/## \[0.2.0\]/,/## \[/p' CHANGELOG.md | sed '$d')
```

> gh release create does something different: it wraps that existing tag in a GitHub Release — a separate, GitHub-specific object layered on top of the tag.
> Concretely, it:

> - Publishes a page on the repo's "Releases" tab with your formatted notes (rendered from the --notes-file content), rather than requiring people to dig through CHANGELOG.md or git log themselves.
> - Generates the source .zip/.tar.gz download links people expect on that page.
> - Sends a notification to anyone "Watching" the repo — a plain tag push does not trigger that notification, only a Release does.
> - Makes the .../releases/tag/v0.2.0 URL — the exact link format your CHANGELOG.md already uses in its [0.2.0]: https://... reference — actually show something meaningful. Without running this command, that link points at a tag with no Release attached.

> So it's purely about human discoverability/communication, not distribution mechanics. If you don't care about the Releases tab or notifying watchers, you can skip it — the plugin still works identically for everyone via the tag alone. Given you already wrote real changelog notes for this, I'd still run it (low cost, and it makes those changelog links actually resolve to something), but it's optional, not required.

### B. A quick patch release later

Someone reports a crash in `v0.2.0`. You fix it directly on `main` (or a
tiny topic branch merged the same way):

```sh
# fix the bug, add a regression test, commit it normally
# then bump lua/md-viewer/init.lua and renderer/package.json to 0.2.1
# add a "## [0.2.1]" CHANGELOG section under "### Fixed"
git add -A
git commit -m "chore: release v0.2.1"
git push origin main
git tag -a v0.2.1 -m "v0.2.1: fix crash in :MdViewerHealth on <describe>"
git push origin v0.2.1
gh release create v0.2.1 --title "v0.2.1" --notes-file <(sed -n '/## \[0.2.1\]/,/## \[/p' CHANGELOG.md | sed '$d')
```

### C. Testing before committing to a real tag

You've finished Part 7 but want Kitty/Ghostty/Warp users to try it before
you call it `v0.3.0`:

```sh
git tag -a v0.3.0-rc.1 -m "Release candidate 1 for v0.3.0"
git push origin v0.3.0-rc.1
gh release create v0.3.0-rc.1 --title "v0.3.0-rc.1" --prerelease \
  --notes "Testing selection/search/click-to-source before v0.3.0. Please report results per terminal in docs/manual-testing.md's checklist."
```

If it needs another round, `v0.3.0-rc.2`. Once it's solid, tag the same
commit as the real `v0.3.0` (repeat the section A workflow) and optionally
delete the `-rc` pre-releases from GitHub — they've served their purpose.

### D. Eventually reaching 1.0.0

There's no separate mechanical workflow for this — it's workflow A, with
`1.0.0` as the version number, once you've decided (not "once a checklist
says so") that the config surface, supported terminals, and behavior are
stable enough to promise that in writing. A reasonable bar for *this*
project specifically: all seven parts shipped, the compatibility matrix in
`docs/manual-testing.md` has real (not `PENDING`) results for the terminals
you care about, and you haven't needed a breaking change in a while.

---

## FAQ

**Do I need to tag every commit?** No. Tag when you want to hand someone
(including yourself, in a different config) a stable point to depend on.
Most commits aren't releases.

**What if I forget to bump a version file and tag anyway?** Fix the file,
commit it, and re-tag — `git tag -d v0.2.0 && git push origin :v0.2.0` to
delete the tag locally and remotely, then redo steps 7–9. Only do this if
the tag hasn't been widely pulled yet; once people depend on a tag, treat it
as permanent and ship a new PATCH instead.

**What do I do if `main` and the topic branch's version files conflict?**
Resolve in favor of whichever is actually higher — version bumps should
only ever go up.

**Where does the four-line "delete these and confirm it still renders"
acceptance test fit in?** That's a manual gate before tagging a
cross-platform-relevant release (`v0.2.0` and beyond), not a version-number
decision by itself — see `docs/manual-testing.md` and
`prompts/README.md`'s Dogfooding section.
