local M = {}

-- Run claude -p --continue with the given prompt and optional code context.
-- Calls on_done(response_text, exit_code) when finished.
-- Runs from the project root so --continue picks up the right session.
function M.run(prompt, code, on_done)
  local cmd = { "claude", "-p", "--continue" }

  -- If we have code context, prepend it to the prompt
  local full_prompt = prompt
  if code and code ~= "" then
    full_prompt = "Here is the code:\n```\n" .. code .. "\n```\n\n" .. prompt
  end
  table.insert(cmd, full_prompt)

  local stdout_chunks = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout_chunks, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      local response = table.concat(stdout_chunks, "\n")
      vim.schedule(function()
        on_done(response, exit_code)
      end)
    end,
  })
end

return M
