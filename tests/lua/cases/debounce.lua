return function(t)
  local debounce = require("md-viewer.debounce")
  local holder, calls = {}, 0
  debounce.call(holder, "timer", 5, function() calls = calls + 1 end)
  debounce.call(holder, "timer", 5, function() calls = calls + 1 end)
  vim.wait(100, function() return calls == 1 end)
  t.eq(1, calls, "debounce coalesces callbacks")
  debounce.close(holder, "timer")
end
