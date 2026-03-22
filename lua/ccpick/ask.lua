local M = {}

-- Run claude -p with streaming output.
-- on_chunk(text) is called as new text arrives.
-- on_done(exit_code) is called when the process exits.
function M.run(prompt, code, on_chunk, on_done, opts)
  opts = opts or {}
  local cmd = {
    "claude", "-p", "--continue",
    "--output-format", "stream-json", "--verbose",
    "--system-prompt", "You are a helpful coding assistant. Answer questions about code directly. Do not use any tools. Respond concisely.",
  }
  if opts.fork then
    table.insert(cmd, "--fork-session")
  end

  -- If we have code context, prepend it to the prompt
  local full_prompt = prompt
  if code and code ~= "" then
    full_prompt = "Here is the code:\n```\n" .. code .. "\n```\n\n" .. prompt
  end
  table.insert(cmd, full_prompt)

  local last_text = ""
  local result_text = nil

  local function process_line(line)
    if line == "" then return end
    local ok, obj = pcall(vim.json.decode, line)
    if not ok or type(obj) ~= "table" then return end

    if obj.type == "assistant" then
      local content = obj.message and obj.message.content
      if type(content) == "table" then
        local full_text = ""
        for _, block in ipairs(content) do
          if block.type == "text" and block.text then
            full_text = full_text .. block.text
          end
        end
        if #full_text > #last_text then
          local new_text = full_text:sub(#last_text + 1)
          last_text = full_text
          vim.schedule(function()
            on_chunk(new_text)
          end)
        end
      end
    elseif obj.type == "result" and obj.result then
      result_text = obj.result
    end
  end

  vim.fn.jobstart(cmd, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then return end
      -- Neovim splits on newlines: each element is a line,
      -- last element may be partial (empty string if complete)
      for _, line in ipairs(data) do
        process_line(line)
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if last_text == "" and result_text and result_text ~= "" then
          on_chunk(result_text)
        end
        on_done(exit_code)
      end)
    end,
  })
end

return M
