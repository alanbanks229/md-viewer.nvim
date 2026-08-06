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
  process.stop()
  vim.wait(5000, function() return not process.status().running end, 20)
  t.eq(false, process.status().running, "Lua renderer shutdown")
end
