local M = { count = 0, failures = {}, skips = {} }

---Called before every assertion, when the runner installs one. The session
---shape contract uses it to sample the live sessions: a field that exists only
---between two lines of one handler is still on the table when the assertion
---about that handler runs.
M.on_assert = nil

function M.eq(expected, actual, label)
  if M.on_assert then M.on_assert() end
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
  if M.on_assert then M.on_assert() end
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

---Record that a block of assertions did not run, and why. A skip is not a
---pass: it is printed after the count so a run that quietly covered less than
---the last one says so.
function M.skip(what, reason)
  -- Sample here too: a skip is where a case stops, and the session it was
  -- about is still on the table at this point but will not be by the next
  -- assertion in some later case.
  if M.on_assert then M.on_assert() end
  M.skips[#M.skips + 1] = ("%s -- %s"):format(what, reason)
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
  for _, skip in ipairs(M.skips) do
    print("  skipped: " .. skip)
  end
end

return M
