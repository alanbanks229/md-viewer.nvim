---
part: 7
title: Hardening, documentation, and the compatibility matrix
status: not-started
model: Sonnet 5
depends_on: parts 1-6
commit: ""
ships: v0.3.0
---

# Part 7 of 7 — Hardening, Documentation, and Compatibility

> Read `prompts/00-policy.md` first.

## Objective

Turn six parts of implementation into a release. Full regression, a real security
review, complete cleanup on every exit path, honest documentation, and a
compatibility matrix that does not overclaim.

**This part completes `v0.3.0`.** Do not downgrade the model for it — it contains
a security review, not just prose.

---

## Verified repository facts

**Documentation surface to update:**

```text
README.md
CHANGELOG.md
SECURITY.md
doc/md-viewer.txt          # 126 lines, Vim help format
docs/architecture.md
docs/security.md
docs/manual-testing.md
docs/troubleshooting.md
docs/development.md
```

**Existing security controls to verify are still intact** (do not merely assert
this — test it):

- `renderer/src/security.js` — `installNetworkPolicy()` and the `csp` constant;
  `localImageDataUri()` performs canonical-path, symlink, MIME-signature, and
  size validation.
- `lua/md-viewer/security.lua` — the Lua-side path constraints.
- `renderer/src/browser.js` — `javaScriptEnabled: false`, CSP injected into the
  document head, launch args `--disable-extensions --disable-component-update
  --no-first-run --no-default-browser-check`.
- `renderer/src/markdown.js` — the `sanitizeHtml` allowlist, `allowedSchemes`
  (`data`, `http`, `https`, `mailto`), `allowedSchemesByTag`,
  `allowProtocolRelative: false`.

**Existing tests that must still pass:** `tests/node/security.test.js` covers
traversal, symlink escape, remote URLs, wrong MIME, oversize files, and that the
network policy blocks HTTP. `tests/node/markdown.test.js` covers sanitization
with the raw-HTML override enabled.

**Cleanup paths to exercise:** preview close, buffer wipeout, tab leave, `VimSuspend`
/ resume, renderer restart, backend fallback, `VimLeave`. `kitty_raw.lua` tracks
`owned` images and `item.placement_ids`; `mouse.lua` restores mappings via
`vim.fn.mapset`.

**CI** was extended in Part 1 to macOS and Ubuntu with `stylua --check`.

---

## Implement

### 7.1 Full regression

Run everything and fix what broke. Explicitly re-verify the behaviours the
earlier parts touched but did not own:

initial rendering; unsaved edits; scroll-only captures; fast and settled frames;
pinned previews; source-to-preview cursor following; local images; backend
selection and fallback; cleanup; floating-window handling; image placement.

### 7.2 Security review

Not a checklist recital — actually attempt the attacks and add the tests:

- Malicious `data-*` attributes surviving sanitization.
- `javascript:`, `data:`, and `vbscript:` links.
- Document-root escapes via `../`, absolute paths, and symlinks.
- Stale interaction requests against a superseded content revision.
- Cross-document interaction attempts.
- Search strings containing HTML, and selection text containing HTML.
- Unicode and malformed input to every protocol boundary.
- Confirm no HTTP server, no WebSocket server, and no listening port exists —
  assert it, do not assume it.
- Confirm `javaScriptEnabled` is still `false` and Markdown-originated script
  still cannot execute.
- Confirm the hidden page cannot be navigated away from the generated document.

Consider running `/security-review` over the accumulated diff as a second pass.

### 7.3 Cleanup and lifecycle

Verify and test that every exit path leaves nothing behind:

| Path | Must release |
|------|--------------|
| Preview close | images, placements, gesture state, pending captures |
| Buffer wipeout | session, mappings if last graphical preview |
| Tab leave / enter | placements recreated correctly |
| Suspend / resume | placements recreated |
| Renderer restart | mappings restored, interaction state cleared |
| Backend fallback | graphical state torn down cleanly |
| `VimLeave` | all images deleted, all mappings restored, temp files removed |

Mappings must be restored **even after a renderer failure**. Cancel or invalidate
pending selection captures on teardown. Temporary PNGs must be unlinked —
`browser.js` tracks them in `this.files` and removes `this.tempDir` on `close()`.

### 7.4 Diagnostics

Final `:MdViewerHealth`, `:MdViewerDebug`, and `:checkhealth md-viewer` output:

terminal profile and detection evidence; capability confidence; selected backend
and why; effective z-index and its source; platform; browser executable;
multiplexer; preview placement and size in cells; Chromium viewport in CSS
pixels; calibration tier; current content revision; interaction enabled state;
selection state and cached selection **length**; active search query and match
count; last source-navigation precision; interaction request counts; coalesced
drag events; fast and settled capture timings; stale-interaction count; and which
document is currently loaded in Chromium.

**Never print selected private text in diagnostics.** Lengths and counts only.

This is the largest diagnostics field set added anywhere in the project.
Invoke `:MdViewerHealth`, `:MdViewerDebug`, and `:checkhealth md-viewer`
directly in a headless session (policy §5) with a preview actually open and
with an active selection/search present, and confirm every field above
renders without error — do not rely solely on `health.check()`/
`debug.snapshot()` return values. Any table-shaped field (lists, nested
status objects) needs the same scrutiny that broke `:MdViewerHealth` in Part 1
(`nvim_buf_set_lines` rejects embedded newlines).

### 7.5 Manual compatibility matrix

Rewrite `docs/manual-testing.md` as a repeatable procedure for iTerm2, Kitty,
WezTerm, Ghostty, and Warp, covering:

initial image; live and unsaved edits; source cursor following; keyboard and
mouse-wheel scrolling; click-to-source; exact source columns; line-level
fallback; forward, backward, and multi-paragraph selection; copying;
double-click word selection; search; link activation; resize; font-size change;
all four split positions; winbar; statusline; global statusline; floating
windows; passive overlays; tab switching; suspend and resume; HiDPI and standard
DPI; flicker; and cleanup.

Record results with exactly these labels:

```text
Supported                            actually launched and verified
Experimental                         partially verified, known gaps
Protocol-compatible but unvalidated  should work, nobody has looked
Unsupported                          known not to work
```

**Do not mark a terminal Supported because its environment variable was
recognized, or because its protocol is compatible.** Only terminals you actually
launched and looked at get `Supported`. Anything you could not test gets
`Protocol-compatible but unvalidated` — including all of them, if you have no
graphical environment. That is an honest and acceptable outcome.

Likewise: do not advertise tmux, screen, or Zellij support unless escape-sequence
passthrough was implemented and tested. Detect, warn, and stop there.

### 7.6 Documentation

Put this distinction prominently in `README.md` and `docs/architecture.md`:

> The preview is still a browser-rendered PNG surface. Mouse and keyboard
> interactions are forwarded to the persistent Chromium DOM, which performs
> hit-testing, selection, search, and link resolution before the viewport is
> recaptured. This provides browser-like behavior but is not native terminal
> text selection or a real embedded webview.

Document: click versus drag behaviour; selection copying; optional
copy-on-select; search; safe link handling; source-position precision levels and
what each means for the user; Unicode byte-column behaviour; terminal profiles;
explicit capability overrides; browser discovery per platform; which terminals
are experimental; multiplexer limitations; and the security implications of
interaction.

Update `doc/md-viewer.txt` with every new command, mapping, and configuration
key, with tags and a table of contents. It is Vim help — keep the format valid.

Update `SECURITY.md` and `docs/security.md` for the interaction surface.
Update `docs/troubleshooting.md` with the failure modes the new code introduces:
wrong terminal profile, no browser found, interaction not responding, selection
not appearing, wrong cursor position on click.

Write the `CHANGELOG.md` entry for the release.

### 7.7 Final polish

- `stylua lua/ plugin/ tests/lua/` — formatted, and CI enforces it.
- Remove dead code, stale comments, and any leftover scaffolding.
- Confirm the README's supported-terminal claims match the matrix exactly. If
  they disagree, the matrix is right.
- Bump the version in `renderer/package.json` and anywhere else it appears.

---

## Do not do in this part

- Do not add features. Anything discovered now goes in the status document as
  future work.
- Do not claim graphical validation you did not perform.
- Do not add Sixel.
- Do not weaken a security control to make a test pass.

---

## Acceptance criteria

- [ ] Every existing and new test passes on macOS and Ubuntu CI.
- [ ] `stylua --check` passes and is enforced in CI.
- [ ] Security review completed with tests for each attack listed in §7.2.
- [ ] No HTTP server, WebSocket server, or listening port — asserted by test.
- [ ] `javaScriptEnabled` is still `false`.
- [ ] Every lifecycle path in §7.3 releases everything, including after failure.
- [ ] Diagnostics report all §7.4 fields and leak no selected text.
- [ ] `docs/manual-testing.md` is a repeatable five-terminal procedure.
- [ ] Terminal statuses use the four honest labels and are not overclaimed.
- [ ] tmux is not advertised.
- [ ] README, CHANGELOG, SECURITY, `doc/md-viewer.txt`, and all `docs/` updated.
- [ ] The raster-surface distinction is documented prominently.
- [ ] README claims and the compatibility matrix agree.
- [ ] Version bumped; changelog entry written.
- [ ] Status document reflects the final state and lists deferred work.

## Operator verification (manual)

This is the part only you can finish. Work through `docs/manual-testing.md` in
each terminal you actually have, and update the matrix with real results — not
predictions. A row marked `Protocol-compatible but unvalidated` is a perfectly
good release state. A row marked `Supported` that you never launched is a bug
report waiting to be filed by someone else.

---

## Commit

```text
feat(md-viewer): cross-platform preview part 7/7 - hardening and documentation
```

Then follow `prompts/00-policy.md` §6 and §7.
