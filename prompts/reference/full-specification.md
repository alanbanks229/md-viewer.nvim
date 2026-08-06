# Implement Cross-Terminal Rendering and VS Code-Like Markdown Preview Interaction in `md-viewer.nvim`

You are working directly inside the current checkout of the `md-viewer.nvim` repository.

Implement a production-quality next version of the plugin that:

1. Generalizes the Kitty graphics backend for iTerm2, Kitty, WezTerm, Ghostty, and Warp.
2. Adds browser-backed mouse interaction to the rasterized Markdown preview.
3. Distinguishes clicks from drags.
4. Supports source navigation from rendered content.
5. Supports visible DOM text selection and copying.
6. Adds rendered-preview search and safe link activation.
7. Preserves the existing local-process and security architecture.
8. Includes automated tests, diagnostics, documentation, and an honest compatibility matrix.

Do not stop after writing a plan or proposing pseudocode.

Inspect the repository, implement the changes, run the complete test suite, fix regressions, update the documentation, and leave the working tree in a coherent, reviewable state.

Use the current checkout as the source of truth. Verify existing behavior before changing it because the repository may have changed since this prompt was written.

Do not rewrite the project from scratch.

---

# 1. Inspect the Existing Architecture

Before modifying code, inspect at least:

```text
README.md
CHANGELOG.md
SECURITY.md

docs/architecture.md
docs/security.md
docs/manual-testing.md
docs/troubleshooting.md
docs/development.md

lua/md-viewer/config.lua
lua/md-viewer/controller.lua
lua/md-viewer/coordinates.lua
lua/md-viewer/mouse.lua
lua/md-viewer/navigation.lua
lua/md-viewer/preview.lua
lua/md-viewer/process.lua
lua/md-viewer/protocol.lua
lua/md-viewer/renderer.lua
lua/md-viewer/state.lua
lua/md-viewer/sync.lua

lua/md-viewer/backends/init.lua
lua/md-viewer/backends/kitty_raw.lua
lua/md-viewer/backends/nvim_img.lua

renderer/src/browser.js
renderer/src/main.js
renderer/src/markdown.js
renderer/src/protocol.js
renderer/src/source-map.js
renderer/src/security.js

tests/lua/
renderer/test/
```

Confirm the current equivalents if any files have moved.

Preserve these architectural properties:

* Unsaved Neovim buffer contents are rendered directly.
* Neovim communicates with one persistent Node process through NDJSON over stdin and stdout.
* No HTTP server is introduced.
* No WebSocket server is introduced.
* No localhost or external TCP listener is introduced.
* One persistent headless Chromium browser is reused.
* Browser pages remain hidden.
* The rendered preview remains a PNG surface inside a normal Neovim split.
* Existing source-to-preview synchronization remains functional.
* Existing scroll-only capture reuse remains functional.
* Existing stale-request protection and backpressure remain functional.
* Existing image ownership and cleanup remain functional.
* Existing network blocking and Markdown sanitization remain functional.

The desired architecture is:

```text
Markdown source buffer
        |
        v
Markdown parser and source-provenance mapping
        |
        v
Persistent Chromium DOM
        |
        v
Viewport PNG
        |
        v
Kitty graphics placement
        |
        v
Neovim preview split

Terminal mouse input
        |
        v
Neovim cell-coordinate normalization
        |
        v
Unified NDJSON interaction method
        |
        v
Chromium DOM hit-testing, selection, search, or link lookup
        |
        v
Updated screenshot and semantic result
        |
        v
Neovim image update, cursor movement, or clipboard action
```

---

# 2. Important Corrections and Non-Negotiable Design Rules

## 2.1 Mouse coordinates are terminal cells, not pixels

`vim.fn.getmousepos()` provides 1-based screen and window cell coordinates.

Do not use guessed conversions such as:

```lua
x = mouse.winx * 10
y = mouse.winy * 20
```

Do not require exact physical terminal-cell dimensions for browser hit-testing.

Map terminal cells into Chromium CSS viewport coordinates using normalized geometry.

A representative conversion is:

```text
localCellX = screenColumn - 1 - placementColumn
localCellY = screenRow    - 1 - placementRow

cssX = ((localCellX + 0.5) / placementWidthCells)  * viewportWidthCssPx
cssY = ((localCellY + 0.5) / placementHeightCells) * viewportHeightCssPx
```

Use the center of a terminal cell because the TUI normally cannot provide a subcell pointer position.

Clamp coordinates to the Chromium viewport.

Account for:

* Neovim's 1-based mouse coordinates.
* Zero-based image placement coordinates.
* Winbars.
* Statuslines.
* Global statuslines.
* Tablines.
* Split separators.
* Command-line rows.
* Resized windows.
* Cropped image placements.
* Passive-overlay exclusion rectangles.
* Focusable floating windows.
* Hidden or suppressed images.

Do not dispatch preview interactions when the pointer is inside an excluded or occluded rectangle.

## 2.2 Block line annotations are not enough for exact columns

The repository may already attach block-level attributes equivalent to:

```html
<p data-source-start="13" data-source-end="15">
```

Keep those attributes for block synchronization.

Do not replace them with only:

```html
data-source-line="14"
```

A browser caret offset is an offset in rendered DOM text. It is not automatically the same as a Markdown source column.

Examples where the offsets diverge include:

```markdown
**bold**
[visible label](https://example.com)
`inline code`
&amp;
# Heading
> blockquote
- list item
```

The rendered DOM omits or transforms Markdown syntax.

Implement richer source provenance for exact navigation.

## 2.3 Cursor columns must be Neovim byte offsets

`nvim_win_set_cursor()` expects:

* One-based source lines.
* Zero-based byte columns.

Browser text-node offsets and JavaScript string offsets must not be passed directly as Neovim columns.

Correctly handle:

* UTF-8 source bytes.
* JavaScript UTF-16 offsets.
* Emoji.
* Surrogate pairs.
* Combining characters.
* Accented characters.
* CJK text.
* Tabs.
* Repeated text.
* HTML entities.

## 2.4 Do not claim native terminal selection

The visible surface remains a PNG.

The implementation will provide browser-backed synthetic selection:

* Neovim captures terminal mouse gestures.
* Chromium creates a real DOM `Selection`.
* Chromium paints the selection.
* A new screenshot displays the highlight.
* Selected text is returned to Neovim.

Document this accurately.

Do not describe it as native terminal text selection or a real embedded webview.

## 2.5 One interaction method does not mean one request per gesture

Use one unified NDJSON protocol method, preferably:

```text
interact
```

with typed actions.

A click may require only one release-time request.

A live drag selection requires multiple coalesced interaction requests so that the user can see the selection changing.

Do not force the entire gesture into one IPC request if doing so removes live visual feedback.

---

# 3. Gesture Model

Implement mouse gesture classification in Lua.

Maintain per-session pointer state containing at least:

```text
pressed
press screen cell
latest screen cell
press time
drag started
interaction serial
selection request in flight
newest pending drag point
current content revision
cached selected text
```

Support:

```text
<LeftMouse>
<LeftDrag>
<LeftRelease>
<2-LeftMouse>
<C-LeftMouse>
<D-LeftMouse>
```

Use platform-appropriate modifier mappings where available.

## 3.1 Click-versus-drag classification

Record the press cell.

Classify the gesture using configurable cell or normalized CSS distance.

A possible configuration is:

```lua
interaction = {
  enabled = true,
  drag_threshold_cells = 1,
}
```

Use Euclidean distance or maximum-axis distance consistently.

Do not classify based on guessed physical pixels.

Expected behavior:

### Click below threshold

A normal click should:

1. Convert the release position to Chromium CSS coordinates.
2. Hit-test the DOM.
3. Resolve the most precise available Markdown source position.
4. Move the source cursor.
5. Return a precision field indicating whether the result is exact, line-level, or block-level.

### Drag at or above threshold

A drag should:

1. Resolve an anchor caret from the press point.
2. Resolve a focus caret from the latest drag point.
3. Create or update a Chromium DOM selection.
4. Capture the selected state.
5. Display the updated image.
6. Return selected text on release.
7. Cache the text in the Neovim session.

### Double click

Use double click for browser-style word selection unless repository conventions strongly justify another behavior.

If double-click source navigation already exists or is preferred, make the behavior configurable rather than silently breaking selection.

### Modifier click

Use Ctrl-click or Command-click for safe link activation.

Do not navigate the hidden Chromium page away from the controlled Markdown document.

## 3.2 Copy behavior

Do not automatically copy every drag selection by default because that is not how VS Code or normal browser selection behaves.

Provide:

```lua
interaction = {
  copy_on_select = false,
}
```

When enabled, a completed drag may copy to:

```text
"
+
```

By default, selection should remain highlighted and be copied explicitly through:

```text
:MdViewerCopy
```

and a preview-local mapping such as:

```text
y
```

When copying:

* Write to the unnamed register.
* Write to the `+` register when clipboard support is available.
* Do not shell out to `pbcopy`, `xclip`, or platform-specific clipboard commands when Neovim registers can perform the operation.
* Notify clearly when no text is selected.
* Avoid putting an enormous selected string into a notification.

---

# 4. Source Provenance and Exact Source Navigation

Refactor Markdown rendering so it can return both HTML and source-map metadata.

A suitable conceptual result is:

```js
{
  html,
  sourceMap
}
```

Update the Markdown cache accordingly.

## 4.1 Preserve block ranges

Keep existing block metadata equivalent to:

```text
data-source-start
data-source-end
```

These remain useful for scrolling and fallback navigation.

## 4.2 Add stable source IDs

Assign stable per-render source IDs to relevant rendered blocks and inline text regions:

```html
<span data-md-source-id="s42">visible text</span>
```

Whitelist the required data attributes in the sanitizer.

Do not put raw Markdown content or unsafe executable data into attributes.

Keep the complete mapping in trusted Node memory where practical.

## 4.3 Build inline provenance

Create mappings that relate rendered text boundaries to Markdown source positions.

A source-map entry should be capable of representing:

```js
{
  id,
  startLine,
  startByteColumn,
  endLine,
  endByteColumn,
  startByteOffset,
  endByteOffset,
  renderedBoundaryToSourceByte
}
```

The exact representation may differ, but it must support reliable conversion from a DOM text-node boundary to a source byte position.

For each rendered text region, distinguish:

```text
exact
line
block
none
```

Do not guess an exact column when the parser cannot establish one reliably.

If markdown-it does not expose sufficient inline position data:

1. Keep markdown-it as the renderer.
2. Add a focused positional parsing or provenance pass.
3. Align the positional parse with rendered tokens.
4. Add tests proving the alignment.
5. Fall back conservatively when alignment is ambiguous.

Do not replace the entire renderer merely to obtain source columns unless there is a compelling, tested reason.

Potential implementation approaches include:

* Custom markdown-it renderer rules with inline provenance.
* A parser plugin that exposes source positions.
* A second position-aware AST pass used only for provenance.
* Trusted source-map structures keyed by generated DOM IDs.

Choose the smallest reliable approach.

## 4.4 DOM hit-testing

Prefer:

```js
document.caretPositionFromPoint(x, y)
```

Fall back to:

```js
document.caretRangeFromPoint(x, y)
```

when necessary.

Also use:

```js
document.elementFromPoint(x, y)
```

for links and non-text elements.

Normalize a hit so it resolves to:

```js
{
  node,
  offset,
  sourceId,
  sourcePosition,
  precision,
  element,
  link
}
```

Handle:

* Text nodes.
* Inline formatting.
* Inline code.
* Fenced code.
* Headings.
* Links.
* Images.
* Tables.
* List markers.
* Task-list controls.
* Empty blocks.
* Whitespace.
* Page padding.
* Scroll-past-end padding.
* Coordinates outside the article.

## 4.5 Navigation result

Return source locations in a clear format:

```js
{
  line: 12,
  byteColumn: 4,
  precision: "exact"
}
```

Line numbers returned to Lua should be one-based, or the protocol should explicitly document and consistently convert them.

Columns supplied to `nvim_win_set_cursor()` must be zero-based byte offsets.

When only line or block precision is available:

```js
{
  line: 12,
  byteColumn: 0,
  precision: "line"
}
```

Do not falsely label approximate positions as exact.

---

# 5. Unified Renderer Interaction Protocol

Extend the NDJSON protocol with one method:

```text
interact
```

Use typed actions such as:

```text
gesture_commit
selection_preview
selection_commit
selection_clear
selection_text
word_select
activate_at
find_set
find_next
find_previous
find_clear
```

Exact action names may differ if a cleaner design emerges.

Every interaction request must include enough information to reject stale work:

```js
{
  documentId,
  contentRevision,
  viewportWidthPx,
  viewportHeightPx,
  scrollY,
  action,
  coordinates,
  modifiers,
  clickCount,
  captureScale
}
```

Do not accept interactions against an outdated content revision.

Return a specific stale-interaction error code.

## 5.1 Atomic interaction results

Where an interaction changes visible DOM state, perform the DOM mutation and screenshot in the same queued renderer operation.

For example, `selection_commit` should be able to return:

```js
{
  kind: "selection",
  text,
  collapsed,
  pngPath,
  captureScale,
  scrollY,
  viewportHeightPx,
  documentHeightPx,
  contentRevision
}
```

A click may return:

```js
{
  kind: "source",
  sourcePosition: {
    line,
    byteColumn,
    precision
  }
}
```

A modifier-click may return:

```js
{
  kind: "link",
  link: {
    href,
    type
  }
}
```

Avoid requiring a separate capture request immediately after every interaction when the same renderer operation can return the updated PNG.

## 5.2 Renderer queueing

Chromium page mutations, scrolling, rendering, and interaction must be serialized safely.

The current renderer may use one page shared across documents.

Account for that explicitly.

An interaction for document A must never accidentally operate on document B's currently loaded DOM.

Refactor common logic into an operation equivalent to:

```text
ensureDocumentActive(documentId, contentRevision, cachedHtml, viewport, theme)
```

If the requested document is not active:

* Rehydrate its cached HTML and source map.
* Restore its viewport and scroll position.
* Restore safe per-document interaction state where possible.
* Reject with an actionable cache-miss error when rehydration is impossible.

Do not allow cross-document selection or source-map leakage.

## 5.3 Separate stale-work lanes

Do not let a harmless selection request incorrectly supersede a newer full content render.

Use separate per-document serials or generations for:

* Content rendering.
* Viewport captures.
* Interaction updates.
* Settled interaction frames.

All operations must still verify the same content revision.

A newer content render should invalidate old interactions.

A newer drag position should supersede an older drag position without invalidating unrelated document work.

---

# 6. DOM Selection

Implement actual Chromium DOM selection.

For anchor and focus carets:

* Resolve both points with caret hit-testing.
* Normalize element-boundary results to usable text boundaries.
* Support forward and backward dragging.
* Prefer `Selection.setBaseAndExtent()` where available.
* Otherwise construct a correctly ordered `Range`.
* Do not accidentally collapse reversed selections.

The browser's real selection should paint the visible highlight.

Support selection across:

* Nested emphasis.
* Strong text.
* Links.
* Inline code.
* Multiple paragraphs.
* Lists.
* Tables.
* Blockquotes.
* Code blocks.
* Unicode text.

## 6.1 Drag preview performance

Do not take a full device-scale screenshot for every raw mouse movement.

Reuse the existing fast-scroll architecture:

1. Permit at most one selection-preview request in flight.
2. Keep only the newest pending drag point.
3. Coalesce intermediate events.
4. Use CSS-scale screenshots during movement.
5. Display completed current frames.
6. Prevent stale images from replacing newer frames.
7. Capture one device-scale frame after release or a configurable settle delay.

Add configuration similar to:

```lua
interaction = {
  drag_debounce_ms = 40,
  settle_ms = 120,
}
```

Do not impose an arbitrary high fixed frame rate.

Let screenshot and terminal-transfer completion provide natural backpressure.

## 6.2 Selection persistence

Keep selection intact during:

* Scroll-only captures.
* Settled high-resolution captures.
* Temporary image replacement.
* Preview focus changes.

On content changes:

* Clear selection safely, or
* Restore it only when source provenance proves that the range remains valid.

Never apply a selection from an older content revision to newer content.

For multiple preview sessions, do not leak one document's selection into another document.

---

# 7. Lua Mouse Layer

Extend the current mouse module rather than creating unrelated global mappings elsewhere.

Preserve and restore existing user mappings exactly.

Install mappings only while at least one graphical preview exists.

Detach them when no graphical preview sessions remain.

Handle at least normal, insert, and visual modes according to current project conventions.

## 7.1 Event routing

For each mouse event:

1. Call `vim.fn.getmousepos()`.
2. Identify an active session from the preview window.
3. Confirm the pointer lies inside the image placement rectangle.
4. Confirm it is not inside an exclusion or occlusion.
5. Convert the cell to CSS viewport coordinates.
6. Dispatch the appropriate interaction action asynchronously.
7. Return or replay normal behavior when the event does not belong to a preview.

Events outside the preview must not be swallowed.

Statusline, separator, tabline, command-line, and unrelated floating-window clicks must retain normal Neovim behavior.

## 7.2 Session cleanup

Clear gesture state during:

* Preview close.
* Buffer wipeout.
* Tab leave.
* Vim suspend.
* Renderer restart.
* Content revision changes.
* Backend fallback.
* Neovim exit.

Cancel or invalidate pending selection captures.

Restore mappings even after renderer failures.

---

# 8. Source Cursor Updates

Add a source navigation function that accepts:

```lua
{
  line = number,
  byte_column = number,
  precision = string,
}
```

Before moving the cursor:

* Validate the source window.
* Clamp the line to the buffer line count.
* Clamp the byte column to the source line's byte length.
* Avoid placing the cursor inside an invalid UTF-8 byte sequence.
* Use the existing synchronization guard.
* Avoid creating source-to-preview feedback loops.

Make source focusing configurable:

```lua
interaction = {
  focus_source_on_click = true,
}
```

When false, update the source cursor without changing the active window.

Record the last interaction precision in debug output.

---

# 9. Safe Link Interaction

Use modifier-click to activate links.

Classify links as:

```text
fragment
http
https
mailto
local_file
unsafe
```

Behavior:

* Fragment links scroll within the controlled Chromium document.
* HTTP and HTTPS links may open through `vim.ui.open()` after an explicit user action.
* Mail links may use `vim.ui.open()` when supported.
* Local files must remain constrained to the configured document root.
* Reject unsafe schemes.
* Reject root escapes.
* Reject symlink escapes.
* Reject arbitrary hidden-browser navigation.

Do not let Chromium navigate away from the generated Markdown page.

Normal unmodified clicks on links should still support source navigation.

---

# 10. Browser-Backed Find

Add rendered-text search using the persistent DOM.

Commands:

```text
:MdViewerFind [query]
:MdViewerFindNext
:MdViewerFindPrevious
:MdViewerFindClear
```

Suggested preview-local mappings:

```text
/   prompt for rendered-text search
n   next match
N   previous match
Esc clear find highlights or selection
```

Define predictable Escape precedence, for example:

1. Clear active find.
2. Otherwise clear selection.
3. Otherwise preserve normal behavior.

Search rendered text rather than raw Markdown syntax.

Do not implement highlighting by unsafe HTML string replacement.

Use safe DOM traversal, ranges, CSS highlight APIs where suitably supported, or controlled wrapper elements.

Track:

* Query.
* Match count.
* Active match.
* Match source position where available.
* Per-document search state.

Scroll the active result into view and return an updated screenshot.

---

# 11. Cross-Terminal Capability Layer

Create a dedicated terminal capability module or directory.

Profiles should include:

```text
iterm2
kitty
wezterm
ghostty
warp
generic_kitty
unknown
```

A profile should report:

* Terminal identity evidence.
* Platform.
* Whether Kitty graphics is explicit, verified, inferred, or unavailable.
* Default raw z-index.
* Placement assumptions.
* Deletion assumptions.
* Crop assumptions.
* Multiplexer status.
* Validation status.
* Known caveats.

## 11.1 Capability resolution order

Use:

1. Explicit user configuration.
2. Verified `vim.ui.img` support.
3. A safe runtime Kitty graphics probe, only if it can be implemented without consuming normal input.
4. Conservative terminal-profile inference.
5. Text-cell fallback.

Do not fake a successful protocol probe based on environment variables.

If a safe Neovim TUI probe is not practical:

* Keep the probe disabled or optional.
* Clearly report inferred rather than verified support.
* Support explicit user override.
* Document the limitation.

## 11.2 Configuration

Add a configuration surface similar to:

```lua
terminal = {
  profile = "auto",
  kitty_graphics = "auto",
  probe = "safe",
}
```

Allow explicit profiles for all target terminals.

## 11.3 Raw backend refactor

Keep the Kitty encoder generic.

Move terminal-specific defaults out of `kitty_raw.lua`.

Preserve:

* Owned image IDs.
* Owned placement IDs.
* Targeted deletion.
* Chunked PNG transmission.
* Upload-once behavior.
* Cropped placements.
* Cursor save and restore.
* Quiet mode.
* Double buffering.
* Cleanup.

Test:

* Negative z-index.
* Zero z-index.
* Positive z-index.
* Placement replacement.
* Placement deletion.
* Image deletion.
* Resize.
* Split movement.
* Alternate-screen transitions.
* Cropped placements.
* Passive overlays.
* Focusable floats.
* Font-size changes.
* Tab changes.

## 11.4 Do not add Sixel in this task

The named target terminals can be addressed through the Kitty graphics path or existing Neovim image abstraction.

Do not add a Sixel backend merely because the feature proposal mentioned Sixel.

Keep the backend interface extensible so Sixel could be added separately later.

## 11.5 Multiplexers

Detect tmux and other multiplexers.

Do not claim multiplexer support unless escape-sequence passthrough has actually been implemented and tested.

Health output should clearly warn about unvalidated multiplexer configurations.

---

# 12. Cross-Platform Browser Discovery

Generalize Chromium executable discovery.

Never run:

```text
playwright install
```

Never silently download a browser.

Continue supporting an explicit executable path.

Search appropriately for:

## macOS

```text
Google Chrome
Chromium
Microsoft Edge
common package-manager paths
```

## Linux

```text
google-chrome
google-chrome-stable
chromium
chromium-browser
microsoft-edge
microsoft-edge-stable
```

Search `PATH` and suitable standard paths.

## Windows

Search:

```text
PATH
PROGRAMFILES
PROGRAMFILES(X86)
LOCALAPPDATA
standard Chrome locations
standard Chromium locations
standard Edge locations
```

Use platform-safe path handling.

Return actionable errors and report the selected executable in health output.

Test discovery using mocked file-system and environment behavior rather than requiring every browser to be installed.

---

# 13. Security Requirements

Preserve all secure defaults.

Required defaults:

* No HTTP server.
* No WebSocket server.
* No listening port.
* Runtime browser network requests blocked.
* Restrictive Content Security Policy.
* Markdown-originated JavaScript disabled.
* Raw Markdown HTML disabled.
* Remote images removed.
* Local images constrained to the document root.
* Canonical-path checks.
* Symlink checks.
* File signature checks.
* File-size limits.
* Safe temporary-file cleanup.

Playwright `page.evaluate()` used by trusted renderer code is allowed.

Do not enable arbitrary script execution originating from rendered Markdown.

Whitelist only the new source-map attributes required by the implementation.

Test:

* Malicious attributes.
* Unsafe links.
* `javascript:` links.
* Root escapes.
* Symlink escapes.
* Stale interaction requests.
* Search strings containing HTML.
* Selection text containing HTML.
* Unicode and malformed input.
* Cross-document interaction attempts.

---

# 14. Configuration

Add a coherent interaction configuration.

A suggested shape is:

```lua
interaction = {
  enabled = true,
  click_to_source = true,
  focus_source_on_click = true,
  selection = true,
  copy = true,
  copy_on_select = false,
  links = true,
  find = true,
  word_select = true,
  drag_threshold_cells = 1,
  drag_debounce_ms = 40,
  settle_ms = 120,
}
```

Use naming consistent with the project.

Validate configuration values and produce useful errors.

Do not enable interaction for the text-cell backend unless a behavior is explicitly supported there.

---

# 15. Commands and Mappings

Add commands equivalent to:

```text
:MdViewerCopy
:MdViewerClearSelection
:MdViewerFind [query]
:MdViewerFindNext
:MdViewerFindPrevious
:MdViewerFindClear
```

Add help and completion where appropriate.

Suggested preview behavior:

```text
mouse click       jump to source
mouse drag        select rendered text
double click      select rendered word
Ctrl/Cmd-click    activate safe link
y                 copy selected rendered text
/                 search rendered text
n                 next result
N                 previous result
Esc               clear find or selection
```

Preserve existing navigation mappings.

Avoid overriding user mappings without saving and restoring them.

---

# 16. Diagnostics

Extend:

```text
:MdViewerHealth
:MdViewerDebug
:checkhealth md-viewer
```

Report:

* Detected terminal profile.
* Detection evidence.
* Capability confidence.
* Selected image backend.
* Effective z-index.
* Platform.
* Browser executable.
* Multiplexer.
* Preview placement.
* Preview dimensions in cells.
* Chromium viewport dimensions in CSS pixels.
* Coordinate calibration status.
* Current content revision.
* Interaction enabled status.
* Selection state.
* Cached selection length.
* Active search query and match count.
* Last source-navigation precision.
* Interaction request counts.
* Coalesced drag events.
* Fast capture timing.
* Settled capture timing.
* Stale interaction count.
* Current document loaded in Chromium.

Do not expose selected private text in diagnostics.

---

# 17. Automated Tests

Add substantial Lua and Node coverage.

## 17.1 Lua tests

Test:

* Terminal-profile detection.
* Explicit terminal override.
* Capability-resolution precedence.
* Unknown-terminal fallback.
* Mouse press state.
* Click-versus-drag threshold.
* Forward drag.
* Reverse drag.
* Events outside previews.
* Events in excluded rectangles.
* Statusline and separator events.
* Mapping installation.
* Mapping restoration.
* Session cleanup.
* Cell-to-CSS coordinate conversion.
* Coordinate clamping.
* Resize behavior.
* Stale interaction callbacks.
* Separate render and interaction serials.
* Copy register behavior.
* `copy_on_select`.
* Source cursor byte-column clamping.
* Source synchronization guard.
* Link dispatch.
* Configuration validation.
* Health and debug fields.

## 17.2 Node tests

Test:

* `caretPositionFromPoint()` path.
* `caretRangeFromPoint()` fallback.
* Text-node hits.
* Element-boundary hits.
* Coordinates outside the article.
* Click source resolution.
* Exact source precision.
* Line fallback.
* Block fallback.
* UTF-16 to UTF-8 byte conversion.
* Emoji.
* Combining characters.
* CJK text.
* Tabs.
* Repeated text.
* Inline emphasis.
* Strong text.
* Inline code.
* Fenced code.
* Links.
* Entities.
* Lists.
* Tables.
* Blockquotes.
* Forward selection.
* Backward selection.
* Multi-block selection.
* Word selection.
* Selection text.
* Selection clearing.
* Selection persistence during capture.
* Search creation.
* Search next and previous.
* Search clearing.
* Fragment links.
* HTTP and HTTPS classification.
* Unsafe scheme rejection.
* Stale content revisions.
* Cross-document interactions.
* Document rehydration.
* Interaction screenshot results.
* Browser discovery on macOS, Linux, and Windows.

Use realistic Markdown fixtures.

## 17.3 Regression tests

Ensure all existing tests for these behaviors continue to pass:

* Initial rendering.
* Unsaved edits.
* Scroll-only captures.
* Fast and settled frames.
* Pinned previews.
* Source-to-preview cursor following.
* Local images.
* Security.
* Backend selection.
* Cleanup.
* Floating-window handling.
* Image placement.

---

# 18. Manual Compatibility Matrix

Expand manual testing instructions for:

```text
iTerm2
Kitty
WezTerm
Ghostty
Warp
```

Test:

* Initial image.
* Live edits.
* Unsaved edits.
* Source cursor following.
* Keyboard scrolling.
* Mouse-wheel scrolling.
* Click-to-source.
* Exact source columns.
* Line-level fallback.
* Forward selection.
* Backward selection.
* Multi-paragraph selection.
* Selection copying.
* Double-click word selection.
* Search.
* Link activation.
* Resize.
* Font-size changes.
* All split positions.
* Winbar.
* Statusline.
* Global statusline.
* Floating windows.
* Passive overlays.
* Tab switching.
* Suspend and resume.
* HiDPI.
* Standard DPI.
* Flicker.
* Cleanup.

Use honest statuses:

```text
Supported
Experimental
Protocol-compatible but unvalidated
Unsupported
```

Do not mark a terminal supported merely because its environment variable was recognized.

---

# 19. Documentation

Update:

```text
README.md
CHANGELOG.md
SECURITY.md
docs/architecture.md
docs/security.md
docs/manual-testing.md
docs/troubleshooting.md
doc/md-viewer.txt
```

Document this distinction prominently:

> The preview is still a browser-rendered PNG surface. Mouse and keyboard interactions are forwarded to the persistent Chromium DOM, which performs hit-testing, selection, search, and link resolution before the viewport is recaptured. This provides browser-like behavior but is not native terminal text selection or a real embedded webview.

Explain:

* Click versus drag behavior.
* Selection copying.
* Optional copy-on-select.
* Search.
* Safe link handling.
* Source-position precision levels.
* Unicode byte-column behavior.
* Terminal profiles.
* Explicit capability overrides.
* Browser discovery.
* Experimental terminal support.
* Multiplexer limitations.
* Security implications.

---

# 20. Acceptance Criteria

The implementation is complete only when all of the following are true:

1. The Kitty raw backend is no longer architecturally tied only to iTerm2.
2. Explicit profiles exist for iTerm2, Kitty, WezTerm, Ghostty, and Warp.
3. Terminal detection distinguishes explicit, verified, inferred, and unavailable support.
4. Unverified terminals are not falsely advertised as supported.
5. Chromium discovery works across macOS, Linux, and Windows.
6. Mouse positions are mapped from terminal cells to browser CSS coordinates without guessed pixel multiplication.
7. A click below the configured threshold navigates to Markdown source.
8. A drag above the threshold creates an actual Chromium DOM selection.
9. Dragging displays visible selection feedback.
10. Selection updates are coalesced and backpressured.
11. A settled high-resolution frame follows drag completion.
12. Selected text can be copied through `:MdViewerCopy`.
13. Copying writes to the unnamed register and `+` register when available.
14. Automatic copy-on-select is optional and disabled by default.
15. Exact source columns are returned only when inline provenance supports them.
16. Fallback navigation reports line or block precision honestly.
17. Neovim cursor columns are valid zero-based UTF-8 byte offsets.
18. Unicode tests pass.
19. Modifier-click safely activates approved links.
20. The hidden browser cannot navigate arbitrarily.
21. Rendered-text find supports set, next, previous, and clear.
22. Interaction requests reject stale content revisions.
23. Interaction with one document cannot affect another document.
24. Render, capture, and interaction stale-work handling do not incorrectly supersede each other.
25. Existing source-to-preview synchronization still works.
26. Existing scrolling performance remains intact.
27. Existing security defaults remain intact.
28. No HTTP server, WebSocket server, or listening port is added.
29. Existing tests pass.
30. New Lua and Node tests pass.
31. Health and debug output expose interaction and capability information.
32. Documentation distinguishes tested support from inferred compatibility.
33. Sixel is not added as an unrelated scope expansion.
34. tmux is not advertised unless implemented and tested.
35. The final implementation is formatted, linted, and reviewable.

---

# 21. Required Verification

Run the repository's existing setup and test commands, including:

```bash
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
```

Run any formatting, linting, type-checking, or additional test commands defined by the repository.

Fix failures introduced by the implementation.

Do not run `playwright install`.

If interactive graphical terminals are unavailable in the execution environment:

* Complete all automated implementation and testing.
* Add precise manual test instructions.
* Mark graphical combinations unvalidated.
* Do not claim visual success that was not observed.

---

# 22. Final Response Requirements

After completing the implementation, report:

1. Architecture changes.
2. Important files changed.
3. Terminal capability strategy.
4. Source-provenance strategy.
5. Coordinate-conversion strategy.
6. Click-versus-drag behavior.
7. DOM-selection implementation.
8. Copy behavior.
9. Search behavior.
10. Link security.
11. Unicode and byte-column handling.
12. Renderer queue and stale-work handling.
13. Commands and mappings added.
14. Tests run and exact results.
15. Terminals tested interactively.
16. Terminals still unvalidated.
17. Deferred work.
18. Any behavior that remains approximate.

Do not respond with only a plan, patch outline, or pseudocode.

Implement the best complete solution possible in the current repository.
