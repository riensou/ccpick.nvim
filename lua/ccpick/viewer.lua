local M = {}

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

-- Warm shimmer gradient: amber/orange tones that cycle
local shimmer_colors = {
  "#c87830",
  "#d48535",
  "#e0923a",
  "#eca03f",
  "#f0ad44",
  "#eca03f",
  "#e0923a",
  "#d48535",
  "#c87830",
  "#bc6b2b",
  "#b05e26",
  "#bc6b2b",
}

local loading_verbs = {
  "Thinking",
  "Reasoning",
  "Analyzing",
  "Pondering",
  "Considering",
  "Reflecting",
  "Processing",
  "Examining",
  "Studying",
  "Contemplating",
}

local state = {
  bufnr = nil,
  winnr = nil,
  timer = nil,
}

local function is_open()
  return state.winnr ~= nil and vim.api.nvim_win_is_valid(state.winnr)
end

local function stop_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function close()
  stop_timer()
  if is_open() then
    vim.api.nvim_win_close(state.winnr, true)
  end
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.api.nvim_buf_delete(state.bufnr, { force = true })
  end
  state.winnr = nil
  state.bufnr = nil
end

-- Create the floating window
local function create_window(lines, title, opts)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  vim.api.nvim_buf_set_option(bufnr, "filetype", "markdown")
  -- Enable treesitter highlighting for markdown
  pcall(vim.treesitter.start, bufnr, "markdown")
  state.bufnr = bufnr

  local ui = vim.api.nvim_list_uis()[1]
  local max_width = ui.width - 10
  local max_height = ui.height - 4

  -- Fit to content, with min/max bounds
  local width = max_width
  local content_height = #lines
  -- Account for wrapped lines
  for _, line in ipairs(lines) do
    if #line > max_width then
      content_height = content_height + math.floor(#line / max_width)
    end
  end
  local height = math.max(5, math.min(content_height + 2, max_height))
  local row = math.floor((ui.height - height) / 2) - 1
  local col = math.floor((ui.width - width) / 2)

  local winnr = vim.api.nvim_open_win(bufnr, true, {
    relative  = "editor",
    width     = width,
    height    = height,
    row       = row,
    col       = col,
    border    = "rounded",
    title     = " " .. title .. " ",
    title_pos = "center",
  })
  vim.wo[winnr].wrap = true
  vim.wo[winnr].linebreak = true
  vim.wo[winnr].breakindent = true
  vim.wo[winnr].conceallevel = 0
  opts = opts or {}
  local show_numbers = opts.numbers ~= false
  vim.wo[winnr].cursorline = show_numbers
  vim.wo[winnr].number = show_numbers
  vim.wo[winnr].relativenumber = show_numbers
  vim.wo[winnr].signcolumn = "no"
  vim.wo[winnr].foldcolumn = "0"
  vim.wo[winnr].spell = false
  vim.wo[winnr].winhighlight = "FloatBorder:CcpickTitle,FloatTitle:CcpickTitle"
  state.winnr = winnr

  local opts = { noremap = true, silent = true, buffer = bufnr }
  vim.keymap.set("n", "q",     close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
end

-- Show an animated loading indicator while waiting for Claude
function M.show_loading(title)
  if is_open() then close() end
  create_window({ "" }, title or "claude", { numbers = false })

  local frame = 0
  local shimmer_idx = 0
  local verb_idx = 1
  local verb_ticks = 0
  local ns_loading = vim.api.nvim_create_namespace("ccpick_loading")

  state.timer = vim.uv.new_timer()
  state.timer:start(0, 250, vim.schedule_wrap(function()
    if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
      stop_timer()
      return
    end

    frame = (frame % #spinner_frames) + 1
    shimmer_idx = (shimmer_idx % #shimmer_colors) + 1
    verb_ticks = verb_ticks + 1
    if verb_ticks >= 15 then
      verb_ticks = 0
      verb_idx = (verb_idx % #loading_verbs) + 1
    end

    -- Update shimmer highlight
    vim.api.nvim_set_hl(0, "CcpickShimmer", { fg = shimmer_colors[shimmer_idx] })

    local text = "  " .. spinner_frames[frame] .. " " .. loading_verbs[verb_idx] .. "..."
    vim.api.nvim_buf_set_option(state.bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { text })
    vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)
    vim.api.nvim_buf_clear_namespace(state.bufnr, ns_loading, 0, -1)
    vim.api.nvim_buf_add_highlight(state.bufnr, ns_loading, "CcpickShimmer", 0, 0, -1)
  end))
end

-- Process markdown: strip syntax and track inline code positions for highlighting
local function process_markdown(text)
  -- Remove code fence lines
  text = text:gsub("\n```[%w_%-]*\n", "\n")
  text = text:gsub("^```[%w_%-]*\n", "")
  text = text:gsub("\n```\n", "\n")
  text = text:gsub("\n```$", "")
  -- Remove heading markers but keep the text
  text = text:gsub("\n(#+) ", "\n")
  text = text:gsub("^(#+) ", "")
  -- Remove bold markers
  text = text:gsub("%*%*(.-)%*%*", "%1")

  -- Process inline backticks: strip them and record positions
  local lines = vim.split(text, "\n")
  local highlights = {} -- { line_idx, col_start, col_end }

  for i, line in ipairs(lines) do
    local new_line = ""
    local pos = 1
    while pos <= #line do
      local bstart = line:find("`", pos, true)
      if not bstart then
        new_line = new_line .. line:sub(pos)
        break
      end
      new_line = new_line .. line:sub(pos, bstart - 1)
      local bend = line:find("`", bstart + 1, true)
      if not bend then
        new_line = new_line .. line:sub(bstart)
        break
      end
      local code_text = line:sub(bstart + 1, bend - 1)
      local col_start = #new_line
      new_line = new_line .. code_text
      local col_end = #new_line
      table.insert(highlights, { i - 1, col_start, col_end })
      pos = bend + 1
    end
    lines[i] = new_line
  end

  return lines, highlights
end

-- Replace loading content with the actual response
function M.open(text, title)
  if is_open() then close() end
  local lines, code_highlights = process_markdown(text)
  create_window(lines, title or "claude")

  -- Apply inline code highlights
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    local ns_code = vim.api.nvim_create_namespace("ccpick_inline_code")
    for _, hl in ipairs(code_highlights) do
      vim.api.nvim_buf_add_highlight(state.bufnr, ns_code, "CcpickInlineCode", hl[1], hl[2], hl[3])
    end
  end
end

-- Close the viewer
function M.close()
  close()
end

return M
