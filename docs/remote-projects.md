# Remote projects with a local Neovim

How to edit a project that lives on a remote machine from the Neovim on your
own machine — and why md-viewer renders at full local quality when you do.

This guide assumes you have never used remote Neovim buffers before. It uses
[remote-ssh.nvim](https://github.com/inhesrom/remote-ssh.nvim) because that is
what md-viewer's remote support was built and tested against; plain netrw
(`:e scp://…`) works with the same md-viewer machinery.

## The mental model to replace

The workflow you may know:

```sh
ssh dev-vm
cd ~/project
nvim .
```

That runs Neovim **on the VM**. The VM therefore needs Neovim, a copy of your
config, every plugin, Node and Chromium for md-viewer — and every rendered
preview frame has to travel back to your terminal through the SSH connection,
which is why scrolling over a slow link lags (see
[Remote sessions over SSH](../README.md#remote-sessions-over-ssh); that mode
still works and is still supported).

The workflow this guide sets up:

```sh
nvim        # on your own machine, your normal Neovim
```

and then, from inside Neovim, you open files that live on the VM. Neovim, your
config, your plugins, md-viewer, Node and Chromium all stay on your machine.
Only file contents cross the SSH connection.

> **Do not run `nvim` after SSHing into the VM for this workflow.** That is
> the old model. If Neovim is running on the VM, nothing on this page applies.

```
MY MACHINE
────────────────────────────────────────
iTerm2 / Kitty / Ghostty
  └── Neovim
       ├── my config and plugins
       ├── md-viewer.nvim
       │     └── Node renderer
       │           └── Chromium
       │                 └── PNG → my terminal   (never crosses SSH)
       └── remote-ssh.nvim
             │
             │ SSH — file contents only
             ▼
THE VM
────────────────────────────────────────
project files          (the source of truth)
language servers       (started over SSH by remote-ssh.nvim)
git, compilers, tests  (run them in a shell on the VM)
Docker, dev servers
```

## 1. What to install on your machine

- Neovim 0.12+, Node.js 22.12+, Chrome/Chromium/Edge, and md-viewer.nvim —
  the ordinary [installation](../README.md#installation). Under this workflow
  these live **only** on your machine.
- `ssh` (you already have it). md-viewer runs every remote command through
  it — argv only, never a local shell — and respects your `~/.ssh/config`,
  including `ProxyCommand` and `ControlMaster` settings.
- remote-ssh.nvim and its dependencies, added to your local plugin manager:

```lua
{
  "inhesrom/remote-ssh.nvim",
  branch = "master",
  dependencies = {
    "inhesrom/telescope-remote-buffer", -- fzf/telescope over opened remote buffers
    "nvim-telescope/telescope.nvim",
    "nvim-lua/plenary.nvim",
    "neovim/nvim-lspconfig",
    "rcarriga/nvim-notify",             -- recommended by upstream
  },
  config = function()
    require("telescope-remote-buffer").setup()
    -- Pass your usual on_attach/capabilities so remote LSP behaves like
    -- local LSP; see the remote-ssh.nvim README for filetype_to_server.
    require("remote-ssh").setup({})
  end,
}
```

remote-ssh.nvim is `v0.7.x-alpha`; its README warns that breaking changes are
possible. md-viewer does not call into it — it only recognizes the
`rsync://…`/`scp://…` buffers it creates — so a remote-ssh.nvim update cannot
break md-viewer's side of this.

## 2. What must exist on the VM

- `sshd`, plus the standard tools remote-ssh.nvim's health check requires:
  `python3`, `rsync`, `find`, `grep`, `stat`, `ls`.
- The language servers you want (e.g. `rust-analyzer`, `clangd`, `pyright`),
  installed on the VM — they run there.
- A POSIX login shell (bash, zsh, dash…). A fish login shell breaks the shell
  quoting both remote-ssh.nvim and md-viewer rely on.
- **Not** Neovim, not your config, not Node, not Chromium.

## 3. SSH keys and a host alias

Both plugins assume **passwordless key auth** — a password prompt has nowhere
to appear under a GUI-less job, so it fails instead. Set up once:

```sh
ssh-keygen -t ed25519          # if you have no key yet
ssh-copy-id alan@your-vm-host
```

Give the host an alias in `~/.ssh/config`, and (recommended) connection
multiplexing so each file operation reuses one SSH connection instead of
paying a fresh handshake:

```sshconfig
Host dev-vm
    HostName your-vm-host.example.com
    User alan
    IdentityFile ~/.ssh/id_ed25519
    ControlMaster auto
    ControlPath ~/.ssh/cm-%r@%h:%p
    ControlPersist 10m
```

Confirm `ssh dev-vm true` succeeds without prompting. Everything below uses
`dev-vm`.

## 4. Open a remote project

Start Neovim on your machine:

```sh
nvim
```

Open a file on the VM — the double-slash form means "absolute path on the
remote machine":

```vim
:RemoteOpen rsync://dev-vm//home/alan/project/README.md
```

Or browse the project tree and open files from it:

```vim
:RemoteTreeBrowser rsync://dev-vm//home/alan/project
```

(`j`/`k` to move, `Enter` to open, `q` to quit.) Plain `:e
rsync://dev-vm//home/alan/project/README.md` works too, and so does
`scp://…`. `:RemoteGrep rsync://dev-vm//home/alan/project` searches the
project on the VM.

The buffer you get is a normal Neovim buffer whose *name* is that URL. Your
keymaps, colorscheme and plugins that operate on buffer text all just work.

## 5. Preview it

```vim
:MdViewerToggle
```

Everything md-viewer does now happens on your machine: the Markdown text is
already in the local buffer, the local renderer lays it out, local Chromium
captures the PNG, and your terminal draws it. **No rendered pixel ever
crosses SSH**, so scrolling, selection, search and links feel exactly like a
local file — the SSH-session bandwidth reductions do not apply here because
there is nothing they would save.

The one thing that does cross SSH is the files your document references:

```markdown
![Architecture](./images/architecture.png)
```

`images/architecture.png` exists on the VM, so the first render shows a
placeholder for it while md-viewer copies it — once — into a private local
cache, then the preview updates. From then on, scrolling and editing re-use
the cached copy with **zero** remote traffic; md-viewer re-checks a cached
file (one cheap stat, no transfer) once per preview session, so an image you
regenerate on the VM is picked up the next time you open the preview.
Everything about the document itself — text, headings, code highlighting,
`https://` images — never needed the VM at all.

## 6. Where everything runs now

| Thing | Where | Notes |
|---|---|---|
| Neovim, your config, plugins | your machine | one config to maintain |
| md-viewer, Node, Chromium | your machine | full local quality |
| Rendered preview frames | your machine | never cross SSH |
| Project files | the VM | the source of truth |
| Saves (`:w`) | pushed to the VM | asynchronous — see below |
| LSP servers | the VM | remote-ssh.nvim proxies them over SSH |
| git, builds, tests, runtimes | the VM | **not automatic** — see below |
| Referenced images | copied VM → local cache | once each, off the render loop |

**Saves are asynchronous.** `:w` returns immediately and remote-ssh.nvim
pushes the buffer to the VM with `scp`/`rsync` in the background (it also
autosaves a few seconds after you stop typing; `async_write_opts.autosave =
false` turns that off). `BufWritePost` fires when the push completes, not
when you typed `:w`.

**Shell-tool plugins are the honest caveat.** remote-ssh.nvim does not
teleport processes: any plugin that shells out against the buffer's path —
gitsigns, a linter spawning `eslint`, a formatter spawning `prettier`,
`make`, `rg` from a fuzzy finder — runs on *your* machine and hands the tool
a literal `rsync://dev-vm/…` string it cannot open. Those integrations
silently do nothing (or error) on remote buffers. For project operations, use
what runs remotely: `:RemoteGrep` for searching, `:RemoteTui lazygit` or a
plain `ssh dev-vm` in another terminal for git, builds and tests.

## 7. Your dev server is a separate concern

md-viewer using your local Chromium does **not** mean your local browser can
reach a web app listening on the VM's `localhost:3000`. Those are unrelated:
md-viewer's Chromium renders Markdown from local bytes and is blocked from
all networking; reaching a remote dev server is ordinary SSH port
forwarding —

```sh
ssh -L 3000:localhost:3000 dev-vm
```

— then browse `http://localhost:3000` locally. No part of md-viewer needs
this, and nothing ever forwards Chrome's debugging protocol anywhere.

## 8. Day to day

- **Disconnect:** close the buffers or quit Neovim. There is no daemon and no
  session to tear down; unsaved changes you never wrote out are lost like any
  unsaved buffer, so `:w` first.
- **Reconnect tomorrow:** `nvim`, then the same `:RemoteOpen`/
  `:RemoteTreeBrowser` command (`:RemoteHistory` lists what you had open;
  `:RemoteSession dev-vm//home/alan/project` manages named sessions —
  upstream's README covers those).
- **Which kind of buffer am I in?** `:echo @%` — a remote buffer's name
  starts with `rsync://` or `scp://`. md-viewer's `:MdViewerDebug` prints a
  `Remote Document` section (host, project root, fetched-asset counts) for a
  remote preview and omits it for a local one.
- **A dropped connection** fails the operation that hit it (with ssh's own
  message) and nothing else; the preview keeps rendering the text it has.
  Reopen or `:e!` after the network returns.

## 9. If something does not work

- `:checkhealth remote-ssh` — upstream's own diagnosis (missing remote tools,
  auth problems).
- `:MdViewerDebug` — the `Remote Document` section shows the resolved remote
  project root, the connection state, and the root-walk error if there was
  one. `ssh session: no` is **correct** here: your Neovim is local; that line
  describes Neovim's own transport, not the document's origin.
- Images show placeholders naming a reason:
  - *file not found* — the path does not exist on the VM (or the fetch is
    still in flight for a second more).
  - *outside the document root* — the reference escapes the remote project
    root; that containment is deliberate and not configurable per document.
  - md-viewer refuses remote symlinked images outright — copying one would
    materialize whatever it points at, which is exactly what the symlink
    policy exists to prevent. Reference the real file instead.
- `ssh dev-vm true` hanging or prompting means keys are not set up
  (§3) — md-viewer runs ssh with `BatchMode=yes`, so where you would see a
  password prompt, it sees a clean failure naming the problem.
- [troubleshooting.md](troubleshooting.md) covers the rest, symptom by
  symptom.

## Limitations, honestly

- Single-slash URLs (`rsync://dev-vm/path`) are read as absolute paths, the
  way remote-ssh.nvim writes them; when the file is not found there,
  md-viewer retries relative to the remote `$HOME`, which is what netrw
  means by the same spelling. When in doubt, write the unambiguous
  double-slash absolute form.
- Only image files under the remote project root are fetched, only up to
  `render.max_local_image_bytes` each, and the local cache is bounded by
  `remote.cache_max_bytes` (256 MiB default). `remote.enabled = false`
  switches all of this off, and such buffers are then refused rather than
  mis-rendered.
- Ctrl/Cmd-clicking a link to another Markdown/text file on the VM opens it
  as another remote buffer and the preview follows. Links to non-text files
  (a PNG, a PDF) are refused in a remote document rather than fetched for the
  OS to open.
- A fish login shell on the VM breaks remote quoting (both for md-viewer and
  for remote-ssh.nvim). Windows-hosted Neovim is untested for this feature.
