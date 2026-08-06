# `md-viewer.nvim`: Cross-Terminal and VS Code-Like Preview Feasibility Report

**Project:** `alanbanks229/md-viewer.nvim`
**Current release:** `v0.1.0-beta`
**Assessment date:** August 5, 2026

## Executive Summary

`md-viewer.nvim` has strong potential to become a cross-terminal, browser-quality Markdown previewer for Neovim.

Its current architecture is unusually well positioned for this:

* Markdown is rendered by a persistent headless Chromium page.
* Unsaved Neovim buffer contents are sent directly to the renderer.
* Chromium performs real HTML, CSS, layout, and syntax highlighting.
* Only the visible browser viewport is captured.
* The resulting PNG is placed inside a normal Neovim split using the Kitty graphics protocol.
* Source token ranges are already mapped to measured DOM geometry.
* The project already supports source-to-preview cursor synchronization.
* The renderer and Neovim communicate through a persistent local NDJSON process.
* No HTTP server, WebSocket server, localhost listener, or external browser window is required.

The project can plausibly support iTerm2, Kitty, WezTerm, Ghostty, and Warp because those terminals implement the Kitty graphics protocol.

However, protocol implementation alone does not guarantee identical behavior. The remaining cross-terminal work is concentrated in:

* Terminal capability detection.
* Placement semantics.
* Z-index behavior.
* Cell and pixel geometry.
* Image replacement and deletion.
* Floating-window interaction.
* Browser executable discovery.
* Interactive testing.

The larger limitation is interaction.

The visible preview is currently a PNG. Once the Chromium DOM is converted into an image, the terminal receives pixels rather than text nodes, links, ranges, or browser events. Native browser text selection therefore cannot be provided by the Kitty graphics protocol alone.

A convincing VS Code-like experience is nevertheless possible by forwarding terminal input back into the persistent Chromium page. Chromium can perform hit-testing, create real DOM selections, return selected text, activate links, perform search, and produce a new screenshot containing the browser-generated highlights.

This would be synthetic browser interaction over a raster surface rather than a real embedded webview, but it could provide most of the behavior users perceive as important.

---

## Current Rendering Architecture

The current rendering path is approximately:

```text
Markdown buffer
      |
      v
Neovim Lua controller
      |
      | NDJSON over stdin/stdout
      v
Persistent Node.js renderer
      |
      v
Persistent headless Chromium page
      |
      v
HTML/CSS layout and syntax highlighting
      |
      v
Viewport-sized PNG screenshot
      |
      v
Kitty graphics protocol
      |
      v
Image placed inside a Neovim preview split
```

This architecture provides several important advantages:

1. **Browser-quality rendering**

   Markdown is ultimately laid out by Chromium rather than approximated with terminal text cells.

2. **Unsaved-buffer support**

   The preview can render the current in-memory Neovim buffer without requiring a file save.

3. **Persistent rendering state**

   Chromium, its browser context, and its page remain alive while previews are active.

4. **Efficient scrolling**

   Scroll-only updates can reuse the existing DOM and recapture only the visible viewport.

5. **Source mapping**

   Markdown token ranges are annotated and measured in the browser, allowing source lines to map to rendered blocks.

6. **Security isolation**

   The renderer does not need a network-facing server, and browser network access is disabled by default.

This is a stronger foundation for VS Code-like behavior than a plugin that simply invokes a Markdown-to-image command for every update.

---

## Cross-Terminal Potential

The Kitty graphics protocol is implemented by the terminals under consideration, but each implementation must be tested for the exact operations used by `md-viewer.nvim`.

| Terminal |        Potential | Current status                                                                                                                                 |
| -------- | ---------------: | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| iTerm2   |        Very high | Current supported target. Existing placement, negative z-index, and overlay behavior are tuned for direct iTerm2 use.                          |
| Kitty    |        Very high | Reference implementation of the protocol. It is a natural second target, but the current detector and platform assumptions still require work. |
| WezTerm  |             High | Implements Kitty graphics. Placement, z-index, deletion, scaling, and resize behavior need direct validation.                                  |
| Ghostty  |             High | Implements Kitty graphics and aims for protocol compatibility. It still needs a dedicated profile and graphical testing.                       |
| Warp     | Moderate to high | Supports Kitty images on macOS and Linux. Its block-oriented terminal UI and environment detection require specific testing.                   |

The transport format is therefore broadly portable.

The current implementation is not yet broadly portable because it includes assumptions around:

* Recognized terminal environment variables.
* iTerm2-specific z-index behavior.
* Direct use without tmux.
* macOS Chromium installation paths.
* Estimated terminal cell dimensions.
* Placement behavior around Neovim UI elements.
* The absence of a safely confirmed runtime protocol probe.

---

## Why Shared Protocol Support Is Not Enough

Two terminals can implement the same image protocol while differing in behavior important to a Neovim preview.

Potential differences include:

* Whether negative z-index places images beneath text but above terminal backgrounds.
* Whether images survive cell repainting.
* Whether replacing an image produces flicker.
* Whether deleting an image also removes its placements.
* Whether placement IDs are handled consistently.
* How source-image cropping is interpreted.
* How images interact with alternate-screen transitions.
* How images react to font-size changes.
* Whether tab bars or pane padding affect coordinates.
* How HiDPI scaling is handled.
* How rapidly repeated placements are rendered.
* Whether a terminal has image-memory limits.
* How a terminal behaves when Neovim creates floating windows.

A real compatibility layer should therefore model terminal capabilities rather than simply checking whether `$TERM` contains a particular word.

---

## Cross-Terminal Work Still Needed

### 1. Terminal capability abstraction

Terminal detection should be moved into a dedicated module.

The module should distinguish among:

* Explicitly configured support.
* Runtime-verified support.
* Environment-inferred support.
* Unknown support.
* Unsupported environments.

It should expose profiles for:

* iTerm2
* Kitty
* WezTerm
* Ghostty
* Warp
* Generic Kitty-compatible terminals

Each profile should provide relevant defaults and warnings.

The raw image encoder should remain generic. Terminal-specific placement policy should live in the profile layer.

### 2. Safe capability probing

The Kitty protocol defines a graphics query that can be followed by a primary-device-attributes query to determine whether the terminal answered the graphics request.

The complication is that Neovim owns terminal input. A naïve synchronous probe could consume or corrupt normal input.

A safe implementation must not pretend that the probe succeeded based only on a terminal name.

A practical strategy is:

1. Respect an explicit user override.
2. Prefer a verified Neovim image API when available.
3. Attempt a safe asynchronous graphics query only where reliable.
4. Fall back to conservative terminal-profile inference.
5. Fall back to the text-cell renderer when confidence is insufficient.

Health output should state exactly how the capability was determined.

### 3. Terminal-specific placement profiles

The current negative z-index behavior works for the supported iTerm2 configuration.

Other terminals may require:

* A different z-index.
* Different replacement ordering.
* Different deletion behavior.
* Additional redraws after resize.
* Placement recreation after alternate-screen transitions.
* Different handling when a floating window overlaps the image.

These differences should be configuration data rather than forks of the complete backend.

### 4. Coordinate and geometry reliability

The plugin must convert among several coordinate spaces:

```text
Terminal screen cells
        |
        v
Neovim preview-window cells
        |
        v
Image-placement cells
        |
        v
Chromium CSS viewport pixels
        |
        v
Screenshot source pixels
```

Exact physical terminal-cell dimensions are useful for image quality, but interactive hit-testing can rely primarily on normalized geometry.

For example:

```text
cssX = relativePreviewColumn / previewWidthCells * viewportWidthPx
cssY = relativePreviewRow / previewHeightCells * viewportHeightPx
```

This allows terminal-cell mouse events to map into browser coordinates even when the exact Retina pixel size of each terminal cell is unknown.

The conversion must still account for:

* One-based versus zero-based coordinates.
* Winbars.
* Statuslines.
* Tablines.
* Global statuslines.
* Split separators.
* Command-line rows.
* Cropped image placements.
* Overlapping floating windows.

### 5. Cross-platform Chromium discovery

The current renderer primarily searches standard macOS application locations.

A cross-platform implementation should find existing Chromium-family browsers without downloading one.

It should support:

#### macOS

* Google Chrome
* Chromium
* Microsoft Edge
* Explicit executable paths
* Common package-manager locations where appropriate

#### Linux

* `google-chrome`
* `google-chrome-stable`
* `chromium`
* `chromium-browser`
* `microsoft-edge`
* `microsoft-edge-stable`
* Explicit executable paths

#### Windows

* `PATH`
* Chrome installation directories
* Edge installation directories
* `PROGRAMFILES`
* `PROGRAMFILES(X86)`
* `LOCALAPPDATA`
* Explicit executable paths

The project should continue avoiding `playwright install` and automatic browser downloads.

### 6. Terminal test matrix

Automated tests can validate protocol encoding, state management, coordinate conversion, and browser behavior.

They cannot fully validate:

* Correct image pixels.
* Z-index composition.
* Flicker.
* Float overlay behavior.
* HiDPI sharpness.
* Terminal-specific resize behavior.

A repeatable manual matrix is necessary before each terminal is described as fully supported.

Suggested status labels are:

* Supported
* Experimental
* Protocol-compatible but unvalidated
* Unsupported

---

## The Raster Boundary

The most important architectural boundary is:

```text
Chromium DOM
      |
      | screenshot
      v
PNG pixels
```

Before the screenshot, Chromium has:

* Text nodes.
* Elements.
* Links.
* Selection ranges.
* Layout rectangles.
* Accessibility information.
* Browser find behavior.
* Pointer hit-testing.
* Scroll state.

After the screenshot, the terminal has only pixels.

The Kitty graphics protocol can transmit and place those pixels, but it does not transmit:

* DOM nodes.
* Selectable text.
* Hyperlink targets.
* Browser events.
* Caret positions.
* Accessibility semantics.
* Input focus.
* Context menus.
* IME state.

This means native browser selection cannot be added merely by improving the Kitty image backend.

---

## How VS Code-Like Selection Can Be Simulated

The persistent Chromium page makes a strong synthetic interaction layer possible.

A text-selection interaction could work as follows:

```text
1. User presses inside the preview.
2. Neovim captures the terminal mouse position.
3. Lua converts the position into Chromium CSS coordinates.
4. Lua sends a selection-begin request to Node.
5. Playwright performs DOM caret hit-testing.
6. Chromium creates a Range and Selection.
7. Drag events update the selection focus.
8. Chromium paints the selection highlight.
9. The renderer captures a new viewport screenshot.
10. The Kitty backend replaces the preview image.
11. A copy command retrieves window.getSelection().toString().
12. Lua writes the selected text into Neovim clipboard registers.
```

Relevant browser APIs include:

* `document.caretPositionFromPoint()`
* `document.caretRangeFromPoint()`
* `document.elementFromPoint()`
* `document.createRange()`
* `window.getSelection()`

The user would see a normal Chromium selection highlight because the browser itself created and painted the selection before the screenshot was taken.

This would not be native terminal selection, but it would provide the key user-facing behaviors:

* Press-and-drag selection.
* Highlighted selected text.
* Copying rendered text.
* Word selection on double click.
* Potential paragraph selection on triple click.
* Selection across inline formatting.
* Selection inside code blocks.
* Selection that survives scroll-only screenshot updates.

---

## Interaction Performance

Capturing a full Retina screenshot for every mouse movement would be unnecessarily expensive.

The existing two-stage scrolling pipeline provides a suitable model:

1. During pointer movement, coalesce events.
2. Allow only one moving capture in flight.
3. Retain only the newest pending pointer position.
4. Capture at CSS scale or reduced resolution.
5. Display each current frame.
6. After release or a short idle period, capture one full device-scale frame.

This should make synthetic selection responsive without abandoning browser-quality settled output.

The same backpressure rules already used for preview scrolling should be reused for selection.

---

## Neovim Mouse Handling Required

The current mouse layer primarily dispatches wheel events.

Interactive selection would require handling:

* `<LeftMouse>`
* `<LeftDrag>`
* `<LeftRelease>`
* `<2-LeftMouse>`

The event should only be intercepted when the pointer is over an active graphical preview.

Events outside the preview should retain their original behavior.

The implementation must:

* Save existing user mappings.
* Restore them when no graphical previews remain.
* Maintain per-preview drag state.
* Use screen-relative mouse coordinates.
* Avoid treating the preview’s one-line scratch buffer as the rendered document.
* Clear interaction state when a preview closes or a tab changes.

---

## Copying Preview Text

A command such as:

```text
:MdViewerCopy
```

could request the current browser selection text and place it in:

* The unnamed Neovim register.
* The `+` clipboard register when clipboard support is available.

A preview-local `y` mapping would provide a familiar workflow.

This produces the same copied characters the browser selected, even though the terminal itself still sees an image.

---

## Browser-Backed Search

The persistent DOM also makes rendered-preview search possible.

Potential commands include:

```text
:MdViewerFind
:MdViewerFindNext
:MdViewerFindPrevious
:MdViewerFindClear
```

The renderer can find matching text nodes, create ranges for matches, add safe highlight elements or CSS-backed markers, scroll the active match into view, and capture the result.

Preview-local mappings could mirror common editor behavior:

```text
/    enter search
n    next result
N    previous result
Esc  clear search or selection
```

Search should operate on rendered text rather than raw Markdown syntax.

---

## Preview-to-Source Navigation

The project already has much of the required foundation:

* Markdown tokens carry source ranges.
* The renderer measures corresponding DOM geometry.
* Source lines can map to rendered blocks.
* A preview-to-source synchronization function already exists.
* A synchronization guard prevents feedback loops.

The next step is to connect pointer hit-testing to source metadata.

Double-clicking rendered text could:

1. Hit-test the DOM element or text node.
2. Identify its most specific source range.
3. Return the source line to Lua.
4. Move the source cursor.
5. Preserve the synchronization guard.

This would closely resemble VS Code’s rendered-preview-to-source navigation.

---

## Links

Rendered links can also be made interactive.

The hidden browser page should not be allowed to navigate away from the controlled Markdown document.

Instead, Chromium can return link metadata to Lua.

Lua can then handle links according to type:

* Fragment links scroll inside the current Chromium document.
* `http` and `https` links open through `vim.ui.open()` after an explicit click.
* `mailto` links may use `vim.ui.open()`.
* Local file links remain constrained to the document root.
* Unsafe schemes such as `javascript:` are rejected.

This preserves the existing security boundary while providing useful interaction.

---

## Security Considerations

Interactive behavior should not weaken the project’s current security defaults.

The implementation should preserve:

* No HTTP server.
* No WebSocket server.
* No listening network port.
* Runtime browser network requests blocked.
* Restrictive Content Security Policy.
* Markdown-provided JavaScript disabled.
* Raw HTML disabled by default.
* Remote images removed.
* Local images constrained to the document root.
* Canonical-path and symlink validation.
* File signature and size validation.

Playwright `page.evaluate()` is trusted renderer code and can manipulate the internal DOM without enabling arbitrary JavaScript from Markdown.

Link activation should remain an explicit operation with scheme validation.

---

## Raster Interaction Versus a Real Webview

There are two possible long-term product directions.

### Direction A: Cross-terminal raster preview

This is the natural continuation of the current project.

It can provide:

* Broad terminal compatibility.
* Browser-quality Markdown rendering.
* CSS themes.
* Syntax highlighting.
* Source synchronization.
* Synthetic text selection.
* Copying.
* Search.
* Clickable links.
* Double-click source navigation.
* No external browser window.
* No local web server.

Its unavoidable limitations include:

* Selection is not the terminal’s native selection.
* Drag updates require browser round trips and screenshot replacement.
* Screen readers do not receive the rendered DOM.
* Browser context menus are unavailable.
* IME and editable-browser behavior are not present.
* Pixel-level mouse precision may be limited to terminal cells.

### Direction B: Real embedded webview

A true webview would provide native:

* DOM text selection.
* Browser context menus.
* Accessibility semantics.
* Browser focus.
* Fine-grained pointer input.
* IME behavior.
* Link and form interaction.

However, a real webview is not part of the Kitty graphics protocol.

It would require:

* A terminal-specific embedded browser API.
* A Neovim GUI frontend with webview support.
* A sidecar browser window.
* An iTerm2 browser pane.
* A custom application hosting both Neovim and a browser view.

That path would sacrifice the project’s terminal portability.

---

## Recommended Roadmap

### Phase 1: Portable rendering

1. Introduce terminal profiles and capability resolution.
2. Remove iTerm2-specific assumptions from the generic Kitty encoder.
3. Add explicit Kitty, WezTerm, Ghostty, and Warp profiles.
4. Add macOS, Linux, and Windows browser discovery.
5. Improve health and debug diagnostics.
6. Add geometry and terminal-profile unit tests.
7. Create a manual terminal compatibility matrix.
8. Keep untested terminals marked experimental.

### Phase 2: Preview interaction foundation

1. Add normalized preview-cell-to-browser-coordinate conversion.
2. Extend the NDJSON protocol with interaction requests.
3. Add DOM hit-testing.
4. Implement click and double-click handling.
5. Enable preview-to-source navigation.
6. Add safe link activation.

### Phase 3: Synthetic text selection

1. Add press, drag, and release mouse handling.
2. Create browser DOM selections.
3. Reuse the fast low-resolution capture pipeline during dragging.
4. Capture a settled Retina frame after release.
5. Add `:MdViewerCopy`.
6. Preserve selection through scroll-only captures.
7. Clear or invalidate selection after content changes.

### Phase 4: Browser-backed find

1. Add rendered-text search.
2. Highlight all matches safely.
3. Track the active match.
4. Add next, previous, and clear commands.
5. Add preview-local `/`, `n`, and `N` mappings.

### Phase 5: Compatibility hardening

1. Test every advertised terminal directly.
2. Validate HiDPI and standard-DPI displays.
3. Validate all split positions.
4. Validate floating windows and UI overlays.
5. Validate font-size changes and resizes.
6. Investigate tmux passthrough separately.
7. Add regression tests for terminal-specific workarounds.

---

## Definition of Success

A strong next version would allow a user to:

1. Open a Markdown file in terminal Neovim.
2. Open a browser-quality preview in an adjacent Neovim split.
3. Edit unsaved Markdown and see live updates.
4. Move the source cursor and see the preview follow.
5. Scroll the preview with keyboard or mouse.
6. Drag over rendered text and see Chromium selection highlighting.
7. Copy the selected rendered text.
8. Double-click rendered content to jump to Markdown source.
9. Search rendered text with next and previous navigation.
10. Open safe links.
11. Use the same plugin in multiple Kitty-compatible terminal emulators.

The plugin should describe this accurately as browser-backed interaction over a raster preview rather than a native webview.

---

## Final Assessment

`md-viewer.nvim` is already architecturally close to being a compelling terminal-native alternative to VS Code’s Markdown preview.

Its use of a persistent Chromium page is the decisive advantage. The browser DOM still exists after rendering, so the project does not need to reconstruct Markdown semantics from image pixels. It only needs to forward user interaction back to the browser and recapture the result.

The Kitty graphics protocol can provide the portable display surface across iTerm2, Kitty, WezTerm, Ghostty, and Warp.

It cannot independently provide native selectable browser text.

The best realistic target is therefore:

> A cross-terminal, Chromium-rendered Markdown preview with synthetic DOM interaction, source synchronization, copying, search, links, and browser-quality visual fidelity.

That could reproduce most of the practical VS Code Markdown preview experience while preserving the project’s defining qualities: terminal operation, Neovim integration, unsaved-buffer rendering, local processing, and no external browser window.
