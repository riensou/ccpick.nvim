local M = {}

-- Strip ANSI escape codes from a string
local function strip_ansi(s)
  return s:gsub("\27%[[%d;]*m", ""):gsub("\27%[[%d;]*[A-Za-z]", "")
end

-- Split a shell code block into individual commands, respecting \ continuations.
-- Comment-only lines and blank lines are dropped.
local function split_shell_commands(code)
  local commands = {}
  local current = nil

  for line in (code .. "\n"):gmatch("(.-)\n") do
    local trimmed = vim.trim(line)

    -- skip blank lines and comment-only lines (unless continuing a command)
    if current == nil and (trimmed == "" or trimmed:match("^#")) then
      -- skip
    else
      if current then
        current = current .. "\n" .. line
      else
        current = line
      end

      -- if line ends with \, keep accumulating
      if trimmed:match("\\$") then
        -- continue
      else
        local result = vim.trim(current)
        if result ~= "" then
          table.insert(commands, result)
        end
        current = nil
      end
    end
  end

  -- flush any trailing continued line
  if current then
    local result = vim.trim(current)
    if result ~= "" then
      table.insert(commands, result)
    end
  end

  return commands
end

local shell_langs = { bash = true, sh = true, zsh = true }

-- Extract fenced code blocks from a markdown string.
-- Returns list of { cmd = string, lang = string }
-- Shell blocks with multiple commands are split into separate items.
local function extract_blocks(text)
  local blocks = {}
  -- Match ```lang\n...\n``` patterns (non-greedy)
  for lang, code in text:gmatch("```([%w_%-]*)\n(.-)\n```") do
    local trimmed = vim.trim(code)
    if trimmed == "" then goto continue end

    lang = lang ~= "" and lang or "text"

    if shell_langs[lang] then
      local cmds = split_shell_commands(trimmed)
      for _, cmd in ipairs(cmds) do
        table.insert(blocks, { cmd = cmd, lang = lang })
      end
    else
      table.insert(blocks, { cmd = trimmed, lang = lang })
    end

    ::continue::
  end
  return blocks
end

-- Pull text content out of an assistant message's content array.
-- Claude Code stores content as either a plain string or an array of blocks.
local function message_text(msg)
  local content = msg.message and msg.message.content
  if not content then return nil end

  if type(content) == "string" then
    return content
  end

  if type(content) == "table" then
    local parts = {}
    for _, block in ipairs(content) do
      if type(block) == "table" and block.type == "text" and block.text then
        table.insert(parts, block.text)
      end
    end
    return table.concat(parts, "\n")
  end

  return nil
end

-- Filter blocks by language
local function filter_blocks(blocks, langs)
  if not langs or #langs == 0 then return blocks end
  local filtered = {}
  for _, block in ipairs(blocks) do
    if block.lang == "text" then
      table.insert(filtered, block)
    else
      for _, l in ipairs(langs) do
        if block.lang == l then
          table.insert(filtered, block)
          break
        end
      end
    end
  end
  return filtered
end

-- Public: parse a JSONL file and return commands grouped by turn.
-- Returns a list of turns ordered most-recent-first, where each turn
-- is a list of { cmd, lang } items. Only turns with commands are included.
-- opts.langs = list of languages to include (nil/empty = all)
function M.parse_by_turn(jsonl_path, opts)
  opts = opts or {}
  local langs = opts.langs

  local f, err = io.open(jsonl_path, "r")
  if not f then
    return nil, "Cannot open " .. jsonl_path .. ": " .. (err or "")
  end

  -- Collect all assistant messages in order
  local assistant_msgs = {}
  for line in f:lines() do
    if line ~= "" then
      local ok, obj = pcall(vim.json.decode, line)
      if ok and type(obj) == "table" and obj.type == "assistant" then
        table.insert(assistant_msgs, obj)
      end
    end
  end
  f:close()

  -- Process each assistant message into a turn, most-recent-first
  -- Each turn is { items = {...}, timestamp = "..." }
  local turns = {}
  for i = #assistant_msgs, 1, -1 do
    local msg = assistant_msgs[i]
    local text = message_text(msg)
    if text then
      text = strip_ansi(text)
      local blocks = filter_blocks(extract_blocks(text), langs)
      if #blocks > 0 then
        table.insert(turns, {
          items = blocks,
          timestamp = msg.timestamp,
        })
      end
    end
  end

  return turns, nil
end

return M
