local branches = require("ccpick.branches")

local M = {}

-- Callback set by init.lua to handle opening a branch
M.on_open_branch = nil

local HL_SELECTED = "CcpickSelected"
local HL_EMPTY    = "CcpickEmpty"

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local shimmer_colors = {
  "#c87830", "#d48535", "#e0923a", "#eca03f", "#f0ad44",
  "#eca03f", "#e0923a", "#d48535", "#c87830", "#bc6b2b",
  "#b05e26", "#bc6b2b",
}

-- Namespace for preview extmarks
local ns = vim.api.nvim_create_namespace("ccpick_manager_preview")
local ns_shimmer = vim.api.nvim_create_namespace("ccpick_manager_shimmer")

local state = {
  bufnr   = nil,
  winnr   = nil,
  timer   = nil,
  frame   = 0,
  toggled = {},  -- set of branch indices with preview expanded
}

local function is_open()
  return state.winnr ~= nil and vim.api.nvim_win_is_valid(state.winnr)
end

local function close()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  if is_open() then
    vim.api.nvim_win_close(state.winnr, true)
  end
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_delete(state.bufnr, { force = true })
  end
  state.winnr = nil
  state.bufnr = nil
  state.toggled = {}
end

-- Status indicator for a branch
local function status_icon(branch)
  if branch.status == "loading" or branch.status == "streaming" then
    return spinner_frames[(state.frame % #spinner_frames) + 1]
  elseif branch.status == "done" then
    return "✓"
  elseif branch.status == "error" then
    return "✗"
  end
  return "?"
end

-- Format line range for display
local function format_range(b)
  if not b.line_range then return "all" end
  if b.line_range[1] == b.line_range[2] then
    return "L" .. b.line_range[1]
  end
  return "L" .. b.line_range[1] .. "-" .. b.line_range[2]
end

-- Build display lines from branches (one line per branch always)
local function build_lines()
  local all = branches.list()
  if #all == 0 then
    return { "  No branches." }
  end
  local lines = {}
  for _, b in ipairs(all) do
    local icon = status_icon(b)
    local file_part = b.file ~= "" and b.file or "buffer"
    local range = format_range(b)
    local status_text = ""
    if b.status == "done" then
      status_text = "done"
    elseif b.status == "error" then
      status_text = "error"
    elseif b.status == "loading" or b.status == "streaming" then
      status_text = b.status
    end
    local line = string.format("  %s %s (%s) [%s]", icon, file_part, range, status_text)
    table.insert(lines, line)
  end
  return lines
end

-- Apply virtual line previews for toggled branches
local function apply_previews()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)

  local all = branches.list()
  local win_width = is_open() and vim.api.nvim_win_get_width(state.winnr) or 80

  local cursor_row = nil
  if is_open() then
    cursor_row = vim.api.nvim_win_get_cursor(state.winnr)[1]
  end

  for i, b in ipairs(all) do
    if state.toggled[i] then
      local virt_lines = {}
      local prefix = "    "
      local max_w = math.max(20, win_width - #prefix - 4)
      local hl = (i == cursor_row) and HL_SELECTED or "Normal"

      -- Show prompt and line range (slightly indented)
      local range_str = format_range(b)
      local indent = "  "
      local preview_lines = {
        prefix .. indent .. "prompt: " .. b.prompt,
        prefix .. indent .. "lines:  " .. range_str,
      }

      for _, pl in ipairs(preview_lines) do
        -- Word-wrap: find last space before max_w
        while #pl > max_w do
          local wrap_at = max_w
          local space = pl:sub(1, max_w):find("%s[^%s]*$")
          if space and space > #prefix + 5 then
            wrap_at = space
          end
          local line_text = pl:sub(1, wrap_at)
          -- Pad to full window width
          local pad = win_width - #line_text
          if pad > 0 then line_text = line_text .. string.rep(" ", pad) end
          table.insert(virt_lines, { { line_text, hl } })
          pl = prefix .. indent .. "  " .. pl:sub(wrap_at + 1)
        end
        -- Pad final line to full window width
        local pad = win_width - #pl
        if pad > 0 then pl = pl .. string.rep(" ", pad) end
        table.insert(virt_lines, { { pl, hl } })
      end

      if #virt_lines > 0 then
        vim.api.nvim_buf_set_extmark(state.bufnr, ns, i - 1, 0, {
          virt_lines = virt_lines,
          virt_lines_above = false,
        })
      end
    end
  end
end

local function render()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end

  local lines = build_lines()
  local all = branches.list()

  local cursor_row = 1
  if is_open() then
    cursor_row = vim.api.nvim_win_get_cursor(state.winnr)[1]
  end

  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)

  vim.api.nvim_buf_clear_namespace(state.bufnr, -1, 0, -1)
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns_shimmer, 0, -1)
  if #all == 0 then
    vim.api.nvim_buf_add_highlight(state.bufnr, -1, HL_EMPTY, 0, 0, -1)
  end

  -- Apply shimmer to spinner character only on active branches
  local shimmer_idx = (state.frame % #shimmer_colors) + 1
  vim.api.nvim_set_hl(0, "CcpickManagerShimmer", { fg = shimmer_colors[shimmer_idx] })
  for i, b in ipairs(all) do
    if b.status == "loading" or b.status == "streaming" then
      -- "  ⠹ " — shimmer just the spinner char (col 2 to 5 roughly)
      vim.api.nvim_buf_add_highlight(state.bufnr, ns_shimmer, "CcpickManagerShimmer", i - 1, 2, 5)
    end
  end

  -- Apply previews
  apply_previews()

  -- Resize to fit content + preview lines
  local total_visual = #lines
  for i, b in ipairs(all) do
    if state.toggled[i] then
      -- Estimate 2 lines for prompt + lines, plus wrapping
      local max_w = math.max(20, (is_open() and vim.api.nvim_win_get_width(state.winnr) or 80) - 8)
      local prompt_len = #("      prompt: " .. b.prompt)
      total_visual = total_visual + math.max(1, math.ceil(prompt_len / max_w))
      total_visual = total_visual + 1 -- lines: row
    end
  end

  local height = math.max(3, math.min(total_visual, 15))
  if is_open() then
    vim.api.nvim_win_set_height(state.winnr, height)
    if cursor_row > #lines then cursor_row = #lines end
    if cursor_row > 0 then
      vim.api.nvim_win_set_cursor(state.winnr, { cursor_row, 0 })
    end
  end
end

-- Open a branch's response in the viewer
local function open_branch()
  local all = branches.list()
  if #all == 0 then return end
  local row = vim.api.nvim_win_get_cursor(state.winnr)[1]
  local branch = all[row]
  if not branch then return end

  close()

  if M.on_open_branch then
    M.on_open_branch(branch)
  end
end

-- Delete branch under cursor
local function delete_branch()
  local all = branches.list()
  if #all == 0 then return end
  local row = vim.api.nvim_win_get_cursor(state.winnr)[1]
  local branch = all[row]
  if not branch then return end
  branches.delete(branch.id)
  state.toggled = {}
  render()
end

-- Prune all completed branches
local function prune_branches()
  branches.prune()
  state.toggled = {}
  render()
end

-- Toggle preview for branch under cursor
local function toggle_preview()
  local all = branches.list()
  local row = vim.api.nvim_win_get_cursor(state.winnr)[1]
  if row > #all then return end
  state.toggled[row] = not state.toggled[row]
  render()
  vim.api.nvim_win_set_cursor(state.winnr, { row, 0 })
end

local function set_keymaps(bufnr)
  local opts = { noremap = true, silent = true, buffer = bufnr }

  vim.keymap.set("n", "<CR>",  open_branch,    opts)
  vim.keymap.set("n", "q",     close,           opts)
  vim.keymap.set("n", "<Esc>", close,           opts)
  vim.keymap.set("n", "dd",    delete_branch,   opts)
  vim.keymap.set("n", "D",     prune_branches,  opts)
  vim.keymap.set("n", "o",     toggle_preview,  opts)
end

-- Toggle the branch manager
function M.toggle()
  if is_open() then
    close()
    return
  end

  local lines = build_lines()

  -- Create buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "filetype", "ccpick")
  state.bufnr = bufnr

  -- Window config
  local ui = vim.api.nvim_list_uis()[1]
  local width = math.min(80, math.floor(ui.width * 0.7))
  local height = math.max(3, math.min(#lines, 15))
  local row = math.floor((ui.height - height) / 2) - 2
  local col = math.floor((ui.width - width) / 2)

  local winnr = vim.api.nvim_open_win(bufnr, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    border    = "rounded",
    title     = " claude manager ",
    title_pos = "center",
  })
  vim.wo[winnr].wrap = false
  vim.wo[winnr].cursorline = true
  vim.wo[winnr].number = true
  vim.wo[winnr].relativenumber = true
  vim.wo[winnr].signcolumn = "no"
  vim.wo[winnr].foldcolumn = "0"
  vim.wo[winnr].spell = false
  vim.wo[winnr].winhighlight = "CursorLine:" .. HL_SELECTED .. ",FloatBorder:CcpickTitle,FloatTitle:CcpickTitle"
  state.winnr = winnr

  set_keymaps(bufnr)
  render()

  -- Update preview highlights when cursor moves
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer   = bufnr,
    callback = function()
      for _, v in pairs(state.toggled) do
        if v then apply_previews(); return end
      end
    end,
  })

  -- Timer to animate spinners and shimmer for active branches
  if branches.active_count() > 0 then
    state.timer = vim.uv.new_timer()
    state.timer:start(0, 250, vim.schedule_wrap(function()
      if not is_open() then
        if state.timer then
          state.timer:stop()
          state.timer:close()
          state.timer = nil
        end
        return
      end
      state.frame = state.frame + 1
      render()
      if branches.active_count() == 0 and state.timer then
        state.timer:stop()
        state.timer:close()
        state.timer = nil
      end
    end))
  end

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer   = bufnr,
    once     = true,
    callback = function()
      vim.schedule(close)
    end,
  })
end

return M
