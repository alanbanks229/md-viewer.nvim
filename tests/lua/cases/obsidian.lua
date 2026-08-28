return function(t)
  local config = require("md-viewer.config")
  local controller = require("md-viewer.controller")
  local interaction = require("md-viewer.interaction")
  local obsidian = require("md-viewer.obsidian")
  local process = require("md-viewer.process")

  local vault = vim.fn.tempname()
  vim.fn.mkdir(vault .. "/folder", "p")
  vim.fn.mkdir(vault .. "/other", "p")
  vim.fn.writefile({ "# Current" }, vault .. "/current.md")
  vim.fn.writefile({ "# Note" }, vault .. "/folder/Note.md")
  vim.fn.writefile({ "# Duplicate" }, vault .. "/other/note.md")
  vim.fn.writefile({ "# Résumé" }, vault .. "/Résumé.md")
  vim.fn.writefile({ "not markdown" }, vault .. "/folder/Note.txt")
  vault = vim.uv.fs_realpath(vault)

  local source = vim.fn.bufadd(vault .. "/current.md")
  vim.fn.bufload(source)
  local session = { source_buf = source }
  config.reset()
  config.setup({ obsidian = { enabled = true, vault_root = vault } })

  local resolved, reason
  obsidian.resolve(session, "folder/Note", function(path, why)
    resolved, reason = path, why
  end)
  t.eq(vault .. "/folder/Note.md", resolved, "explicit Obsidian paths resolve from the vault root")
  t.eq(nil, reason, "an explicit note path has no failure reason")

  resolved = nil
  obsidian.resolve(session, "RÉSUMÉ", function(path) resolved = path end)
  t.eq(vault .. "/Résumé.md", resolved, "Unicode bare note names are matched case-insensitively")

  local original_select = vim.ui.select
  local choices
  vim.ui.select = function(items, opts, callback)
    choices = vim.tbl_map(opts.format_item, items)
    callback(items[2])
  end
  resolved = nil
  obsidian.resolve(session, "NOTE.md", function(path) resolved = path end)
  t.eq(2, #choices, "bare note names are matched case-insensitively by stem")
  t.eq("other/note.md", choices[2], "duplicate choices are shown as vault-relative paths")
  t.eq(vault .. "/other/note.md", resolved, "the picker selection is returned")

  local cancelled = false
  vim.ui.select = function(_, _, callback)
    callback(nil)
    cancelled = true
  end
  resolved = "unchanged"
  obsidian.resolve(session, "note", function(path) resolved = path end)
  t.eq(true, cancelled, "ambiguous note resolution can be cancelled")
  t.eq("unchanged", resolved, "picker cancellation invokes no navigation callback")
  vim.ui.select = original_select

  resolved, reason = "set", nil
  obsidian.resolve(session, "missing", function(path, why)
    resolved, reason = path, why
  end)
  t.eq(nil, resolved, "a missing note never creates a file")
  t.eq("missing", reason, "a missing note is distinguished from a security refusal")

  resolved, reason = "set", nil
  obsidian.resolve(session, "../escape", function(path, why)
    resolved, reason = path, why
  end)
  t.eq(nil, resolved, "an explicit traversal cannot escape the vault")
  t.eq("outside_root", reason, "traversal is reported as a root refusal")

  local outside = vim.fn.tempname()
  vim.fn.mkdir(outside, "p")
  vim.fn.writefile({ "# Secret" }, outside .. "/secret.md")
  vim.uv.fs_symlink(outside .. "/secret.md", vault .. "/folder/escape.md")
  resolved, reason = "set", nil
  obsidian.resolve(session, "folder/escape", function(path, why)
    resolved, reason = path, why
  end)
  t.eq(nil, resolved, "a symlinked note outside the vault is refused")
  t.eq("outside_root", reason, "a symlink escape uses the same security boundary")

  local original_retarget = controller.retarget
  local retargeted
  controller.retarget = function(active, buf, record, restore_scroll, pending_anchor)
    retargeted = { active, buf, record, restore_scroll, pending_anchor }
    return true
  end
  local cross_anchor = { kind = "heading", segments = { "Parent", "Child" } }
  local current_before = vim.api.nvim_get_current_buf()
  interaction.activate_link(session, {
    link = { type = "obsidian", target = "folder/Note", anchor = cross_anchor },
  })
  t.eq(session, retargeted[1], "cross-note navigation stays in the active preview pane")
  t.eq(0, retargeted[4], "a cross-note anchor opens its target at the top")
  t.eq(cross_anchor, retargeted[5], "the anchor waits on the destination's first render")
  t.eq(
    current_before,
    vim.api.nvim_get_current_buf(),
    "cross-note navigation does not display the target source buffer"
  )
  controller.retarget = original_retarget

  local same_anchor
  local original_scroll_anchor = interaction.scroll_obsidian_anchor
  interaction.scroll_obsidian_anchor = function(active, anchor) same_anchor = { active, anchor } end
  interaction.activate_link(session, {
    link = { type = "obsidian", target = "", anchor = cross_anchor },
  })
  t.eq(session, same_anchor[1], "a same-document Obsidian anchor does not resolve another file")
  t.eq(cross_anchor, same_anchor[2], "a same-document anchor scrolls in place")
  interaction.scroll_obsidian_anchor = original_scroll_anchor

  local original_request = process.request
  local original_schedule = controller.schedule_scroll
  local requested, scheduled = nil, false
  local notifications = {}
  local original_notify = vim.notify
  vim.notify = function(message) notifications[#notifications + 1] = message end
  process.request = function(method, params, callback)
    requested = { method = method, params = params }
    callback({ kind = "obsidian_anchor", found = false, scrollY = 0 }, nil)
  end
  controller.schedule_scroll = function(active) scheduled = active == session end
  session.document_id = "obsidian-test"
  session.renderer_revision = "1:0"
  session.viewport_width_px = 800
  session.viewport_height_render_px = 600
  interaction.scroll_obsidian_anchor(session, { kind = "block", value = "missing-id" })
  t.eq("obsidian_scroll", requested.params.action, "anchor scrolling uses its typed renderer interaction")
  t.eq(true, scheduled, "a missing anchor still displays the target at the top")
  t.ok(notifications[1]:find("anchor not found", 1, true) ~= nil, "a missing anchor warns")
  process.request = original_request
  controller.schedule_scroll = original_schedule
  vim.notify = original_notify

  config.reset()
end
