# Operator Guide — Exactly What To Do, Step By Step

Plain-language runbook. Every command you type is in a box. Do them in order.

Project root, referred to below as `$REPO`:

```text
~/Documents/Github/Neovim_Plugins/md-viewer.nvim
```

---

## About switching models mid-session

You raised this, and it's worth settling up front: **you can switch models in the
middle of a Claude Code session** with `/model`. The conversation — including an
approved plan — stays in context. So the "plan with Opus, implement with Sonnet"
handoff does work.

Two things to know:

- `/model` also saves your pick as the default for *new* sessions. Set it back
  when you're done with a part.
- The plan's context carries into Sonnet's window, so you pay for it twice. On a
  short plan that's nothing; on a long one it's real.

**If the switching feels fiddly, just run the whole part on Opus.** It costs more
but it's one less thing to get wrong. This only affects Part 3 — Part 5 is Opus
start to finish anyway.

---

## Before you start anything

### 1. Confirm where you are

```bash
cd ~/Documents/Github/Neovim_Plugins/md-viewer.nvim
git status
git branch --show-current
```

You should be on `feat/cross-platform-markdown-preview`.

### 2. Commit the planning files

They're untracked right now. Get them in git before anything else — the whole
point is that they survive a lost session.

```bash
git add prompts/ .gitignore
git commit -m "docs: add phased cross-platform implementation plan"
```

### 3. Make sure the project builds and tests pass right now

```bash
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts --prefix renderer
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
```

Both test commands must pass **before** you start Part 1. If they don't, fix that
first — otherwise you won't know whether Part 1 broke something or it was already
broken.

### 4. Optional: install stylua

CI will start checking formatting in Part 1. Nice to have locally:

```bash
brew install stylua
```

---

## PART 1 — Foundations

**Model:** Sonnet 5 &nbsp;&nbsp;|&nbsp;&nbsp; **Plan mode:** no

### Do this

```bash
cd ~/Documents/Github/Neovim_Plugins/md-viewer.nvim
claude
```

In the session:

```text
/model
```
→ pick **Sonnet 5**

```text
/clear
```

Then paste this as your prompt:

```text
Read prompts/00-policy.md and prompts/part-1-foundations.md, then implement Part 1.
```

Let it run. It will ask permission for edits and commands — approve them.

### When it says it's done

Check the work yourself. In a **separate terminal tab**:

```bash
cd ~/Documents/Github/Neovim_Plugins/md-viewer.nvim
git log --oneline -1
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
```

You want to see:
- A commit whose subject ends in `part 1/7 - capability and browser foundation`
- Both test commands passing
- `prompts/README.md` showing Part 1 as `done` with the commit hash
- `docs/cross-platform-implementation-status.md` now exists

### Then do this yourself

Open a Markdown file in Neovim and check the new health output:

```text
:MdViewerHealth
```

Read it. It should now tell you which terminal it thinks you're in, what evidence
it used, and whether graphics support is `inferred` or `verified`. If it says
`verified` without having actually probed anything, that's a bug — tell Claude.

### Then

Type `/clear` and move to Part 2. Or close the session and come back later.

---

## BETWEEN PART 1 AND PART 2 — set up dogfooding

You need to test against your working branch, not the published tag.

Open your config:

```bash
nvim ~/.config/nvim/lua/plugins/md-viewer.lua
```

Change the plugin spec — remove `version`, add `dir`:

```lua
"alanbanks229/md-viewer.nvim",
dir = "~/Documents/Github/Neovim_Plugins/md-viewer.nvim",
-- version = "v0.1.0-beta",   <- delete this line; dir and version conflict
```

Restart Neovim. Confirm the preview still opens with `<leader>mp`.

**Keep a copy of the original file** so you can switch back:

```bash
cp ~/.config/nvim/lua/plugins/md-viewer.lua ~/md-viewer.lua.backup
```

---

## PART 2 — Portable rendering

**Model:** Sonnet 5 &nbsp;&nbsp;|&nbsp;&nbsp; **Plan mode:** no

### Do this

```bash
cd ~/Documents/Github/Neovim_Plugins/md-viewer.nvim
claude
```

```text
/model
```
→ **Sonnet 5**

```text
/clear
```

```text
Read prompts/00-policy.md and prompts/part-2-portable-rendering.md, then implement Part 2.
```

### When it says it's done

```bash
git log --oneline -1
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
```

### Then do this yourself — this is the important one

**This is the real test of whether "cross-platform" actually happened.** No
automated test can do it.

Open your config:

```bash
nvim ~/.config/nvim/lua/plugins/md-viewer.lua
```

Delete these four lines:

```lua
image.backend = "kitty_raw"
browser.executable_path = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
render.cell_aspect_ratio = 0.42
render.estimated_cell_width_px = 7.5
```

Restart Neovim. Open a Markdown file. Press `<leader>mp`.

**Does the preview still render correctly?**

- Yes → Parts 1 and 2 worked. The plugin can now figure this out on its own.
- No → put the lines back one at a time to find which one is still needed, then
  start a new Claude session and tell it exactly which one and what went wrong.

Also check `:MdViewerHealth` — it should report the backend it picked and why.

### If it all works, you have a shippable release

```bash
git tag v0.2.0
```

Don't push the tag yet if you plan to keep going. Just mark the spot.

---

## PART 3 — Interaction transport

**Model:** Opus 5 to plan, Sonnet 5 to implement &nbsp;&nbsp;|&nbsp;&nbsp; **Plan mode: YES**

This is the one part where planning first is worth the money. Nothing
user-visible changes in this part — it's all plumbing underneath.

### Do this

```bash
cd ~/Documents/Github/Neovim_Plugins/md-viewer.nvim
claude
```

```text
/model
```
→ pick **Opus 5**

```text
/clear
```

Now turn on plan mode: press **Shift+Tab** until the prompt shows `plan mode on`.

Paste:

```text
Read prompts/00-policy.md and prompts/part-3-interaction-transport.md. Plan Part 3 in detail — I especially want the queueing, staleness-lane, and document-isolation design settled before any code is written.
```

It will think, then present a plan and ask you to approve it.

**Read the plan.** You're looking for it to have answered: how does an
interaction for document A avoid touching document B's DOM, and how does a drag
avoid cancelling a render. If those aren't clearly addressed, say so and ask it
to revise before approving.

### After you approve the plan

Switch to Sonnet to do the actual writing:

```text
/model
```
→ pick **Sonnet 5**

```text
Implement the approved plan for Part 3.
```

*(If switching models feels like a hassle, skip it and just let Opus implement.
It costs more, it's not wrong.)*

### When it says it's done

```bash
git log --oneline -1
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
```

### Then do this yourself

**Nothing.** There's nothing to see — this part adds no user-visible behavior on
purpose. Just confirm the tests pass and the commit exists.

Set your model back if you changed it:

```text
/model
```
→ **Sonnet 5**

---

## PART 4 — Mouse layer, click-to-source, safe links

**Model:** Sonnet 5 &nbsp;&nbsp;|&nbsp;&nbsp; **Plan mode:** no

### Do this

```bash
cd ~/Documents/Github/Neovim_Plugins/md-viewer.nvim
claude
```

```text
/model
```
→ **Sonnet 5**

```text
/clear
```

```text
Read prompts/00-policy.md and prompts/part-4-mouse-and-navigation.md, then implement Part 4.
```

### When it says it's done

```bash
git log --oneline -1
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
```

### Then do this yourself — first time you'll see interaction work

Restart Neovim, open a Markdown file, open the preview. Try each of these:

| Try | Expect |
|-----|--------|
| Click a paragraph in the preview | Cursor jumps to that block in the source |
| Ctrl-click an `https://` link | Opens in your browser |
| Click the statusline | Normal Neovim behavior, nothing weird |
| Scroll wheel over the preview | Still scrolls like before |
| Close the preview, then use your own mouse mappings | They still work |

The cursor will land on the *start of the block* you clicked, not the exact word.
**That's correct for now** — Part 5 fixes it.

If anything above misbehaves, note exactly what you did and what happened, and
start a new session to report it before moving on.

---

## PART 5 — Exact source provenance

**Model:** Opus 5, start to finish &nbsp;&nbsp;|&nbsp;&nbsp; **Plan mode:** no

This is the hardest part in the project. Don't use Sonnet here — the way this
fails is silent (cursor lands in the wrong place, nothing crashes).

### Do this

```bash
cd ~/Documents/Github/Neovim_Plugins/md-viewer.nvim
claude
```

```text
/model
```
→ pick **Opus 5**

```text
/clear
```

```text
Read prompts/00-policy.md and prompts/part-5-source-provenance.md, then implement Part 5.
```

This one will take a while and burn tokens. That's expected.

### When it says it's done

```bash
git log --oneline -1
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
```

### Then do this yourself

Make a scratch Markdown file with tricky content:

```markdown
Some **bold text** and a [link label](https://example.com) here.

Unicode line: café 日本語 🎉 done.

Repeated: apple banana apple banana apple
```

Open the preview and click precisely on:

- the word `text` inside the bold → cursor should land on `text` in the source,
  **after** the `**`
- the word `label` inside the link → cursor lands on `label`, not on the URL
- the `日本語` characters → cursor lands there, not offset by a few columns
- the emoji → cursor lands there, not two columns off
- the **second** `apple` → cursor lands on the second one, not the first

Then run `:MdViewerDebug` and look for the last navigation precision. It should
say `exact` for these cases.

**The multibyte ones are what matters.** If clicking `日本語` or `🎉` puts the
cursor a few columns off, the UTF-8 conversion is wrong — report it before
moving on. That bug gets much harder to find later.

Set your model back to Sonnet 5 when done.

---

## PART 6 — Selection, copy, and search

**Model:** Sonnet 5 &nbsp;&nbsp;|&nbsp;&nbsp; **Plan mode:** no

### Do this

```bash
cd ~/Documents/Github/Neovim_Plugins/md-viewer.nvim
claude
```

```text
/model
```
→ **Sonnet 5**

```text
/clear
```

```text
Read prompts/00-policy.md and prompts/part-6-selection-and-search.md, then implement Part 6.
```

### When it says it's done

```bash
git log --oneline -1
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
```

### Then do this yourself — the fun part

Open the preview and try:

| Try | Expect |
|-----|--------|
| Click and drag across a paragraph | A blue highlight follows your mouse |
| Drag **upward / backward** | Selection grows, doesn't collapse |
| Drag across two paragraphs | Both highlight |
| Press `y` | Selection copied — paste it somewhere to confirm |
| `:MdViewerCopy` | Same thing |
| Double-click a word | Just that word highlights |
| Press `/`, type a word that appears 3 times, Enter | Matches highlight |
| Press `n` then `N` | Cycles forward and back through matches |
| Press `Esc` | Clears the search |
| Press `Esc` again | Clears the selection |

Watch for **feel**: dragging should look smooth-ish, not like a slideshow. If it
lags badly, that's the coalescing/backpressure not working — report it.

Backward dragging is the single most commonly broken case. Test it properly.

---

## PART 7 — Hardening, docs, compatibility matrix

**Model:** Sonnet 5 &nbsp;&nbsp;|&nbsp;&nbsp; **Plan mode:** no

Don't downgrade this one to a cheaper model. It contains a security review.

### Do this

```bash
cd ~/Documents/Github/Neovim_Plugins/md-viewer.nvim
claude
```

```text
/model
```
→ **Sonnet 5**

```text
/clear
```

```text
Read prompts/00-policy.md and prompts/part-7-hardening-and-docs.md, then implement Part 7.
```

### Optional second pass while you're in the session

```text
/security-review
```

### When it says it's done

```bash
git log --oneline -1
NVIM_APPNAME=md-viewer-tests nvim --headless -u NONE -i NONE -l tests/lua/run.lua
npm test --prefix renderer
stylua --check lua/ plugin/ tests/lua/
```

### Then do this yourself — only you can finish this part

Open the rewritten manual test procedure:

```bash
nvim docs/manual-testing.md
```

Work through it in **each terminal you actually have installed.** For most people
that's iTerm2 and maybe one other.

Then edit the compatibility table with **real results**:

- Only mark a terminal `Supported` if you personally launched it and looked at it
- Everything you didn't test gets `Protocol-compatible but unvalidated`
- If something is broken, mark it `Experimental` or `Unsupported` and say why

A table that's mostly `Protocol-compatible but unvalidated` is a perfectly good
release. A table that says `Supported` for a terminal you never opened is a bug
report someone else is going to file.

### Ship it

```bash
git tag v0.3.0
git push origin feat/cross-platform-markdown-preview
git push origin v0.3.0
```

Open a PR when you're ready.

### Put your config back

If you want to go back to the published version instead of your local checkout:

```bash
cp ~/md-viewer.lua.backup ~/.config/nvim/lua/plugins/md-viewer.lua
```

---

## If something goes wrong

### Claude says it can't find a file the prompt mentions

An earlier part probably named things differently. Tell it:

```text
Read docs/cross-platform-implementation-status.md first — an earlier part may have used different names than this prompt assumes. Reconcile, then continue.
```

### Tests fail and Claude can't fix them

Stop. Don't let it keep flailing — that burns tokens fast. Instead:

```text
Stop implementing. Don't commit. Summarize exactly what is failing and what you have tried, and update docs/cross-platform-implementation-status.md with the current state.
```

Then start fresh with Opus 5 and give it the failure.

### You want to undo a whole part

Every part is one commit, on purpose:

```bash
git log --oneline
git revert <the-commit-hash>
```

### You ran out of budget mid-part

That's what the policy is designed for. Whatever committed is safe. Next session:

```text
/clear
Read docs/cross-platform-implementation-status.md and tell me exactly where things stand and what the next action is.
```

### A session is getting long and confused

Just `/clear` and restart the part. Context rot is real — a fresh session with
the prompt file beats a long one that's lost the plot.

---

## Quick reference

| Part | Model | Plan mode | Manual work after |
|------|-------|-----------|-------------------|
| 1 | Sonnet 5 | no | Check `:MdViewerHealth` output |
| — | — | — | Point config at local checkout |
| 2 | Sonnet 5 | no | **Delete the 4 hardcoded config lines, confirm it still renders** |
| 3 | Opus → Sonnet | **yes** | Nothing — invisible by design |
| 4 | Sonnet 5 | no | Click a paragraph, Ctrl-click a link |
| 5 | Opus 5 | no | **Click multibyte text, verify cursor lands exactly** |
| 6 | Sonnet 5 | no | Drag, drag backward, copy, search |
| 7 | Sonnet 5 | no | **Fill in the compatibility matrix honestly** |

The three bolded rows are the ones no automated test can do for you.
