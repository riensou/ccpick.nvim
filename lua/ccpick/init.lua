local session = require("ccpick.session")
local parser  = require("ccpick.parser")
local picker  = require("ccpick.picker")
local ask     = require("ccpick.ask")
local viewer  = require("ccpick.viewer")

local M = {}

-- Default config
local defaults = {
  -- Keymaps
  keymap     = "<leader>cc",
  ask_keymap = "<leader>ca",

  -- Which languages to show. Empty table = show all.
  -- Set to {"bash","sh","zsh"} to show shell commands only.
  langs = { "bash", "sh", "zsh" },

  -- (turns is no longer needed — all turns are available via h/l navigation)

  -- Highlight groups (linked to standard Neovim groups by default)
  highlights = {
    available = { link = "Normal" },
    selected  = { link = "PmenuSel" },
    title     = { link = "Directory" },
    empty      = { link = "Comment" },
    inline_code = { link = "Function" },
  },
}

local config = {}

local function define_highlights()
  local h = config.highlights
  vim.api.nvim_set_hl(0, "CcpickAvailable", h.available)
  vim.api.nvim_set_hl(0, "CcpickSelected",  h.selected)
  vim.api.nvim_set_hl(0, "CcpickTitle",     h.title)
  vim.api.nvim_set_hl(0, "CcpickEmpty",      h.empty)
  vim.api.nvim_set_hl(0, "CcpickInlineCode", h.inline_code)
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

-- Ask Claude about selected code
function M.ask()
  -- Get visual selection
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local lines = vim.fn.getline(start_pos[2], end_pos[2])
  if type(lines) == "string" then lines = { lines } end
  local code = table.concat(lines, "\n")

  -- Prompt for input
  vim.ui.input({ prompt = "Ask Claude: " }, function(prompt)
    if prompt == nil then return end -- user pressed Esc/cancelled
    if prompt == "" then
      prompt = "Explain what this code does, how it works, and why it's written this way."
    end

    viewer.show_loading("claude")

    ask.run(prompt, code, function(response, exit_code)
      if exit_code ~= 0 then
        viewer.close()
        vim.notify("[ccpick] Claude exited with code " .. exit_code, vim.log.levels.ERROR)
        return
      end
      if response == "" then
        viewer.close()
        vim.notify("[ccpick] No response from Claude.", vim.log.levels.WARN)
        return
      end
      viewer.open(response, "claude")
    end)
  end)
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

  -- Register keymaps
  vim.keymap.set("n", config.keymap, M.pick, {
    desc    = "ccpick: pick command from Claude Code session",
    silent  = true,
    noremap = true,
  })

  vim.keymap.set("v", config.ask_keymap, ":<C-u>lua require('ccpick').ask()<CR>", {
    desc    = "ccpick: ask Claude about selected code",
    silent  = true,
    noremap = true,
  })
end

return M
