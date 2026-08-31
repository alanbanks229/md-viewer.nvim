-- Installs the renderer's locked dependencies. Plugin managers run this on
-- install and update; the vim.pack snippet in README.md dofile()s it directly.

-- Resolved from this file's own path, since loadfile() callers pass no
-- arguments and the working directory is arbitrary.
local root = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))

-- `--ignore-scripts` is what stops Playwright's postinstall from fetching a
-- browser; the environment variable holds even if a dependency shells out to
-- npm itself. md-viewer drives the browser already on the machine.
local result = vim
  .system({ "npm", "ci", "--ignore-scripts" }, {
    cwd = root .. "/renderer",
    env = { PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1" },
    text = true,
  })
  :wait()

if result.code ~= 0 then
  error("md-viewer.nvim renderer installation failed:\n" .. (result.stderr or result.stdout or "unknown error"))
end
