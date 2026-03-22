local ask = require("ccpick.ask")

local M = {}

-- All branches, ordered by creation time (newest first when displayed)
-- Each branch: {
--   id           = number,
--   prompt       = string,
--   code         = string,
--   file         = string,      -- source file name
--   status       = "loading" | "streaming" | "done" | "error",
--   response     = string,      -- accumulated response text
--   messages     = { {role, text}, ... },  -- conversation history (for future follow-ups)
--   created_at   = number,      -- os.time()
-- }
local branches = {}
local next_id = 1

-- Create a new branch and start the ask
function M.create(prompt, code, file, line_range, opts)
  opts = opts or {}
  local branch = {
    id = next_id,
    prompt = prompt,
    code = code,
    file = file or "",
    line_range = line_range, -- { start, end } or nil for whole file
    fork = opts.fork or false,
    status = "loading",
    response = "",
    messages = {
      { role = "user", text = prompt },
    },
    created_at = os.time(),
  }
  next_id = next_id + 1
  table.insert(branches, 1, branch) -- newest first

  -- Start the ask
  ask.run(prompt, code, function(chunk)
    -- on_chunk
    if branch.status == "loading" then
      branch.status = "streaming"
    end
    branch.response = branch.response .. chunk
  end, function(exit_code)
    -- on_done: always mark as done/error, regardless of exit code
    if branch.response ~= "" then
      branch.status = "done"
      table.insert(branch.messages, { role = "assistant", text = branch.response })
      last_session_branch_id = branch.id
    elseif exit_code ~= 0 then
      branch.status = "error"
    else
      branch.status = "done"
    end
  end, {})

  return branch
end

-- Get all branches
function M.list()
  return branches
end

-- Get a branch by ID
function M.get(id)
  for _, b in ipairs(branches) do
    if b.id == id then return b end
  end
  return nil
end

-- Delete a branch by ID
function M.delete(id)
  for i, b in ipairs(branches) do
    if b.id == id then
      table.remove(branches, i)
      return true
    end
  end
  return false
end

-- Delete all completed/error branches
function M.prune()
  local kept = {}
  for _, b in ipairs(branches) do
    if b.status == "loading" or b.status == "streaming" then
      table.insert(kept, b)
    end
  end
  branches = kept
end

-- Track the ID of the branch that most recently wrote to the session
local last_session_branch_id = nil

-- Build a context string from a branch's conversation history
local function build_context(branch)
  local parts = {}
  table.insert(parts, "Here is our previous conversation for context:")
  table.insert(parts, "")
  for _, msg in ipairs(branch.messages) do
    if msg.role == "user" then
      table.insert(parts, "User: " .. msg.text)
    elseif msg.role == "assistant" then
      table.insert(parts, "Assistant: " .. msg.text)
    end
    table.insert(parts, "")
  end
  table.insert(parts, "Now, please respond to the following:")
  table.insert(parts, "")
  return table.concat(parts, "\n")
end

-- Check if a branch is busy (loading or streaming)
function M.is_busy(branch)
  return branch.status == "loading" or branch.status == "streaming"
end

-- Send a follow-up message on an existing branch
function M.follow_up(branch, prompt, code)
  if M.is_busy(branch) then
    vim.notify("[ccpick] Waiting for response — try again after.", vim.log.levels.WARN)
    return false
  end

  -- Dual approach: if this branch was the last to use the session,
  -- just --continue (Option B). Otherwise, prepend context (Option A).
  local full_prompt = prompt
  if last_session_branch_id ~= branch.id then
    full_prompt = build_context(branch) .. prompt
  end

  table.insert(branch.messages, { role = "user", text = prompt })

  branch.status = "loading"
  branch.response = ""

  ask.run(full_prompt, code, function(chunk)
    if branch.status == "loading" then
      branch.status = "streaming"
    end
    branch.response = branch.response .. chunk
  end, function(exit_code)
    if branch.response ~= "" then
      branch.status = "done"
      table.insert(branch.messages, { role = "assistant", text = branch.response })
      last_session_branch_id = branch.id
    elseif exit_code ~= 0 then
      branch.status = "error"
    else
      branch.status = "done"
    end
  end, {})

  return true
end

-- Get count of active (loading/streaming) branches
function M.active_count()
  local count = 0
  for _, b in ipairs(branches) do
    if b.status == "loading" or b.status == "streaming" then
      count = count + 1
    end
  end
  return count
end

return M
