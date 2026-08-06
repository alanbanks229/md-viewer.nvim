# Manual iTerm2 test checklist

Run directly in iTerm2 without tmux, with the production Neovim configuration
and `tests/fixtures/kitchen-sink.md`. Record the backend and attach screenshots
or a terminal recording where helpful. `PENDING` is not a pass.

Record each result as `PASS`, `FAIL`, or `BLOCKED`, with the exact environment.
Headless automation cannot inspect interactive terminal pixels, so it must not
be used to claim graphical parity.

| Scenario | Expected objective result | Result |
|---|---|---|
| `:MdViewerOpen` normal mode | Source remains editable; preview is in one Neovim split | PENDING |
| Cold renderer startup | Centered spinner animates, does not steal focus, and disappears with first frame | PENDING |
| Insert mode and unsaved edit | Preview changes after debounce without focus loss | PENDING |
| Command-line mode | Command line remains visible and image stays confined | PENDING |
| Completion menu | Menu remains visible above/without corruption | PENDING |
| Diagnostics float | Float remains readable | PENDING |
| Snacks notification | Opaque background; no Markdown leaks through; preview remains visible around it | PENDING |
| Telescope/floating picker | Picker remains readable; returning restores preview | PENDING |
| `:redraw!` | Image remains or is restored without stale copy | PENDING |
| Source focus and scrolling | Mapped block follows without redundant within-block render | PENDING |
| Preview focus and scrolling | Viewport moves and source sync has no loop | PENDING |
| Preview Vim motions | `j/k`, Ctrl-d/u, Ctrl-f/b, `gg/G` move only the browser viewport | PENDING |
| Preview mouse wheel | Wheel over preview scrolls it; wheel elsewhere keeps normal Neovim behavior | PENDING |
| Scroll performance | Moving frame responds promptly; a sharper frame replaces it once after settling | PENDING |
| Scroll past end | Final rendered block can reach the preview top with viewport-sized blank space below | PENDING |
| Browse another source file | Preview stays pinned, labeled with its Markdown filename, and remains visible | PENDING |
| Split resizing | Origin and cell size update; no separator/statusline overlap | PENDING |
| macOS/iTerm2 window resize | Placement and PNG dimensions update | PENDING |
| Winbar/statusline/global statusline | All decorations remain visible | PENDING |
| Tab switch and return | Image disappears off-tab and returns in the correct split | PENDING |
| Suspend and resume | No stale image; renderer/preview recover | PENDING |
| Multiple Markdown buffers | Sessions, scroll state, and images do not mix | PENDING |
| Preview close and reopen repeatedly | No owned IDs, files, or browser processes leak | PENDING |
| Neovim exit | No image or Node/Chromium process remains | PENDING |
| External UI audit | No browser window, GUI, terminal pane, or localhost listener appears | PENDING |

Also run the replacement loop from [feasibility.md](feasibility.md) and observe
flicker and terminal memory for at least five minutes. Test tmux only as optional
information; it is not a version-one requirement.
