if vim.g.loaded_codex_nvim then
  return
end
vim.g.loaded_codex_nvim = true

require("codex").setup()
