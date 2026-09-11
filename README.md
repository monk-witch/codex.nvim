# codex.nvim

> A terminal-independent NeoVim client for the [Codex App Server](https://learn.chatgpt.com/docs/app-server).

`codex.nvim` brings an existing local Codex chat into the current NeoVim session without taking ownership of your terminal layout. Keep Codex CLI in kitty, tmux, Sway, a different terminal, or no visible terminal at all—the plugin connects to Codex's local App Server, not to a terminal pane.

## Status

**0.0.14 — idempotent setup with guarded short command aliases.** The public API is small and may change before `1.0.0`.

## The idea

Codex CLI and NeoVim remain graphically independent:

- Codex CLI remains a normal terminal application. You decide whether and where to run it.
- NeoVim offers a command for listing local Codex chats and selecting one for the current NeoVim instance.
- The selected chat is associated with the whole NeoVim session, rather than a particular buffer or split.
- The plugin talks to `codex app-server` over its local protocol. It does not depend on kitty, tmux, Sway, a compositor, or terminal escape-sequence tricks.
- Once selected, the plugin can send explicitly requested editor context—such as a buffer, range, diagnostics, or quickfix items—to that chat.

This is intentionally not an attempt to embed Codex CLI inside NeoVim, nor to have `/ide` discover arbitrary terminals. It is a native NeoVim client for Codex's rich-client protocol.

## Available now

`codex.nvim` provides these commands:

```vim
:CodexList
:CodexLS
:CodexSend
:CodexChat

:CoLS
:CoSe
:CoCh
```

The `Codex…` commands are the stable, descriptive API. `CoLS`, `CoSe`, and `CoCh` are their short aliases for daily terminal use. To avoid overriding another plugin, codex.nvim creates a short alias only when that exact command name is unused.

`CodexList` and its `CodexLS` alias open a keyboard-only list of non-archived interactive Codex chats whose working directory exactly matches NeoVim's current working directory. Move the cursor with the arrow keys and press `<Enter>` to select it, or type a line number then press `<Enter>` to select that chat directly. Press `<Esc>` or `q` to cancel. `codex.nvim` retains the chosen chat for the entire current NeoVim instance:

```lua
local codex = require("codex")

codex.selected_chat()    -- the selected thread metadata, or nil
codex.selected_chat_id() -- the selected thread ID, or nil
codex.clear_selection()
```

### Send a line range to the selected chat

Use `:CodexSend` to send the current line, or use an Ex line range to send those lines verbatim as the next user message in the selected Codex chat:

```vim
:CodexSend          " current line
:12,30CodexSend     " lines 12 through 30
:'<,'>CodexSend     " lines covered by the active Visual selection
```

`CodexSend` resumes the selected chat and starts a new Codex turn. It sends linewise text only: a characterwise Visual selection is expanded to its containing lines. The command never sends text to an unselected chat, and it leaves the chat's existing working directory, sandbox, and approval settings unchanged.

The most recently selected chat is saved per exact project directory and restored on the next NeoVim start. Restoring selection is local state only: it does not connect to, resume, or modify the chat until you run `CodexSend` or `CodexList`. To disable this behavior:

```lua
require("codex").setup({
  selection = { persist = false },
})
```

The underlying API is also available for a future mapping or integration:

```lua
require("codex").send("Explain this snippet", function(err, turn)
  -- `turn` is the accepted App Server turn, or nil when `err` is set.
end)
```

### Send direct chat input

Use `:CodexChat` to send the rest of its command line as direct input to the selected chat:

```vim
:CodexChat Explain why this function uses a timer.
:CodexChat Please review: []{}()$#@! and "quoted text".
```

For text containing a newline or content more convenient to construct in Lua, use `require("codex").chat(text)` instead.

The picker deliberately excludes archived chats and chats from other projects. Selecting a chat does not itself open, resume, or alter it; `CodexSend` does so only when you explicitly send text.

`codex.nvim` is keyboard-first. It provides no mouse bindings, click handlers, or mouse-specific UI, and does not delegate chat selection to `vim.ui.select` or its mouse-oriented fallback prompt. The plugin leaves NeoVim's global `mouse` option unchanged.

On first use, the plugin starts the local App Server daemon when necessary, then connects to its local Unix-socket WebSocket endpoint. This is a local transport only; it does not create or control a terminal window.

### Statusline progress

While `:CodexList` is waiting on the App Server, `codex.nvim` exposes a compact Braille spinner for your existing statusline:

```text
· ⠹ Listing Codex chats…
```

It appears only after 120 ms, updates in place every 100 ms, and disappears before the keyboard picker opens. With NeoVim's untouched native statusline, the plugin places it immediately after the filename automatically. It never replaces a statusline you have configured yourself.

For a custom statusline, add its component wherever you want it to appear:

For a native statusline:

```vim
set statusline+=%{%v:lua.require'codex'.status()%}
```

For lualine:

```lua
{
  function()
    return require("codex").status()
  end,
}
```

The component refreshes with `:redrawstatus` while an operation is active. It returns `""` while idle, so it takes no space. The current defaults can be changed during setup:

```lua
require("codex").setup({
  progress = {
    enabled = true,
    delay_ms = 120,
    interval_ms = 100,
  },
})
```

### Install for local development

With `lazy.nvim`:

```lua
{
  dir = "/path/to/codex.nvim",
  config = function()
    require("codex").setup()
  end,
}
```

The plugin works with its defaults as soon as it is on NeoVim's runtime path. Calling `setup()` is optional and idempotent, so it is safe to use only when you want to override defaults.

To manage the daemon yourself, disable automatic startup:

```lua
require("codex").setup({ auto_start = false })
```

## Next steps

1. Show the active chat and add an explicit command to clear it.
2. Stream agent replies into a NeoVim scratch buffer.
3. Present Codex command and file-change approvals through NeoVim's native UI.

## Requirements

- **NeoVim 0.12.5 or newer.** `codex.nvim` checks this when it starts and refuses App Server operations on older versions.
- **Codex CLI 0.154.0 or newer**, including its matching local App Server. `codex.nvim` checks `codex --version` before it connects or starts the daemon.
- A local Codex CLI authentication and the App Server daemon. Check it with:

  ```sh
  codex --version
  codex app-server daemon version
  ```

These are deliberately pinned minimums, not merely versions that might work. This release was developed and validated against NeoVim `0.12.5` and Codex CLI/App Server `0.154.0`. The App Server protocol is version-coupled to the CLI that provides it; OpenAI documents generated protocol artifacts as matching the specific Codex version that generated them. [See the App Server documentation](https://learn.chatgpt.com/docs/app-server).

## Contributing

Issues, design discussion, and pull requests are welcome. The project aims to be small, composable, accessible, and respectful of user-managed terminal and window-manager workflows.

## License

MIT. See [LICENSE.md](LICENSE.md).
