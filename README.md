# ccpick.nvim

> Keyboard-driven command picker for Claude Code sessions.

<!-- Record a GIF and drop it here before posting to r/neovim -->

When Claude Code gives you shell commands to run, stop reaching for the mouse.
Hit `\cc`, navigate with `j`/`k`, press `Enter` to copy to clipboard. Switch to
your terminal and paste.

---

## The problem

You use Claude Code in one terminal pane. Your shell is in another. Claude gives
you commands to run. Getting them from one pane to the other means mouse
selecting, copying, switching windows, pasting — over and over.

## The solution

ccpick reads Claude Code's session transcript directly from
`~/.claude/projects/`, finds all code blocks in the latest response, and shows
them in a floating picker window inside Neovim. Keyboard only. No mouse. No
context switching until you're ready.

---

## Requirements

- Neovim 0.9+
- Claude Code (sessions must be saved to `~/.claude/projects/`, which is the default)

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

Then add the setup call (vim-plug users add this to `init.vim`):
```vim
lua << EOF
require("ccpick").setup()
EOF
```

---

## Usage

| Key | Action |
|-----|--------|
| `\cc` | Open picker (default) |
| `j` / `k` | Move selection down / up |
| `Enter` | Copy selected command to clipboard and close |
| `q` / `Esc` | Close without copying |

---

## Configuration

All options with their defaults:

```lua
require("ccpick").setup({
  -- Key to open the picker (\ is the default leader key)
  keymap = "<leader>cc",

  -- Languages to include. Empty table = show all code blocks.
  -- Untagged blocks (no language specified) are always included.
  langs = { "bash", "sh", "zsh" },

  -- How many recent Claude responses to scan for commands
  turns = 1,

  -- Highlight colors
  highlights = {
    available = { bg = "#1e3a5f", fg = "#a8c8e8" },  -- unselected (muted blue)
    selected  = { bg = "#1a6fc4", fg = "#ffffff" },  -- selected (bright blue)
    title     = { fg = "#a8c8e8", bold = true },
    empty     = { fg = "#666666", italic = true },
  },
})
```

**Show commands from the last few responses:**
```lua
require("ccpick").setup({ turns = 3 })
```

**Show all code blocks regardless of language:**
```lua
require("ccpick").setup({ langs = {} })
```

---

## How it works

Claude Code automatically saves every session as a JSONL file under
`~/.claude/projects/`. ccpick finds the most recent session matching your
current working directory, parses the assistant messages, and extracts fenced
code blocks. No daemons, no background processes, no external dependencies.
Pure Lua.

---

## License

MIT
