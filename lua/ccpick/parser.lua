local M = {}

-- Strip ANSI escape codes from a string
local function strip_ansi(s)
  return s:gsub("\27%[[%d;]*m", ""):gsub("\27%[[%d;]*[A-Za-z]", "")
end

-- Extract fenced code blocks from a markdown string.
-- Returns list of { cmd = string, lang = string }
local function extract_blocks(text)
  local blocks = {}
  -- Match ```lang\n...\n``` patterns (non-greedy)
  for lang, code in text:gmatch("```([%w_%-]*)\n(.-)\n```") do
    local trimmed = vim.trim(code)
    if trimmed ~= "" then
      table.insert(blocks, {
        cmd  = trimmed,
        lang = lang ~= "" and lang or "text",
      })
    end
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

-- Public: parse a JSONL file and return all code blocks from the
-- most recent assistant turn, or from the last N assistant turns.
-- opts.langs  = list of languages to include, e.g. {"bash","sh","zsh"}
--               nil/empty means include all languages
-- opts.turns  = how many recent assistant turns to scan (default 1)
function M.parse(jsonl_path, opts)
  opts = opts or {}
  local langs  = opts.langs  -- nil = all
  local turns  = opts.turns or 1

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

  if #assistant_msgs == 0 then
    return {}, nil
  end

  -- Take the last `turns` assistant messages
  local start = math.max(1, #assistant_msgs - turns + 1)
  local results = {}

  for i = start, #assistant_msgs do
    local text = message_text(assistant_msgs[i])
    if text then
      text = strip_ansi(text)
      local blocks = extract_blocks(text)
      for _, block in ipairs(blocks) do
        local include = true
  local include = true
  if langs and #langs > 0 then
    include = false
  -- always include untagged blocks (lang == "text")
    if block.lang == "text" then
      include = true
    else
      for _, l in ipairs(langs) do
        if block.lang == l then
          include = true
          break
        end
      end
    end
  end
        if include then
          table.insert(results, block)
        end
      end
    end
  end

  return results, nil
end

return M
