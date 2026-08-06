local M = {}

function M.call(holder, key, delay, callback)
  local timer = holder[key]
  if timer then timer:stop() else timer = vim.uv.new_timer(); holder[key] = timer end
  timer:start(delay, 0, vim.schedule_wrap(callback))
  return timer
end

function M.close(holder, key)
  local timer = holder[key]
  if timer then
    timer:stop()
    if not timer:is_closing() then timer:close() end
    holder[key] = nil
  end
end

return M
