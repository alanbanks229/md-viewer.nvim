local M = { count = 0, failures = {} }

function M.eq(expected, actual, label)
  M.count = M.count + 1
  if not vim.deep_equal(expected, actual) then
    M.failures[#M.failures + 1] = ("%s\nexpected: %s\nactual:   %s"):format(
      label or ("assertion " .. M.count), vim.inspect(expected), vim.inspect(actual))
  end
end

function M.ok(value, label)
  M.eq(true, not not value, label)
end

function M.finish()
  if #M.failures > 0 then error(table.concat(M.failures, "\n\n")) end
  print(("md-viewer Lua tests: %d assertions passed"):format(M.count))
end

return M
