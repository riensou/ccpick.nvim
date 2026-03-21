local M = {}

-- Highlight groups (defined once in init.lua but referenced here)
local HL_AVAILABLE = "CcpickAvailable"
local HL_SELECTED  = "CcpickSelected"
local HL_TITLE     = "CcpickTitle"
local HL_EMPTY     = "CcpickEmpty"

local state = {
  bufnr   = nil,
  winnr   = nil,
  items   = {},   -- list of { cmd, lang }
  cursor  = 1,    -- 1-based index of selected item
}

local function is_open()
  return state.winnr ~= nil and vim.api.nvim_win_is_valid(state.winnr)
end

local function close()
  if is_open() then
    vim.api.nvim_win_close(state.winnr, true)
  end
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_delete(state.bufnr, { force = true })
  end
  state.winnr = nil
  state.bufnr = nil
  state.items = {}
  state.cursor = 1
end

-- Render lines into the buffer and apply highlights
local function render()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end

  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", true)

  local lines = {}
  local items = state.items

  if #items == 0 then
    lines = { "  No commands found in last Claude response." }
  else
    for i, item in ipairs(items) do
      local prefix = (i == state.cursor) and "▶ " or "  "
      -- show language tag if not bash-family
      local tag = ""
      if item.lang ~= "bash" and item.lang ~= "sh" and item.lang ~= "zsh" and item.lang ~= "" then
        tag = " [" .. item.lang .. "]"
      end
      -- For multi-line commands show only first line with ellipsis
      local display = item.cmd:gsub("\n.*", " …")
      table.insert(lines, prefix .. display .. tag)
    end
  end

  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)

  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(state.bufnr, -1, 0, -1)

  if #items == 0 then
    vim.api.nvim_buf_add_highlight(state.bufnr, -1, HL_EMPTY, 0, 0, -1)
    vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)
    return
  end

  -- Apply per-line highlights
  for i, _ in ipairs(items) do
    local hl = (i == state.cursor) and HL_SELECTED or HL_AVAILABLE
    vim.api.nvim_buf_add_highlight(state.bufnr, -1, hl, i - 1, 0, -1)
  end

  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)
end

-- Move selection up or down
local function move(delta)
  if #state.items == 0 then return end
  state.cursor = ((state.cursor - 1 + delta) % #state.items) + 1
  render()
end

-- Copy selected item to system clipboard and close
local function confirm()
  if #state.items == 0 then return end
  local item = state.items[state.cursor]
  vim.fn.setreg("+", item.cmd)   -- system clipboard
  vim.fn.setreg('"', item.cmd)   -- unnamed register too
  close()
  vim.notify("[ccpick] Copied: " .. item.cmd:sub(1, 60), vim.log.levels.INFO)
end

-- Set up buffer-local keymaps for the picker window
local function set_keymaps(bufnr)
  local opts = { noremap = true, silent = true, buffer = bufnr }

  vim.keymap.set("n", "j",      function() move(1)   end, opts)
  vim.keymap.set("n", "k",      function() move(-1)  end, opts)
  vim.keymap.set("n", "<Down>", function() move(1)   end, opts)
  vim.keymap.set("n", "<Up>",   function() move(-1)  end, opts)
  vim.keymap.set("n", "<CR>",   confirm,               opts)
  vim.keymap.set("n", "q",      close,                 opts)
  vim.keymap.set("n", "<Esc>",  close,                 opts)
end

-- Calculate a sensible window size and position
local function win_config(num_items)
  local ui     = vim.api.nvim_list_uis()[1]
  local width  = math.min(80, math.floor(ui.width * 0.7))
  local height = math.max(1, math.min(num_items, 12))
  local row    = math.floor((ui.height - height) / 2) - 2
  local col    = math.floor((ui.width - width) / 2)

  return {
    relative = "editor",
    width    = width,
    height   = height,
    row      = row,
    col      = col,
    style    = "minimal",
    border   = "rounded",
    title    = " ccpick — select command ",
    title_pos = "center",
  }
end

-- Public: open the picker with a list of items
function M.open(items)
  if is_open() then close() end

  state.items  = items or {}
  state.cursor = 1

  -- Create scratch buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "filetype", "ccpick")
  state.bufnr = bufnr

  -- Open floating window
  local cfg = win_config(math.max(1, #items))
  local winnr = vim.api.nvim_open_win(bufnr, true, cfg)
  vim.api.nvim_win_set_option(winnr, "cursorline", false)
  vim.api.nvim_win_set_option(winnr, "wrap", false)
  state.winnr = winnr

  set_keymaps(bufnr)
  render()

  -- Close if focus leaves the window
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer  = bufnr,
    once    = true,
    callback = function()
      vim.schedule(close)
    end,
  })
end

return M
