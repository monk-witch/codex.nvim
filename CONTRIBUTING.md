# Contributing to codex.nvim

Thanks for helping make `codex.nvim` a small, dependable NeoVim client for the local Codex App Server.

## Before opening a pull request

- Discuss substantial API, protocol, or UX changes in an issue first.
- Keep changes focused. Do not reformat unrelated files.
- Preserve the project’s terminal-independent model: no terminal scraping, pane management, or implicit editor-context sends.
- Do not include access tokens, local socket paths, chat content, or other private material in issues, tests, commits, or screenshots.

## Local checks

The supported minimums are NeoVim `0.12.5` and Codex CLI `0.154.0`. The test suite uses a local fake App Server, so it needs no Codex account or daemon:

```sh
bash tests/run.sh
```

Format Lua with StyLua `2.5.2` and check the result:

```sh
stylua lua tests
stylua --check lua tests
```

NeoVim help tags are committed. After changing `doc/codex.txt`, regenerate and review them:

```sh
nvim --headless -u NONE -i NONE '+helptags doc' '+qa!'
```

## Compatibility

The commands, documented configuration keys, public Lua API, persistence format, and minimum versions are the `0.1` public contract. A patch release must not deliberately break them. Additive changes are welcome; breaking changes require a new minor version and migration notes.

## Pull requests

Explain the user-visible behavior, testing performed, and any compatibility or privacy effect. The GitHub workflow checks Lua formatting and runs the protocol suite on pushes and pull requests.
