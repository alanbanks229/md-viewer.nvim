# Usage

A quick reference for commands, keys, and mouse gestures. For more detail, use
`:help md-viewer` inside Neovim.

| Command | Action |
|---|---|
| `:MdViewerToggle [position]` | Open or close the preview (`right`, `left`, `below`, `above`) |
| `:MdViewerCopy` | Copy the current selection |
| `:MdViewerFind [query]` | Search the preview; prompts if no query is given |
| `:MdViewerFindNext` / `:MdViewerFindPrevious` | Move to the next or previous match |
| `:MdViewerBack` / `:MdViewerForward` | Move through followed-link history |
| `:MdViewerTabNext` / `:MdViewerTabPrevious` | Cycle document tabs in the preview pane |
| `:MdViewerTabClose` | Close the active preview document tab |
| `:MdViewerRevealSource` | Show the active preview document in the source pane and focus it |
| `:MdViewerToggleAbsoluteLineNumbers` | Toggle line numbers in the preview |
| `:MdViewerToggleRelativeLineNumbers` | Toggle relative line numbers in the preview |
| `:MdViewerHealth` | Show whether md-viewer is ready and explain any problems |
| `:MdViewerDebug` | Full diagnostic — attach this to a bug report |
| `:MdViewerMeasureLink` | Measure this SSH link's speed once, and cache it for this machine |
| `:checkhealth md-viewer` | Run Neovim health checks |

For statusline integration, see `:help md-viewer-statusline`.

## Rendering modes

Normal mode is right for most users. The two experimental modes are only for slow remote connections.

| Mode | What it does | Turn it on with |
|---|---|---|
| **Normal** (default) | Takes a new screenshot as you move through the document. | Nothing |
| **Local rendering** — *experimental* | Runs the browser beside your terminal so screenshots do not cross the SSH connection. | Set `render.location = "local"` and start the helper. See `:help md-viewer-local`. |
| **Resident** — *experimental* | Loads the whole document into the terminal first, then scrolls without sending more screenshots. Opening a preview may take longer and use more terminal memory. Not available on iTerm2 or WezTerm. | Set `image.resident = "auto"`, then run `:MdViewerMeasureLink` once on each machine. See `:help md-viewer-resident`. |

Do not enable both experimental modes. Local rendering takes priority and turns
resident mode off.

Resident `"auto"` only activates on a supported terminal and a measured slow
connection. If the connection has not been measured, normal mode is used.

## Animated images

GIF and WebP images appear as still pictures by default. To play them:

```lua
require("md-viewer").setup({
  render = { animate = true },
})
```

Animation depends on terminal support and stays off in resident and local
rendering modes. Run `:MdViewerHealth` if an image remains still.

## Keys, with the preview focused

The preview has its own caret, which moves through the rendered document.

| Key | Action |
|---|---|
| `h` `l`, left/right arrows | Move by one character |
| `j` `k`, up/down arrows | Move by one rendered line |
| `0` `$` | Start and end of the rendered line |
| `w` `b` `e` | Next word, previous word, end of word |
| `{` `}` | Previous / next block |
| `Ctrl-d` `Ctrl-u` `Ctrl-f` `Ctrl-b` | Half a page, a page |
| `PageDown` `PageUp` | A page |
| `Ctrl-e` `Ctrl-y` | Scroll the view, leaving the caret where it is |
| `gg` `G` | Start and end of the document |
| `v` | Start or finish a character selection |
| `V` | Start or finish a line selection |
| `Ctrl-V` | The same as `v` |
| `gv` | Does nothing in the preview |
| `o` | Swap the ends of a selection |
| `y` | Copy the selection |
| `Esc` | Clear the search, then the selection |
| `/` `n` `N` | Search, next match, previous match |
| `H` `L` `[b` `]b` | Move between preview tabs. `H`/`L` are configurable with `interaction.keymaps` |
| `gf` | Reveal this preview document in the editable source pane |

Counts work on every motion except `gg` and `G`: for example, `10j`, `5w`, or
`3l`.

The winbar shows `-- VISUAL --` while selecting text.

## Mouse

The mouse never highlights text — only `v`/`V` and the motion keys above do
that. What the mouse still does:

| Gesture | Action |
|---|---|
| Plain click | Places the caret; clears an active selection; never moves the source cursor |
| Ctrl-click / Cmd-click | Activates a link under the pointer |
| Scroll wheel | Scrolls the preview |

Selections are copied only when you press `y` or run `:MdViewerCopy`. To copy
automatically, set `interaction.copy_on_select = true`.

**`:help md-viewer` is the complete reference** for every command, key, gesture,
and interaction semantic.
