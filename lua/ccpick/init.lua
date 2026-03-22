local session  = require("ccpick.session")
local parser   = require("ccpick.parser")
local picker   = require("ccpick.picker")
local branches = require("ccpick.branches")
local viewer   = require("ccpick.viewer")
local manager  = require("ccpick.manager")

local M = {}

-- Track the currently viewed branch so \cv can reopen it
local current_branch_id = nil

-- Start polling a branch and update the viewer if it's open
local function poll_branch(branch, title)
  local started = false
  local poll_timer = vim.uv.new_timer()
  poll_timer:start(100, 100, vim.schedule_wrap(function()
    -- Check if branch has response data
    if not started and branch.response ~= "" then
      started = true
      if viewer.is_open() and viewer.get_branch() and viewer.get_branch().id == branch.id then
        viewer.start_streaming(branch, title)
      end
    end

    -- Update viewer if it's showing this branch
    if started and viewer.is_open() and viewer.get_branch() and viewer.get_branch().id == branch.id then
      viewer.update_branch(branch, title)
    end

    -- Stop polling when done
    if branch.status == "done" or branch.status == "error" then
      poll_timer:stop()
      poll_timer:close()
      if viewer.get_branch() and viewer.get_branch().id == branch.id then
        viewer.done_streaming()
      end
    end
  end))
end

-- Handle follow-up from inside the viewer
local function handle_follow_up(prompt, code)
  local branch = viewer.get_branch()
  if not branch then return end

  local title = "claude [#" .. branch.id .. "]"

  -- Clear on_close so reopening doesn't trigger manager
  viewer.set_on_close(nil)

  local ok = branches.follow_up(branch, prompt, code)
  if not ok then return end

  -- Immediately re-render to show the new user message + loading shimmer
  viewer.open_branch(branch, title)

  poll_branch(branch, title)
end

-- Set up the follow-up callback
viewer.set_on_follow_up(handle_follow_up)

-- Show a branch's conversation in the viewer
local function show_branch(branch)
  if not branch then return end
  current_branch_id = branch.id
  local title = "claude [#" .. branch.id .. "]"

  viewer.open_branch(branch, title)

  viewer.set_on_close(function()
    manager.toggle()
  end)
end

-- Set up the manager callback
manager.on_open_branch = show_branch

-- Default config
local defaults = {
  keymap          = "<leader>cc",
  ask_keymap      = "<leader>ca",
  view_keymap     = "<leader>cv",
  manager_keymap  = "<leader>cm",

  langs = { "bash", "sh", "zsh" },

  highlights = {
    available   = { link = "Normal" },
    selected    = { link = "PmenuSel" },
    title       = { link = "Directory" },
    empty       = { link = "Comment" },
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

-- Shared ask logic
local function do_ask(mode)
  local code, line_range
  if mode == "visual" then
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local lines = vim.fn.getline(start_pos[2], end_pos[2])
    if type(lines) == "string" then lines = { lines } end
    code = table.concat(lines, "\n")
    line_range = { start_pos[2], end_pos[2] }
  else
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    code = table.concat(lines, "\n")
  end

  local file = vim.fn.expand("%:t")

  vim.ui.input({ prompt = "Ask Claude: " }, function(prompt)
    if prompt == nil then return end
    if prompt == "" then
      prompt = "Explain what this code does, how it works, and why it's written this way."
    end

    local branch = branches.create(prompt, code, file, line_range)
    current_branch_id = branch.id
    local title = "claude [#" .. branch.id .. "]"

    -- Run in background, don't auto-open viewer
    poll_branch(branch, title)
  end)
end

-- Ask Claude (continues session)
function M.ask(mode)
  do_ask(mode)
end

-- Toggle the response viewer for the most recent branch
function M.view()
  local all = branches.list()
  local branch = #all > 0 and all[1] or nil
  if branch then
    current_branch_id = branch.id
  end

  if not branch then
    vim.notify("[ccpick] No branches to show.", vim.log.levels.INFO)
    return
  end

  local title = "claude [#" .. branch.id .. "]"
  viewer.toggle_branch(branch, title)
end

-- Toggle the branch manager
function M.branches()
  manager.toggle()
end

-- Setup
function M.setup(opts)
  config = vim.tbl_deep_extend("force", defaults, opts or {})

  define_highlights()

  vim.api.nvim_create_autocmd("ColorScheme", {
    callback = define_highlights,
  })

  vim.keymap.set("n", config.keymap, M.pick, {
    desc    = "ccpick: pick command from Claude Code session",
    silent  = true,
    noremap = true,
  })

  vim.keymap.set("v", config.ask_keymap, ":<C-u>lua require('ccpick').ask('visual')<CR>", {
    desc    = "ccpick: ask Claude about selected code",
    silent  = true,
    noremap = true,
  })

  vim.keymap.set("n", config.ask_keymap, function() M.ask("normal") end, {
    desc    = "ccpick: ask Claude about current file",
    silent  = true,
    noremap = true,
  })

  vim.keymap.set("n", config.view_keymap, M.view, {
    desc    = "ccpick: toggle Claude response viewer",
    silent  = true,
    noremap = true,
  })

  vim.keymap.set("n", config.manager_keymap, M.branches, {
    desc    = "ccpick: toggle claude manager",
    silent  = true,
    noremap = true,
  })
end

return M
