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

  -- (turns is no longer needed — all turns are available via h/l navigation)

  -- Highlight groups (linked to standard Neovim groups by default)
  highlights = {
    available = { link = "Normal" },
    selected  = { link = "PmenuSel" },
    title     = { link = "Directory" },
    empty     = { link = "Comment" },
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

  local turns, perr = parser.parse_by_turn(path, {
    langs = config.langs,
  })

  if not turns then
    vim.notify("[ccpick] Parse error: " .. perr, vim.log.levels.ERROR)
    return
  end

  if #turns == 0 then
    vim.notify("[ccpick] No commands found in session.", vim.log.levels.INFO)
    return
  end

  picker.open(turns)
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
