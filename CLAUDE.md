# Working on md-viewer.nvim

## How to report back

**Every problem you name gets the fix next to it, verbatim.** A finding with no
command, edit, or explicit "nothing to do here" is not a finding, it is homework
assigned to the reader. If you know what the fix is, apply it or write it out in
full — the exact shell line, the exact config edit, the exact file and line.

Concretely:

- **Lead with what to do right now.** The first thing in the response is the
  action, not the analysis. Analysis goes underneath, for whoever wants it.
- **If something is broken and you can fix it, fix it.** Do not describe it and
  wait. If it is out of scope to fix, say so in one line and give the exact
  change someone else would make.
- **If there is genuinely nothing to do, say that explicitly.** "This is fine,
  no action" is a complete answer. Silence reads as an unstated chore.
- **A pending item names its owner and its exact next command.** Not "this needs
  a human in a terminal" — rather "run `:MdViewerMeasureLink` in iTerm2 on
  the LAN reference host; paste the notification back."

## What not to put in a report

- **History that does not change the decision.** "rc5 → rc6 found three
  failures" is not a reason to do or not do anything today. If a past bug is
  relevant, it is relevant because it is still live or because a specific guard
  now prevents it — say that instead.
- **Uncertainty with no knob attached.** "The memory figure disagrees with itself
  by 34×" is only worth saying alongside "so `image.resident_max_chunks` is the
  bound that holds, and lowering it is what to do if memory bites."
- **Cons that apply to something nobody is choosing.** If the recommendation is
  "on for host A, off for host B", the cons of running it on host B are not a
  cost of the recommendation.
- **Restating the same fact in three registers.** Say it once, in the place a
  reader will look for it.

## Measurements

Numbers in this repo's docs and comments are measured, not estimated, and they
name the host and date they came from. Do not soften a measured figure into a
range, and do not quote one without saying what it was measured on — an AWS SSM
tunnel and a LAN host are fourteen times apart, and "over SSH" predicts nothing.

If a measurement cannot be taken from the machine you are on, say which machine
can take it and give the exact command to run there.

## Tests

`make test` is Lua (`nvim --headless`) plus the renderer's node suite. Both must
be green before anything is called done. `stylua --check build.lua lua/ plugin/ tests/lua/`
is what CI runs on formatting.

Do not weaken a test to make a change pass. Several tests in
`tests/lua/cases/resident.lua` exist to pin arguments that were wrong before and
say so in their comments; if one of those fails, the change is what is wrong.
