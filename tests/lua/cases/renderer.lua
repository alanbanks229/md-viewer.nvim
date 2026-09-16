return function(t)
  local renderer = require("md-viewer.renderer")
  local lanes = require("md-viewer.lanes")

  -- `is_stale` is three questions, not one: the document is gone, the document
  -- is not the one its pane is showing, or this request's lane has moved on.
  -- Only the third is md-viewer.lanes'; the ticket carries it.
  local session = { closed = false, request_serial = 0, lanes = lanes.fields(), lane_epoch = 0 }
  local ticket = lanes.admit(session, "capture")
  t.eq(false, renderer.is_stale(session, ticket), "a reply whose lane has not moved is current")
  local newer = lanes.admit(session, "capture")
  t.eq(true, renderer.is_stale(session, ticket), "a newer capture supersedes the capture before it")
  t.eq(false, renderer.is_stale(session, newer), "and is itself current")

  session.closed = true
  t.eq(true, renderer.is_stale(session, newer), "a closed document stales everything still on its way")
end
