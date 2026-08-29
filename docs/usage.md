# Usage

Every command, key and mouse gesture. `:help md-viewer` is the same material
inside Neovim, with the full semantics of each.

| Command | Action |
|---|---|
| `:MdViewerToggle [position]` | Open or close the preview (`right`, `left`, `below`, `above`) |
| `:MdViewerCopy` | Copy the current selection |
| `:MdViewerFind [query]` | Search the rendered preview; prompts if no query is given. Moves the caret onto the match |
| `:MdViewerFindNext` / `:MdViewerFindPrevious` | Step through matches, moving the caret onto each one |
| `:MdViewerBack` / `:MdViewerForward` | Move through followed-link history |
| `:MdViewerTabNext` / `:MdViewerTabPrevious` | Cycle document tabs in the preview pane |
| `:MdViewerTabClose` | Close the active preview document tab |
| `:MdViewerRevealSource` | Show the active preview document in the source pane and focus it |
| `:MdViewerToggleAbsoluteLineNumbers` | Show absolute rendered visual-line numbers; repeat to turn them off |
| `:MdViewerToggleRelativeLineNumbers` | Show caret-relative visual-line numbers; repeat to turn them off |
| `:MdViewerHealth` | Short status: is this set up to work, and if not, why |
| `:MdViewerDebug` | Full diagnostic — attach this to a bug report |
| `:MdViewerMeasureLink` | Measure this SSH link's speed once, and cache it for this machine |
| `:checkhealth md-viewer` | Run Neovim health checks |

Statusline integrations can call `require("md-viewer").statusline_progress()`.
It returns `All`, `Top`, `Bot`, or `NN%` for the active graphical preview and
`nil` elsewhere. The `User MdViewerProgressChanged` event fires only when that
label changes. See `:help md-viewer-statusline`.

## Rendering modes

There are three ways a preview can actually get pixels onto your screen. One
is always on; the other two are off by default and you turn them on yourself.

| Mode | What it does | Turn it on with |
|---|---|---|
| **Normal** (the default) | Every time you scroll, it takes a fresh screenshot and sends that picture to your terminal. Simple, and what you get with no configuration. | Nothing — this is what you already have |
| **Resident** — *experimental* | Screenshots the *whole document* once, up front (a short "warm-up"), then scrolling just tells the terminal "show a different part of the picture you already have" instead of taking a new screenshot each time. Not available on iTerm2 or WezTerm — see `:help md-viewer-resident`. | `image.resident = "auto"` **plus** `:MdViewerMeasureLink` once on that machine — `:help md-viewer-resident` |
| **Local rendering** — *experimental* | Runs the browser on the machine your terminal is on instead of the remote one, so screenshots never travel over SSH at all. Requires a helper program running on that machine. | `render.location = "local"` — `:help md-viewer-local` |

Both experimental modes exist to fix the same problem — a slow SSH/SSM
connection making scrolling feel laggy — just in different ways. **You can
only have one active at a time**: if local rendering is on, it always wins
and resident mode is switched off automatically, even if you configured both.

**How to tell which one is currently running:** run `:MdViewerDebug` and look
at the `render_path` field — it reads `resident` or `viewport` (`viewport` is
the normal, default mode). If you never configured `image.resident` or
`render.location` yourself, you're on the normal mode.

**Resident mode asks about your connection, not just your terminal.** `"auto"`
turns it on only where the terminal supports it *and* this machine has measured
a link under 4 MB/s, because the warm-up is a cost you pay on every connection
and only a slow one pays it back. It never measures on its own, so on a machine
where you have not run `:MdViewerMeasureLink`, `"auto"` stays off and
`render_path_reason` says `link speed unknown`. Run that command once per
machine. `image.resident = "on"` skips the question entirely — useful for trying
the mode out on a fast machine, not something to leave on there.

If you turn resident mode on, watch for `warming N/N` in the winbar right
after opening a preview — that's the one-time, whole-document screenshot
happening. It only appears in resident mode, and on a fast connection it can
finish in under a second, so it's easy to miss.

## Keys, with the preview focused

The preview has a real caret. It is a position in the rendered document rather
than a terminal cell, so it only ever sits on an actual character and is drawn
the size of the glyph it is on.

| Key | Action |
|---|---|
| `h` `l` `j` `k`, arrows | One character; one rendered line, holding its column |
| `0` `$` | Start and end of the rendered line |
| `w` `b` `e` | Next word, previous word, end of word |
| `{` `}` | Previous / next block |
| `Ctrl-d` `Ctrl-u` `Ctrl-f` `Ctrl-b` | Half a page, a page |
| `PageDown` `PageUp` | A page |
| `Ctrl-e` `Ctrl-y` | Scroll the view, leaving the caret where it is |
| `gg` `G` | Start and end of the document |
| `v` `V` | Start a selection at the caret, or end one; line-wise |
| `Ctrl-V` | The same as `v` — Neovim's blockwise Visual is mapped away, because over blank cells it would paint a rectangle across the picture |
| `gv` | Reserved, and does nothing: there is no previous Neovim selection to restore here |
| `o` | Swap the ends of a selection |
| `y` | Copy the selection |
| `Esc` | Clear the search, then the selection |
| `/` `n` `N` | Search, next match, previous match. Each moves the caret onto the match, so `v`/`y`/a motion key acts from there |
| `H` `L` `[b` `]b` | Previous / next document tab in the preview pane. `H`/`L` are configurable (`interaction.keymaps`); `[b`/`]b` are always mapped |
| `gf` | Reveal this preview document in the editable source pane |

Counts work on every motion except `gg`/`G` — `10j`, `5w`, `3l`.

Neovim stays in Normal mode throughout: `v` extends a real DOM selection using
the motions above, because Neovim's own Visual mode would only select the blank
cells the picture is drawn over. The winbar shows `-- VISUAL --` in its place.

## Mouse

The mouse never highlights text — only `v`/`V` and the motion keys above do
that. What the mouse still does:

| Gesture | Action |
|---|---|
| Plain click | Places the caret; clears an active selection; never moves the source cursor |
| Ctrl-click / Cmd-click | Activates a link under the pointer |
| Scroll wheel | Scrolls the preview |

Copying is manual by default — nothing reaches your clipboard on selection
unless you ask for it with `y` or `:MdViewerCopy`. Set
`interaction.copy_on_select = true` to copy on every selection change instead.

**`:help md-viewer` is the complete reference** for every command, key, gesture,
and interaction semantic.
