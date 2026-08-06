if vim.g.loaded_md_viewer_nvim == 1 then return end
vim.g.loaded_md_viewer_nvim = 1

vim.api.nvim_set_hl(0, "MdViewerHeading", { bold = true, default = true })
vim.api.nvim_set_hl(0, "MdViewerCode", { link = "String", default = true })
vim.api.nvim_set_hl(0, "MdViewerQuote", { link = "Comment", default = true })
vim.api.nvim_set_hl(0, "MdViewerRule", { link = "NonText", default = true })

require("md-viewer").setup()
