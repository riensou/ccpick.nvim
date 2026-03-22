local M = {}

local HL_SELECTED = "CcpickSelected"
local HL_EMPTY    = "CcpickEmpty"

-- Persists across picker opens — timestamp of last copied turn
local last_copied_timestamp = nil

-- Namespace for extmarks (virtual lines)
local ns = vim.api.nvim_create_namespace("ccpick_preview")

local state = {
  bufnr    = nil,
  winnr    = nil,
  turns        = {},    -- list of turns, each { items, timestamp }
  turn_idx     = 1,    -- which turn we're viewing (1 = most recent)
  toggled      = {},   -- set of item indices with preview expanded
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
  state.turns = {}
  state.turn_idx = 1
  state.toggled = {}
end

-- Get items for the current turn
local function current_items()
  local turn = state.turns[state.turn_idx]
  return turn and turn.items or {}
end

-- Format an ISO timestamp (UTC) to local time (e.g. "12:34 PM")
local function format_timestamp(ts)
  if not ts then return nil end
  local y, mo, d, h, mi, s = ts:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  local now = os.time()
  local utc_offset = os.difftime(now, os.time(os.date("!*t", now)))
  local epoch = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = s, isdst = false })
  return os.date("%I:%M %p", epoch + utc_offset)
end

-- Build display lines — always one buffer line per item (collapsed view)
local function build_lines()
  local items = current_items()
  if #items == 0 then
    return { "  No commands found." }
  end
  local lines = {}
  for _, item in ipairs(items) do
    local display = item.cmd:gsub("\n.*", " …")
    table.insert(lines, "  " .. display)
  end
  return lines
end

-- Apply virtual lines below toggled items to show full command
local function apply_previews()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns, 0, -1)

  local items = current_items()
  local win_width = is_open() and vim.api.nvim_win_get_width(state.winnr) or 80

  -- Usable width for the main buffer line (accounts for line numbers + prefix)
  local content_width = math.max(20, win_width - 6) -- line numbers ~4 + "  " prefix

  -- Get cursor position to determine which item is selected
  local cursor_row = nil
  if is_open() then
    cursor_row = vim.api.nvim_win_get_cursor(state.winnr)[1]
  end

  for i, item in ipairs(items) do
    if state.toggled[i] then
      local virt_lines = {}
      local prefix = "    "
      local max_w = math.max(20, win_width - #prefix - 4)
      local hl = (i == cursor_row) and HL_SELECTED or "Normal"

      -- Helper to pad line to full window width
      local function pad_line(text)
        local pad = win_width - #text
        if pad > 0 then return text .. string.rep(" ", pad) end
        return text
      end

      -- Word-wrap helper: find last space before limit
      local function word_wrap(text)
        local result = {}
        while #text > max_w do
          local wrap_at = max_w
          local space = text:sub(1, max_w):find("%s[^%s]*$")
          if space and space > 5 then
            wrap_at = space
          end
          table.insert(result, text:sub(1, wrap_at))
          text = text:sub(wrap_at + 1)
        end
        if #text > 0 then
          table.insert(result, text)
        end
        return result
      end

      if item.cmd:find("\n") then
        -- Multi-line command: show lines after the first
        local first = true
        for sub_line in (item.cmd .. "\n"):gmatch("(.-)\n") do
          if first then
            first = false
          else
            for _, wl in ipairs(word_wrap(sub_line)) do
              table.insert(virt_lines, { { pad_line(prefix .. wl), hl } })
            end
          end
        end
      else
        -- Long single-line: show the part that was cut off
        local hidden = item.cmd:sub(content_width + 1)
        for _, wl in ipairs(word_wrap(hidden)) do
          table.insert(virt_lines, { { pad_line(prefix .. wl), hl } })
        end
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

-- Render the current turn into the buffer and update the title
local function render()
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end

  local lines = build_lines()

  -- Update title with timestamp
  local turn = state.turns[state.turn_idx]
  local title = " ccpick "
  if #state.turns > 1 then
    local ts = turn and format_timestamp(turn.timestamp)
    if ts then
      title = string.format(" ccpick [%d/%d] %s ", state.turn_idx, #state.turns, ts)
    else
      title = string.format(" ccpick [%d/%d] ", state.turn_idx, #state.turns)
    end
  end
  if is_open() then
    vim.api.nvim_win_set_config(state.winnr, { title = title, title_pos = "center" })
  end

  -- Update buffer contents
  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)

  -- Clear and reapply highlights
  vim.api.nvim_buf_clear_namespace(state.bufnr, -1, 0, -1)
  if #current_items() == 0 then
    vim.api.nvim_buf_add_highlight(state.bufnr, -1, HL_EMPTY, 0, 0, -1)
  end

  -- Apply virtual line previews for toggled items
  apply_previews()

  -- Resize window to fit (buffer lines + virtual lines)
  local total_visual = #lines
  local items = current_items()
  local win_width = is_open() and vim.api.nvim_win_get_width(state.winnr) or 80
  for i, item in ipairs(items) do
    if state.toggled[i] then
      local cmd_lines = {}
      for sub_line in (item.cmd .. "\n"):gmatch("(.-)\n") do
        table.insert(cmd_lines, sub_line)
      end
      for _, cl in ipairs(cmd_lines) do
        local max_w = math.max(20, win_width - 8)
        total_visual = total_visual + math.max(1, math.ceil(#cl / max_w))
      end
    end
  end
  local height = math.max(1, math.min(total_visual, 12))
  if is_open() then
    vim.api.nvim_win_set_height(state.winnr, height)
  end
end

-- Navigate between turns
local function reset_cursor()
  if is_open() then
    vim.api.nvim_win_set_cursor(state.winnr, { 1, 0 })
  end
end

local function prev_turn()
  local count = vim.v.count1
  state.turn_idx = math.min(state.turn_idx + count, #state.turns)
  state.toggled = {}
  render()
  reset_cursor()
end

local function next_turn()
  local count = vim.v.count1
  state.turn_idx = math.max(state.turn_idx - count, 1)
  state.toggled = {}
  render()
  reset_cursor()
end

local function oldest_turn()
  state.turn_idx = #state.turns
  state.toggled = {}
  render()
  reset_cursor()
end

local function newest_turn()
  state.turn_idx = 1
  state.toggled = {}
  render()
  reset_cursor()
end

-- Jump to the turn where we last copied a command
local function last_copied_turn()
  if not last_copied_timestamp then
    vim.notify("[ccpick] No previous copy", vim.log.levels.INFO)
    return
  end
  for i, turn in ipairs(state.turns) do
    if turn.timestamp == last_copied_timestamp then
      state.turn_idx = i
      state.toggled = {}
      render()
      reset_cursor()
      return
    end
  end
  vim.notify("[ccpick] Previous turn no longer found", vim.log.levels.INFO)
end

-- Copy helper: yanks to clipboard and saves timestamp
local function yank_item(item)
  vim.fn.setreg("+", item.cmd)
  vim.fn.setreg('"', item.cmd)
  local turn = state.turns[state.turn_idx]
  if turn then last_copied_timestamp = turn.timestamp end
end

-- Resolve the item under the cursor
local function item_at_cursor()
  local row = vim.api.nvim_win_get_cursor(state.winnr)[1]
  local items = current_items()
  return items[row]
end

-- Copy selected item to system clipboard and close
local function confirm()
  local item = item_at_cursor()
  if not item then return end
  yank_item(item)
  close()
  local first_line = item.cmd:gsub("\n.*", "")
  vim.notify("[ccpick] Copied: " .. first_line:sub(1, 60), vim.log.levels.INFO)
end

-- Yank selected item without closing
local function yank()
  local item = item_at_cursor()
  if not item then return end
  yank_item(item)
  local first_line = item.cmd:gsub("\n.*", "")
  vim.notify("[ccpick] Yanked: " .. first_line:sub(1, 60), vim.log.levels.INFO)
end

-- Copy all commands from current turn
local function yank_all()
  local items = current_items()
  if #items == 0 then return end
  local cmds = {}
  for _, item in ipairs(items) do
    table.insert(cmds, item.cmd)
  end
  local all = table.concat(cmds, "\n")
  vim.fn.setreg("+", all)
  vim.fn.setreg('"', all)
  local turn = state.turns[state.turn_idx]
  if turn then last_copied_timestamp = turn.timestamp end
  close()
  vim.notify(string.format("[ccpick] Copied all %d commands", #items), vim.log.levels.INFO)
end

-- Check if a command needs preview (multi-line or wider than window)
local function needs_preview(item)
  if item.cmd:find("\n") then return true end
  local win_width = is_open() and vim.api.nvim_win_get_width(state.winnr) or 80
  return (#item.cmd + 2) > win_width -- +2 for "  " prefix
end

-- Toggle preview for item under cursor
local function toggle_item_preview()
  local row = vim.api.nvim_win_get_cursor(state.winnr)[1]
  local items = current_items()
  if row > #items then return end
  if not needs_preview(items[row]) then return end
  state.toggled[row] = not state.toggled[row]
  render()
  vim.api.nvim_win_set_cursor(state.winnr, { row, 0 })
end

local function set_keymaps(bufnr)
  local opts = { noremap = true, silent = true, buffer = bufnr }

  vim.keymap.set("n", "<CR>",    confirm,   opts)
  vim.keymap.set("n", "q",       close,     opts)
  vim.keymap.set("n", "<Esc>",   close,     opts)
  vim.keymap.set("n", "h",       prev_turn, opts)
  vim.keymap.set("n", "<Left>",  prev_turn, opts)
  vim.keymap.set("n", "l",       next_turn,  opts)
  vim.keymap.set("n", "<Right>", next_turn,  opts)
  vim.keymap.set("n", "0",       oldest_turn,      opts)
  vim.keymap.set("n", "$",       newest_turn,      opts)
  vim.keymap.set("n", "_",       last_copied_turn, opts)
  vim.keymap.set("n", "y",       yank,             opts)
  vim.keymap.set("n", "Y",       yank_all,         opts)
  vim.keymap.set("n", "o",       toggle_item_preview, opts)
end

local function win_config(num_lines)
  local ui     = vim.api.nvim_list_uis()[1]
  local width  = math.min(80, math.floor(ui.width * 0.7))
  local height = math.max(1, math.min(num_lines, 12))
  local row    = math.floor((ui.height - height) / 2) - 2
  local col    = math.floor((ui.width - width) / 2)

  return {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    border    = "rounded",
    title     = " ccpick ",
    title_pos = "center",
  }
end

-- Public: open the picker with turns
function M.open(turns)
  if is_open() then close() end

  state.turns = turns or {}
  state.turn_idx = 1

  local lines = build_lines()

  -- Create scratch buffer
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(bufnr, "filetype", "ccpick")
  state.bufnr = bufnr

  -- Open floating window
  local cfg = win_config(math.max(1, #lines))
  local winnr = vim.api.nvim_open_win(bufnr, true, cfg)
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
      -- Only re-apply if any items are toggled
      for _, v in pairs(state.toggled) do
        if v then apply_previews(); return end
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer   = bufnr,
    once     = true,
    callback = function()
      vim.schedule(close)
    end,
  })
end

return M
