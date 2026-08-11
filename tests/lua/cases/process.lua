return function(t)
  local process = require("md-viewer.process")
  local ping_result, ping_error
  process.request("ping", {}, function(result, err)
    ping_result, ping_error = result, err
  end)
  vim.wait(5000, function() return ping_result ~= nil or ping_error ~= nil end, 20)
  if ping_error then print("renderer integration diagnostics: " .. vim.inspect(process.status())) end
  t.eq(nil, ping_error, "Lua renderer protocol error")
  t.eq(true, ping_result and ping_result.pong, "Lua renderer protocol ping")

  -- An error response carries `code`/`detail` (protocol.js) so a caller can
  -- distinguish, e.g., a stale-interaction supersession from any other
  -- failure without parsing the human-readable message -- interaction.lua's
  -- stale-interaction diagnostic counter (:MdViewerDebug) depends on this.
  -- `interact` against a documentId that was never rendered is a real,
  -- deterministic error path (INTERACT_CACHE_MISS) that needs no Chromium
  -- page at all.
  local interact_result, interact_err, interact_meta
  process.request("interact", {
    documentId = "process-test-never-rendered",
    contentRevision = "1",
    action = "selection_text",
    viewportWidthPx = 800,
    viewportHeightPx = 600,
  }, function(result, err, meta)
    interact_result, interact_err, interact_meta = result, err, meta
  end)
  vim.wait(5000, function() return interact_err ~= nil or interact_result ~= nil end, 20)
  t.eq(
    nil,
    interact_result,
    "an interact request against an unrendered document fails rather than fabricating a result"
  )
  t.ok(interact_err ~= nil, "the failure is reported as an error")
  t.eq("table", type(interact_meta), "the third callback argument carries the error's machine-readable metadata")
  t.eq(
    "INTERACT_CACHE_MISS",
    interact_meta and interact_meta.code,
    "the code identifies why the interaction was refused"
  )

  process.stop()
  vim.wait(5000, function() return not process.status().running end, 20)
  t.eq(false, process.status().running, "Lua renderer shutdown")
end
