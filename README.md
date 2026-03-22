# ccpick.nvim

A Neovim plugin for working with Claude Code sessions. Pick commands from Claude's responses, ask Claude questions about your code, and manage multiple conversation threads — all without leaving your editor.

---

## Features

- **Command Picker** — extract and copy shell commands from Claude Code's responses
- **Ask Claude** — select code and ask questions, with streaming responses
- **Conversation Threads** — follow-up questions with full Q&A history
- **Branch Manager** — track multiple concurrent conversations
- **Theme Integration** — inherits your Neovim colorscheme automatically

---

## Requirements

- Neovim 0.9+
- Claude Code CLI (sessions saved to `~/.claude/projects/`, which is the default)

---

## Install

**vim-plug**
```vim
Plug 'riensou/ccpick.nvim'
```

**lazy.nvim**
```lua
{
  "riensou/ccpick.nvim",
  config = function()
    require("ccpick").setup()
  end,
}
```

vim-plug users, add the setup call to `init.vim`:
```vim
lua << EOF
require("ccpick").setup()
EOF
```

---

## Usage

### Command Picker (`<leader>cc`)

Opens a floating picker with shell commands extracted from Claude Code's session.

| Key | Action |
|-----|--------|
| `j` / `k` | Navigate commands (all vim motions work, including `/search`) |
| `Enter` | Copy command to clipboard and close |
| `y` | Yank command to clipboard without closing |
| `Y` | Yank all commands from current response |
| `o` | Toggle preview of truncated/multi-line commands |
| `h` / `l` | Browse older / newer Claude responses (supports counts: `3h`) |
| `0` / `$` | Jump to oldest / newest response |
| `_` | Jump to the response you last copied from |
| `q` / `Esc` | Close |

### Ask Claude (`<leader>ca`)

Ask Claude a question about your code. Works in both visual and normal mode.

- **Visual mode**: select code, press `<leader>ca`, type your question. The selected code is sent as context.
- **Normal mode**: press `<leader>ca` to send the entire current file as context.
- **Empty prompt**: defaults to "Explain what this code does, how it works, and why it's written this way."

Questions run in the background via `claude -p --continue` — you can keep editing while Claude thinks.

### Response Viewer (`<leader>cv`)

Toggle the response viewer for the most recent conversation.

| Key | Action |
|-----|--------|
| `]]` / `[[` | Jump to next / previous response in thread |
| `<leader>ca` | Ask a follow-up question (normal mode: plain follow-up, visual mode: ask about selected text from the response) |
| `q` / `Esc` | Close |

The viewer shows the full conversation thread:

```
You: explain this function
─────────────────────────────────────────────────
The function parses JSONL files by reading each line...
─────────────────────────────────────────────────
You: what about error handling?
─────────────────────────────────────────────────
Good question. The error handling works by...
```

While Claude is thinking, an animated loading indicator appears with a warm shimmer effect.

### Claude Manager (`<leader>cm`)

View and manage all conversation branches.

| Key | Action |
|-----|--------|
| `j` / `k` | Navigate branches |
| `Enter` | Open a branch's conversation in the viewer |
| `o` | Preview the prompt and line range |
| `dd` | Delete a branch |
| `D` | Prune all completed branches |
| `q` / `Esc` | Close |

Each branch shows: filename, line range (e.g. `L5-L20`), and status (`loading`, `streaming`, `done`, `error`). Active branches display an animated spinner with a shimmer effect. Closing a viewer opened from the manager returns you to the manager.

---

## Configuration

All options with their defaults:

```lua
require("ccpick").setup({
  -- Keymaps
  keymap          = "<leader>cc",   -- command picker
  ask_keymap      = "<leader>ca",   -- ask Claude
  view_keymap     = "<leader>cv",   -- toggle response viewer
  manager_keymap  = "<leader>cm",   -- toggle branch manager

  -- Which code block languages to show in the picker.
  -- Empty table = show all. Untagged blocks are always included.
  langs = { "bash", "sh", "zsh" },

  -- Highlight groups (linked to standard Neovim groups by default)
  highlights = {
    available   = { link = "Normal" },
    selected    = { link = "PmenuSel" },
    title       = { link = "Directory" },
    empty       = { link = "Comment" },
    inline_code = { link = "Function" },
  },
})
```

---

## How it works

**Command Picker**: Claude Code saves every session as a JSONL file under `~/.claude/projects/`. ccpick finds the most recent session matching your current working directory, parses assistant messages, and extracts fenced code blocks. Multi-line shell blocks are split into individual commands (respecting `\` continuations).

**Ask Claude**: Runs `claude -p --continue` as a background job with `--output-format stream-json` for real-time streaming. Responses are displayed in a floating viewer with markdown processing (inline code highlighting, heading/bold/fence stripping). The `--continue` flag shares context with the active Claude Code session.

**Follow-ups**: Each conversation is tracked as a "branch" with a message history. Follow-up questions use a dual approach — if the branch was the last to interact with the session, it uses `--continue` directly (efficient). If other interactions happened since, it prepends the conversation history to the prompt to restore context.

No daemons, no background processes, no external dependencies beyond Claude Code. Pure Lua.

---

## License

MIT
