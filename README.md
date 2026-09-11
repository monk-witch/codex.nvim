# codex.nvim

> A terminal-independent NeoVim client for the [Codex App Server](https://learn.chatgpt.com/docs/app-server).

`codex.nvim` brings an existing local Codex chat into the current NeoVim session without taking ownership of your terminal layout. Keep Codex CLI in kitty, tmux, Sway, a different terminal, or no visible terminal at all—the plugin connects to Codex's local App Server, not to a terminal pane.

## Status

**0.0.1 — project scaffold.** The public API is not implemented yet and may change before `1.0.0`.

## The idea

Codex CLI and NeoVim remain graphically independent:

- Codex CLI remains a normal terminal application. You decide whether and where to run it.
- NeoVim offers a command for listing local Codex chats and selecting one for the current NeoVim instance.
- The selected chat is associated with the whole NeoVim session, rather than a particular buffer or split.
- The plugin talks to `codex app-server` over its local protocol. It does not depend on kitty, tmux, Sway, a compositor, or terminal escape-sequence tricks.
- Once selected, the plugin can send explicitly requested editor context—such as a buffer, range, diagnostics, or quickfix items—to that chat.

This is intentionally not an attempt to embed Codex CLI inside NeoVim, nor to have `/ide` discover arbitrary terminals. It is a native NeoVim client for Codex's rich-client protocol.

## Planned first usable release

1. Detect or start a local Codex App Server.
2. List resumable local chats and select one for the active NeoVim session.
3. Show the active chat and allow changing or clearing it.
4. Send a prompt, current-file reference, or visual selection to the selected chat.
5. Stream agent replies into a NeoVim scratch buffer.
6. Present Codex command and file-change approvals through NeoVim's native UI.

## Requirements

- NeoVim 0.10 or newer.
- A locally authenticated [Codex CLI](https://learn.chatgpt.com/docs/codex/cli) with `codex app-server` available.

## Contributing

Issues, design discussion, and pull requests are welcome. The project aims to be small, composable, accessible, and respectful of user-managed terminal and window-manager workflows.

## License

MIT. See [LICENSE.md](LICENSE.md).
