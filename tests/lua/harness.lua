local M = { count = 0, failures = {} }

function M.eq(expected, actual, label)
  M.count = M.count + 1
  if not vim.deep_equal(expected, actual) then
    M.failures[#M.failures + 1] = ("%s\nexpected: %s\nactual:   %s"):format(
      label or ("assertion " .. M.count),
      vim.inspect(expected),
      vim.inspect(actual)
    )
  end
end

function M.ok(value, label) M.eq(true, not not value, label) end

function M.near(expected, actual, tolerance, label)
  M.count = M.count + 1
  local within = type(expected) == "number" and type(actual) == "number" and math.abs(expected - actual) <= tolerance
  if not within then
    M.failures[#M.failures + 1] = ("%s\nexpected: %s (+/- %s)\nactual:   %s"):format(
      label or ("assertion " .. M.count),
      tostring(expected),
      tostring(tolerance),
      tostring(actual)
    )
  end
end

---`filter` is MD_VIEWER_TEST_FILTER, when one was in effect. It is printed
---so that a green partial run cannot be read as a green suite.
function M.finish(filter)
  if #M.failures > 0 then error(table.concat(M.failures, "\n\n")) end
  if filter and filter ~= "" then
    print(("md-viewer Lua tests: %d assertions passed (filter %q -- NOT the full suite)"):format(M.count, filter))
  else
    print(("md-viewer Lua tests: %d assertions passed"):format(M.count))
  end
end

return M
