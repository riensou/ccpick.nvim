local session = require("ccpick.session")
local parser  = require("ccpick.parser")
local picker  = require("ccpick.picker")

local M = {}

-- Default config
local defaults = {
  -- Keymaps
  keymap = "<leader>cc",

  -- Which languages to show. Empty table = show all.
  -- Set to {"bash","sh","zsh"} to show shell commands only.
  langs = { "bash", "sh", "zsh" },

  -- How many of the most recent assistant turns to scan
  turns = 1,

  -- Highlight colors (override these in your colorscheme or setup())
  highlights = {
    available = { bg = "#1e3a5f", fg = "#a8c8e8" },  -- muted blue
    selected  = { bg = "#1a6fc4", fg = "#ffffff" },  -- bright blue
    title     = { fg = "#a8c8e8", bold = true },
    empty     = { fg = "#666666", italic = true },
  },
}

local config = {}

local function define_highlights()
  local h = config.highlights
  vim.api.nvim_set_hl(0, "CcpickAvailable", h.available)
  vim.api.nvim_set_hl(0, "CcpickSelected",  h.selected)
  vim.api.nvim_set_hl(0, "CcpickTitle",     h.title)
  vim.api.nvim_set_hl(0, "CcpickEmpty",     h.empty)
end

-- Main action: find session, parse, open picker
function M.pick()
  local path, err = session.find()
  if not path then
    vim.notify("[ccpick] " .. err, vim.log.levels.WARN)
    return
  end

  local items, perr = parser.parse(path, {
    langs = config.langs,
    turns = config.turns,
  })

  if not items then
    vim.notify("[ccpick] Parse error: " .. perr, vim.log.levels.ERROR)
    return
  end

  if #items == 0 then
    vim.notify("[ccpick] No commands found in last Claude response.", vim.log.levels.INFO)
    return
  end

  picker.open(items)
end

-- Setup function for lazy.nvim / user config
function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})

  -- Define highlight groups
  define_highlights()

  -- Re-apply highlights when colorscheme changes
  vim.api.nvim_create_autocmd("ColorScheme", {
    callback = define_highlights,
  })

  -- Register the keymap
  vim.keymap.set("n", config.keymap, M.pick, {
    desc    = "ccpick: pick command from Claude Code session",
    silent  = true,
    noremap = true,
  })
end

return M
