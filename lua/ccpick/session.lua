local M = {}

-- Encode a filesystem path the way Claude Code does:
-- replace "/" with "-" and strip the leading "-"
local function encode_path(p)
  return p:gsub("/", "-"):gsub("^%-", "")
end

-- Return the ~/.claude/projects/ base directory
local function projects_dir()
  return vim.fn.expand("~/.claude/projects")
end

-- Find the most recently modified .jsonl file under a directory
local function latest_jsonl(dir)
  local files = vim.fn.glob(dir .. "/**/*.jsonl", false, true)
  if not files or #files == 0 then
    return nil
  end

  local newest = nil
  local newest_time = 0

  for _, f in ipairs(files) do
    -- skip agent sub-session files
    if not f:match("agent%-") then
      local stat = vim.loop.fs_stat(f)
      if stat and stat.mtime.sec > newest_time then
        newest_time = stat.mtime.sec
        newest = f
      end
    end
  end

  return newest
end

-- Primary strategy: match by cwd or any parent directory
local function find_by_cwd()
  local dir = vim.fn.getcwd()

  -- walk up the tree until we find a matching project or hit home/root
  local home = vim.fn.expand("~")
  while dir ~= "" and dir ~= "/" and dir ~= home do
    local encoded = encode_path(dir)
    local project_dir = projects_dir() .. "/" .. encoded

    if vim.fn.isdirectory(project_dir) == 1 then
      local found = latest_jsonl(project_dir)
      if found then return found end
    end

    -- go up one level
    dir = vim.fn.fnamemodify(dir, ":h")
  end

  return nil
end

-- Fallback: most recently modified jsonl across all projects
local function find_latest_global()
  return latest_jsonl(projects_dir())
end

-- Public: return the best jsonl path, or nil with an error message
function M.find()
  local path = find_by_cwd()
  if path then
    return path, nil
  end

  path = find_latest_global()
  if path then
    return path, nil
  end

  return nil, "No Claude Code session found in ~/.claude/projects/"
end

return M
