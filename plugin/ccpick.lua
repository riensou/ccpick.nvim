-- Autoload entry point.
-- This file is sourced automatically by Neovim when the plugin loads.
-- It intentionally does nothing except guard against double-loading.
-- The user must call require("ccpick").setup() in their config.

if vim.g.loaded_ccpick then
  return
end
vim.g.loaded_ccpick = true
