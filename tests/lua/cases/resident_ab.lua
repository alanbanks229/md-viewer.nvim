-- The measurement harness itself.
--
-- `scripts/resident/ab.lua` is the only way anyone finds out whether resident
-- panning is doing what it claims on a real link, and it reads a dozen fields
-- off `session.resident`. The grid rewrite removed five of them -- `regions`,
-- `height_scale`, `plan_refusal`, `last_insert_refusal`, `used_px` -- and the
-- harness went on referencing them, so `:ResidentAB` threw before it recorded a
-- baseline. Nothing failed: the command wrapper catches its own errors and
-- reports them through `vim.notify`, so on a remote session the instrument
-- simply stopped answering.
--
-- This case drives the whole run headlessly. It cannot measure a wire -- there
-- is no terminal and no SSH here -- but every field the report reads is read,
-- every verdict branch that a zero-traffic run can reach is reached, and an
-- error surfaces as a failure rather than as a notification nobody sees.
return function(t)
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local state = require("md-viewer.state")

  config.reset()
  require("md-viewer").setup({ image = { backend = "cells" } })

  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# A/B", "", "body" })
  local session = assert(controller.open("right"))

  -- Every error the harness produces goes through `vim.notify`, because each
  -- command wraps itself in `pcall` so a half-run cannot leave the operator's
  -- configuration modified. That is right for them and blind for a test, so
  -- notifications are collected and asserted on directly.
  local notices = {}
  local real_notify = vim.notify
  vim.notify = function(message, level) notices[#notices + 1] = { message = tostring(message), level = level } end

  local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h")
  local ok, err = pcall(function()
    -- Sourcing arms phase 1, which is already a snapshot of the live session.
    dofile(root .. "/scripts/resident/ab.lua")
    t.eq({}, notices, "arming the baseline arm reports no error")

    -- Phase 1 -> phase 2. This is the call that used to throw: it snapshots the
    -- baseline arm, and the snapshot is what reads `session.resident`.
    vim.cmd("ResidentAB")
    t.eq({}, notices, "closing the baseline arm and arming the treatment one reports no error")

    vim.cmd("ResidentABMark")
    t.eq({}, notices, "marking reports no error")

    -- A headless session cannot qualify for resident panning, so the treatment
    -- arm has already fallen back and the report would stop at that verdict. The
    -- branch worth reaching is the next one -- "the gate passed and still nothing
    -- filled" -- because that is the one that used to name `plan_refusal` and
    -- `last_insert_refusal`, fields the rewrite removed. Clearing the reason is
    -- the smallest way there and changes nothing else about the run.
    session.resident.fallback_reason = nil

    vim.cmd("ResidentAB")
    t.eq({}, notices, "and neither does producing the report")
  end)

  -- The report opens a split; find it by the name the harness gives it rather
  -- than by assuming which window is current.
  local report_buf
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):match("resident%-ab$") then
      report_buf = buf
    end
  end

  t.eq(true, ok, "the whole run completes: " .. tostring(err))
  t.ok(report_buf ~= nil, "a report buffer is produced")
  if report_buf then
    local text = table.concat(vim.api.nvim_buf_get_lines(report_buf, 0, -1, false), "\n")
    -- The rows that read the fields the rewrite moved. Each of these is a field
    -- lookup that would have thrown, or printed `--`, against the old names.
    for _, expected in ipairs({
      "TOTAL nvim_ui_send BYTES",
      "slice uploads",
      "boundaries: drawn / missed",
      "slices held / in grid",
      "budgeted / ceiling",
      "evictions",
      "slice height scale",
      "link rate used",
    }) do
      t.ok(text:find(expected, 1, true) ~= nil, ("the report carries the %q row"):format(expected))
    end
    -- The row that used to print an inference and call it a measurement: on the
    -- real link it read 139,058 B/ms for a tunnel doing 800, because the write
    -- it timed returned as soon as SSH had buffered the payload. Here nothing is
    -- configured and nothing blocked, so the honest answer is that there is none.
    t.eq(nil, text:match("measured link"), "and never presents an inference as a measurement of the link")
    t.ok(text:find("not measurable", 1, true) ~= nil, "saying so plainly where there is nothing to report")
    -- The verdict for a run where nothing filled, which is the branch that used
    -- to name fields the rewrite removed. It must send the reader somewhere
    -- real rather than to a stack trace or a field that no longer exists.
    t.ok(text:find("NO SLICE WAS EVER FILLED", 1, true) ~= nil, "and reaches a verdict rather than a stack trace")
    t.ok(text:find("grid_refusal", 1, true) ~= nil, "naming a field :MdViewerDebug actually reports")
    t.eq(nil, text:match("plan_refusal"), "and none the rewrite removed")
    t.eq(nil, text:match("last_insert_refusal"), "nor that one")
    t.eq(nil, text:match("height_scale"), "nor the region-era height scale")
  end

  -- Whatever happened, the operator's configuration comes back. A harness that
  -- leaves `image.resident_pan` where it last set it would silently change every
  -- session opened afterwards.
  pcall(vim.cmd, "ResidentABCancel")
  vim.notify = real_notify
  t.eq(config.defaults.image.resident_pan, config.get().image.resident_pan, "the configuration is restored")

  for _, name in ipairs({ "ResidentAB", "ResidentABMark", "ResidentABCancel" }) do
    pcall(vim.api.nvim_del_user_command, name)
  end
  if report_buf then pcall(vim.api.nvim_buf_delete, report_buf, { force = true }) end
  controller.close(source)
  state.remove(source)
  pcall(vim.api.nvim_buf_delete, source, { force = true })
  config.reset()
end
