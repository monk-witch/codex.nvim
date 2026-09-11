# codex.nvim

> A terminal-independent NeoVim client for the [Codex App Server](https://learn.chatgpt.com/docs/app-server).

`codex.nvim` brings an existing local Codex chat into the current NeoVim session without taking ownership of your terminal layout. Keep Codex CLI in kitty, tmux, Sway, a different terminal, or no visible terminal at all—the plugin connects to Codex's local App Server, not to a terminal pane.

## Status

**0.0.4 — keyboard-first chat selection over the local App Server WebSocket.** The public API is small and may change before `1.0.0`.

## The idea

Codex CLI and NeoVim remain graphically independent:

- Codex CLI remains a normal terminal application. You decide whether and where to run it.
- NeoVim offers a command for listing local Codex chats and selecting one for the current NeoVim instance.
- The selected chat is associated with the whole NeoVim session, rather than a particular buffer or split.
- The plugin talks to `codex app-server` over its local protocol. It does not depend on kitty, tmux, Sway, a compositor, or terminal escape-sequence tricks.
- Once selected, the plugin can send explicitly requested editor context—such as a buffer, range, diagnostics, or quickfix items—to that chat.

This is intentionally not an attempt to embed Codex CLI inside NeoVim, nor to have `/ide` discover arbitrary terminals. It is a native NeoVim client for Codex's rich-client protocol.

## Available now

`codex.nvim` provides two equivalent commands:

```vim
:CodexList
:CodexLS
```

They use NeoVim's native `vim.ui.select` picker to list non-archived interactive Codex chats whose working directory exactly matches NeoVim's current working directory. Choose one and `codex.nvim` retains it for the entire current NeoVim instance:

```lua
local codex = require("codex")

codex.selected_chat()    -- the selected thread metadata, or nil
codex.selected_chat_id() -- the selected thread ID, or nil
codex.clear_selection()
```

The picker deliberately excludes archived chats and chats from other projects. It does not open, resume, alter, or subscribe to a selected conversation yet.

`codex.nvim` is keyboard-first. It provides no mouse bindings, click handlers, or mouse-specific UI. The plugin deliberately leaves NeoVim's global `mouse` option and any user-installed `vim.ui.select` provider alone.

On first use, the plugin starts the local App Server daemon when necessary, then connects to its local Unix-socket WebSocket endpoint. This is a local transport only; it does not create or control a terminal window.

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

To manage the daemon yourself, disable automatic startup:

```lua
require("codex").setup({ auto_start = false })
```

## Next steps

1. Show the active chat and add an explicit command to clear it.
2. Send a prompt, current-file reference, or visual selection to the selected chat.
3. Stream agent replies into a NeoVim scratch buffer.
4. Present Codex command and file-change approvals through NeoVim's native UI.

## Requirements

- NeoVim 0.10 or newer.
- A locally authenticated [Codex CLI](https://learn.chatgpt.com/docs/codex/cli) with `codex app-server` available.

## Contributing

Issues, design discussion, and pull requests are welcome. The project aims to be small, composable, accessible, and respectful of user-managed terminal and window-manager workflows.

## License

MIT. See [LICENSE.md](LICENSE.md).
