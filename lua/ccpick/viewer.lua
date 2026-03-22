local M = {}

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local shimmer_colors = {
  "#c87830", "#d48535", "#e0923a", "#eca03f", "#f0ad44",
  "#eca03f", "#e0923a", "#d48535", "#c87830", "#bc6b2b",
  "#b05e26", "#bc6b2b",
}

local loading_verbs = {
  "Thinking", "Reasoning", "Analyzing", "Pondering", "Considering",
  "Reflecting", "Processing", "Examining", "Studying", "Contemplating",
}

local state = {
  bufnr = nil,
  winnr = nil,
  timer = nil,
  on_close = nil,
  branch = nil,         -- the branch being viewed
  response_starts = {}, -- line numbers where each response starts (for ]] / [[)
  on_follow_up = nil,   -- callback for follow-up asks
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
  local cb = state.on_close
  state.on_close = nil
  if cb then
    vim.schedule(cb)
  end
end

-- Process markdown: strip syntax and track inline code positions
local function process_markdown(text)
  text = text:gsub("\n```[%w_%-]*\n", "\n")
  text = text:gsub("^```[%w_%-]*\n", "")
  text = text:gsub("\n```\n", "\n")
  text = text:gsub("\n```$", "")
  text = text:gsub("\n(#+) ", "\n")
  text = text:gsub("^(#+) ", "")
  text = text:gsub("%*%*(.-)%*%*", "%1")

  local lines = vim.split(text, "\n")
  local highlights = {}

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

-- Build the full conversation thread from a branch's messages + current streaming
local function build_thread(branch)
  local all_lines = {}
  local all_highlights = {}
  local response_starts = {}
  -- Fill separator to window text area (subtract line number gutter ~5 cols)
  local win_width = 60
  if state.winnr and vim.api.nvim_win_is_valid(state.winnr) then
    win_width = vim.api.nvim_win_get_width(state.winnr) - 5
  end
  local separator = string.rep("─", math.max(20, win_width))

  if not branch then return all_lines, all_highlights, response_starts end

  for idx, msg in ipairs(branch.messages) do
    if idx > 1 then
      table.insert(all_lines, separator)
      table.insert(all_lines, "")
    end

    if msg.role == "user" then
      table.insert(all_lines, "You: " .. msg.text)
      table.insert(all_lines, "")
    elseif msg.role == "assistant" then
      table.insert(response_starts, #all_lines + 1) -- 1-based line number
      local text = (msg.text or ""):gsub("^\n+", "")
      local lines, highlights = process_markdown(text)
      local offset = #all_lines
      for _, line in ipairs(lines) do
        table.insert(all_lines, line)
      end
      for _, hl in ipairs(highlights) do
        table.insert(all_highlights, { hl[1] + offset, hl[2], hl[3] })
      end
      table.insert(all_lines, "")
    end
  end

  -- If currently loading/streaming, show the in-progress state
  if branch.status == "loading" or branch.status == "streaming" then
    -- The latest user message might not be in messages yet if follow_up
    -- added it — but it should be since we insert before calling ask.run

    if branch.response ~= "" then
      -- Streaming: show partial response
      table.insert(all_lines, separator)
      table.insert(all_lines, "")
      table.insert(response_starts, #all_lines + 1)
      local text = branch.response:gsub("^\n+", "")
      local lines, highlights = process_markdown(text)
      local offset = #all_lines
      for _, line in ipairs(lines) do
        table.insert(all_lines, line)
      end
      for _, hl in ipairs(highlights) do
        table.insert(all_highlights, { hl[1] + offset, hl[2], hl[3] })
      end
    else
      -- Loading: show placeholder (shimmer will be applied separately)
      table.insert(all_lines, separator)
      table.insert(all_lines, "")
      table.insert(all_lines, "  ⠋ Thinking...")
    end
  end

  return all_lines, all_highlights, response_starts
end

-- Create the floating window
local function create_window(lines, title, opts)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  vim.api.nvim_buf_set_option(bufnr, "filetype", "markdown")
  pcall(vim.treesitter.start, bufnr, "markdown")
  state.bufnr = bufnr

  local ui = vim.api.nvim_list_uis()[1]
  local width = ui.width - 10
  local height = ui.height - 16
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

  -- Keymaps
  local kopts = { noremap = true, silent = true, buffer = bufnr }
  vim.keymap.set("n", "q",     close, kopts)
  vim.keymap.set("n", "<Esc>", close, kopts)

  -- Jump to next/previous response
  vim.keymap.set("n", "]]", function()
    local cursor = vim.api.nvim_win_get_cursor(state.winnr)[1]
    for _, start in ipairs(state.response_starts) do
      if start > cursor then
        vim.api.nvim_win_set_cursor(state.winnr, { start, 0 })
        return
      end
    end
  end, kopts)

  vim.keymap.set("n", "[[", function()
    local cursor = vim.api.nvim_win_get_cursor(state.winnr)[1]
    for i = #state.response_starts, 1, -1 do
      if state.response_starts[i] < cursor then
        vim.api.nvim_win_set_cursor(state.winnr, { state.response_starts[i], 0 })
        return
      end
    end
  end, kopts)

  -- Check if branch is busy before allowing follow-up
  local function check_busy()
    if state.branch and (state.branch.status == "loading" or state.branch.status == "streaming") then
      vim.notify("[ccpick] Waiting for response — try again after.", vim.log.levels.WARN)
      return true
    end
    return false
  end

  -- Follow-up ask: \ca in the viewer (visual mode)
  vim.keymap.set("v", "<leader>ca", function()
    if check_busy() then return end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    vim.schedule(function()
      local start_pos = vim.fn.getpos("'<")
      local end_pos = vim.fn.getpos("'>")
      local sel_lines = vim.fn.getline(start_pos[2], end_pos[2])
      if type(sel_lines) == "string" then sel_lines = { sel_lines } end
      local selected = table.concat(sel_lines, "\n")

      vim.ui.input({ prompt = "Follow up: " }, function(prompt)
        if prompt == nil then return end
        if prompt == "" then
          prompt = "Explain this further."
        end
        if state.on_follow_up then
          state.on_follow_up(prompt, selected)
        end
      end)
    end)
  end, kopts)

  -- Follow-up ask: \ca in the viewer (normal mode)
  vim.keymap.set("n", "<leader>ca", function()
    if check_busy() then return end
    vim.ui.input({ prompt = "Follow up: " }, function(prompt)
      if prompt == nil then return end
      if prompt == "" then
        prompt = "Can you elaborate on your response?"
      end
      if state.on_follow_up then
        state.on_follow_up(prompt, nil)
      end
    end)
  end, kopts)
end

-- Apply highlights to the buffer
local function apply_highlights(code_highlights)
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
  local ns_code = vim.api.nvim_create_namespace("ccpick_inline_code")
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns_code, 0, -1)
  for _, hl in ipairs(code_highlights) do
    pcall(vim.api.nvim_buf_add_highlight, state.bufnr, ns_code, "CcpickInlineCode", hl[1], hl[2], hl[3])
  end

  -- Highlight separator lines and "You:" labels
  local ns_thread = vim.api.nvim_create_namespace("ccpick_thread")
  vim.api.nvim_buf_clear_namespace(state.bufnr, ns_thread, 0, -1)
  local line_count = vim.api.nvim_buf_line_count(state.bufnr)
  for i = 0, line_count - 1 do
    local line = vim.api.nvim_buf_get_lines(state.bufnr, i, i + 1, false)[1] or ""
    if line:match("^─+$") then
      pcall(vim.api.nvim_buf_add_highlight, state.bufnr, ns_thread, "Comment", i, 0, -1)
    elseif line:match("^You: ") then
      pcall(vim.api.nvim_buf_add_highlight, state.bufnr, ns_thread, "CcpickTitle", i, 0, 4)
    end
  end
end

-- Render a branch's full thread into the viewer
local function render_branch(branch, title)
  local lines, highlights, starts = build_thread(branch)
  state.response_starts = starts

  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end

  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)

  apply_highlights(highlights)

  -- Start shimmer timer for loading state
  if branch.status == "loading" and branch.response == "" then
    stop_timer()
    local frame = 0
    local shimmer_idx = 0
    local verb_idx = 1
    local verb_ticks = 0
    local ns_loading = vim.api.nvim_create_namespace("ccpick_loading")
    local loading_line = #lines - 1 -- 0-based index of the "Thinking..." line

    state.timer = vim.uv.new_timer()
    state.timer:start(0, 250, vim.schedule_wrap(function()
      if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
        stop_timer()
        return
      end
      -- Stop if branch is no longer loading
      if not state.branch or state.branch.status ~= "loading" or state.branch.response ~= "" then
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
      vim.api.nvim_set_hl(0, "CcpickShimmer", { fg = shimmer_colors[shimmer_idx] })
      local text = "  " .. spinner_frames[frame] .. " " .. loading_verbs[verb_idx] .. "..."
      local lcount = vim.api.nvim_buf_line_count(state.bufnr)
      if loading_line < lcount then
        vim.api.nvim_buf_set_option(state.bufnr, "modifiable", true)
        vim.api.nvim_buf_set_lines(state.bufnr, loading_line, loading_line + 1, false, { text })
        vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)
        vim.api.nvim_buf_clear_namespace(state.bufnr, ns_loading, loading_line, loading_line + 1)
        vim.api.nvim_buf_add_highlight(state.bufnr, ns_loading, "CcpickShimmer", loading_line, 0, -1)
      end
    end))
  else
    stop_timer()
  end
end

-- Show an animated loading indicator
function M.show_loading(title)
  if is_open() then close() end
  state.branch = nil
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
    vim.api.nvim_set_hl(0, "CcpickShimmer", { fg = shimmer_colors[shimmer_idx] })
    local text = "  " .. spinner_frames[frame] .. " " .. loading_verbs[verb_idx] .. "..."
    vim.api.nvim_buf_set_option(state.bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { text })
    vim.api.nvim_buf_set_option(state.bufnr, "modifiable", false)
    vim.api.nvim_buf_clear_namespace(state.bufnr, ns_loading, 0, -1)
    vim.api.nvim_buf_add_highlight(state.bufnr, ns_loading, "CcpickShimmer", 0, 0, -1)
  end))
end

-- Open the viewer with a branch's full conversation thread
function M.open_branch(branch, title)
  if is_open() then close() end
  state.branch = branch
  create_window({ "" }, title or "claude")
  render_branch(branch, title)
end

-- Start streaming mode for a branch
function M.start_streaming(branch, title)
  stop_timer()
  state.branch = branch
  if is_open() then
    vim.wo[state.winnr].cursorline = true
    vim.wo[state.winnr].number = true
    vim.wo[state.winnr].relativenumber = true
    render_branch(branch, title)
  else
    local lines, highlights, starts = build_thread(branch)
    state.response_starts = starts
    create_window(lines, title or "claude")
    apply_highlights(highlights)
  end
end

-- Update the viewer with the branch's current state (called during polling)
function M.update_branch(branch, title)
  if not is_open() then return end
  if not state.branch or state.branch.id ~= branch.id then return end
  render_branch(branch, title)
  -- Keep cursor at the start of the latest response while streaming
  if #state.response_starts > 0 then
    local last_start = state.response_starts[#state.response_starts]
    vim.api.nvim_win_set_cursor(state.winnr, { last_start, 0 })
  end
end

-- Mark streaming as complete
function M.done_streaming()
  -- Final render to include the response in messages
  if state.branch then
    render_branch(state.branch)
  end
end

function M.close()
  close()
end

function M.is_open()
  return is_open()
end

function M.set_on_close(cb)
  state.on_close = cb
end

-- Set callback for follow-up asks from inside the viewer
function M.set_on_follow_up(cb)
  state.on_follow_up = cb
end

-- Get the current branch being viewed
function M.get_branch()
  return state.branch
end

-- Toggle with a branch
function M.toggle_branch(branch, title)
  if is_open() then
    close()
    return
  end
  if branch then
    M.open_branch(branch, title)
  else
    vim.notify("[ccpick] No response to show.", vim.log.levels.INFO)
  end
end

return M
