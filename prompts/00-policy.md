# Execution Policy — Read Before Every Part

This policy applies to all seven parts. Each part prompt assumes you have read
it and does not repeat these rules.

---

## 1. One part per session

Implement **only** the part you were asked to implement. Do not begin the next
part, do not "get a head start," and do not refactor code that belongs to a
later part.

Each part is a stable outcome and commit boundary. The seven boundaries do not
move. Low-level implementation details, however, must be planned from the
repository as it actually exists when the part begins — not from assumptions
frozen at planning time.

## 2. The working tree must always be a safe stopping point

Every commit must be independently reviewable, revertible, and useful. The API
budget may run out mid-project. Never begin work that cannot be left coherent.

- Do not squash or rewrite previously completed commits.
- Do not perform unrelated refactors.
- Do not leave the tree broken between parts.

## 3. Architectural invariants — never violate these

These properties define the product. Breaking one is a regression regardless of
what else the part achieved.

- Unsaved Neovim buffer contents render directly; no file save is required.
- Neovim talks to exactly one persistent Node process over NDJSON on stdin and
  stdout.
- **No HTTP server, no WebSocket server, no listening TCP port.** Ever.
- One persistent headless Chromium browser is reused. Pages stay hidden.
- The visible preview remains a PNG inside a normal Neovim split.
- Existing source-to-preview synchronization keeps working.
- Existing scroll-only capture reuse keeps working.
- Existing stale-request protection and backpressure keep working.
- Existing image ownership and cleanup keep working.
- Existing network blocking and Markdown sanitization keep working.

### The `javaScriptEnabled: false` rule

`renderer/src/browser.js` creates its context with `javaScriptEnabled: false`.
This is a security control: it prevents any script originating from rendered
Markdown from executing.

**Do not set it to `true`.** Playwright's `page.evaluate()` still works with it
disabled — the existing `collectBlockGeometry()` in `renderer/src/source-map.js`
proves this today. Trusted renderer code can manipulate the DOM freely. If DOM
work appears to fail, the cause is your code, not this flag.

## 4. Honesty requirements

- Do not claim a terminal is supported because an environment variable matched.
  Detection evidence is not validation.
- Do not claim graphical validation for a terminal you did not actually launch
  and look at.
- Do not report an approximate source position as `exact`.
- Do not describe the preview as native terminal selection or an embedded
  webview. It is browser-backed synthetic interaction over a raster surface.
- If tests fail, say so and show the output. If you skipped something, say so.

## 5. Testing and verification

Run these before every commit:

```bash
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
stylua --check lua/ plugin/ tests/lua/    # if stylua is installed
```

Never run `playwright install`. Never download a browser.

**These commands are necessary but not sufficient.** They exercise Lua and
Node functions directly; they do not prove a user-facing `:MdViewer*` command
works when a user actually types it. Part 1 shipped `:MdViewerHealth`
callable-but-crashing — `nvim_buf_set_lines` rejects a replacement line
containing an embedded newline — because the automated smoke test called
`health.check()` (the `:checkhealth` code path) and never called
`health.show()`, the actual handler behind `:MdViewerHealth`. The bug was
real, shipped, and was found by the operator, not by testing.

**If a part adds or changes a `:MdViewer*` command, or changes what
`:MdViewerHealth`, `:MdViewerDebug`, or `:checkhealth md-viewer` report,**
invoke that exact command — not the library function underneath it — in a
headless Neovim session before reporting the part done:

```bash
nvim --headless -u NONE -i NONE \
  -c "set runtimepath+=." \
  -c "lua require('md-viewer').setup({})" \
  -c "<TheCommand>" \
  -c "lua vim.wait(8000, function() return <condition proving it finished> end, 50)" \
  -c "qa!"
```

This needs no graphical terminal and no real terminal image protocol — it only
proves the command runs to completion without error and produces sane output.
That is a different, cheaper claim than the graphical validation required by
§4, and where a part touches both, both are required.

If a graphical terminal is unavailable in your environment — it usually is —
complete all automated work, write precise manual test instructions, and mark
the graphical combinations unvalidated. Do not claim visual success you did not
observe.

## 6. Closing every part

After the implementation passes, before you report back:

1. **Commit.** Use the exact commit message given in the part prompt. Do not
   commit if anything is knowingly broken.
2. **Update the part prompt's frontmatter** — set `status: done` and record the
   commit hash.
3. **Update `prompts/README.md`** — set the row's status and commit in the table.
4. **Update `docs/cross-platform-implementation-status.md`** with:
   - Completed parts and their commit hashes.
   - Current verified architecture and behavior.
   - Tests run and their exact results.
   - Known limitations and unresolved risks.
   - Decisions that changed assumptions in the original specification.
   - The exact safe stopping point and the first next action.
5. **Revise downstream prompts where discoveries invalidate them.** This is not
   optional. If you found that a later part's stated approach will not work, or
   that scope must move between parts, edit those prompt files now and explain
   what changed in the status document. Do not silently merge, drop, or reorder
   the seven boundaries — if a boundary genuinely must move, say so explicitly
   and wait for approval.

## 7. Reporting back

End your response with:

1. Part number and title.
2. Commit hash and subject.
3. Files changed.
4. Tests run and exact results.
5. Acceptance criteria met, and any not met.
6. Discoveries that affect later parts, and which prompts you edited as a result.
7. What remains approximate or unvalidated.
8. A clear statement that work is paused pending approval for the next part.

**Do not continue into the next part.** Stop and wait.
